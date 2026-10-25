import Foundation

// Sesión OAuth que Claude Code guarda en este Mac, reducida a lo único que
// esta app necesita: el token de acceso y cuándo caduca. El refresh token no se
// lee ni se guarda a propósito — refrescar por nuestra cuenta rotaría el token
// del CLI y podría cerrarle la sesión al usuario en su terminal.
struct ClaudeSession: Equatable {
    let accessToken: String
    let expiresAt: Date

    // Margen para no arrancar una petición con un token que caduca durante el
    // viaje de red.
    var isUsable: Bool { expiresAt.timeIntervalSinceNow > 120 }
}

enum SessionError: Error {
    case notLoggedIn  // No hay credenciales de Claude Code en este Mac
    case accessDenied // macOS no dejó leer el item del llavero
    case expired      // El token guardado ya caducó: solo Claude Code puede renovarlo
    case malformed    // Las credenciales existen pero no tienen la forma esperada
}

// Lee la sesión de Claude Code sin que macOS pida nunca la contraseña.
//
// Claude Code no usa la API del llavero: guarda y lee su item
// "Claude Code-credentials" llamando a /usr/bin/security
// (`add-generic-password -U` / `find-generic-password -w`). Como es ese binario
// el que crea el item, es el único que figura en su lista de apps de confianza.
// Las versiones anteriores de esta app lo leían con SecItemCopyMatching y por
// eso macOS pedía la contraseña cada vez que Claude Code renovaba el token.
// Leyéndolo con el mismo binario que lo escribe, macOS lo entrega sin preguntar,
// igual que se lo entrega al propio CLI.
final class ClaudeSessionStore {
    private static let keychainService = "Claude Code-credentials"
    private static let securityTool = "/usr/bin/security"

    // Código de salida de `security` cuando el item no existe.
    private static let itemNotFoundStatus: Int32 = 44

    private let lock = NSLock()
    private var cached: ClaudeSession?

    // Bloquea mientras corre `security`: llamar fuera del hilo principal.
    func session() throws -> ClaudeSession {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cached, cached.isUsable {
            return cached
        }

        let fresh = try readNewestSession()
        guard fresh.isUsable else {
            cached = nil
            throw SessionError.expired
        }
        cached = fresh
        return fresh
    }

    // Se llama cuando la API rechaza el token (401): la siguiente lectura debe
    // volver a las credenciales de Claude Code, que puede haberlo renovado ya.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    // Claude Code guarda la sesión en el llavero, salvo cuando no puede usarlo:
    // entonces la deja en ~/.claude/.credentials.json. Si existen las dos (por
    // ejemplo, un fichero viejo de antes de pasar al llavero), gana la que
    // caduca más tarde, que es la que el CLI renovó por última vez.
    private func readNewestSession() throws -> ClaudeSession {
        var candidates: [ClaudeSession] = []
        var keychainError: SessionError?

        do {
            candidates.append(try Self.decode(try readKeychainItem()))
        } catch let error as SessionError {
            keychainError = error
        }

        if let data = try? Data(contentsOf: Self.credentialsFileURL),
           let fromFile = try? Self.decode(data) {
            candidates.append(fromFile)
        }

        if let newest = candidates.max(by: { $0.expiresAt < $1.expiresAt }) {
            return newest
        }
        throw keychainError ?? SessionError.notLoggedIn
    }

    private static var credentialsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    // MARK: - Llavero, a través de /usr/bin/security

    private func readKeychainItem() throws -> Data {
        // Mismo comando que ejecuta Claude Code. Si el item se creó con otra
        // cuenta (versiones antiguas del CLI), se reintenta solo por servicio.
        var result = CommandRunner.run(Self.securityTool, arguments: [
            "find-generic-password", "-a", NSUserName(), "-s", Self.keychainService, "-w"
        ])
        if result?.status == Self.itemNotFoundStatus {
            result = CommandRunner.run(Self.securityTool, arguments: [
                "find-generic-password", "-s", Self.keychainService, "-w"
            ])
        }

        guard let output = result else { throw SessionError.accessDenied }
        switch output.status {
        case 0:
            return Self.unwrapPassword(output.stdout)
        case Self.itemNotFoundStatus:
            throw SessionError.notLoggedIn
        default:
            throw SessionError.accessDenied
        }
    }

    // `security -w` imprime el secreto tal cual si es texto, o en hexadecimal si
    // contiene bytes no imprimibles. Se aceptan las dos formas.
    private static func unwrapPassword(_ stdout: Data) -> Data {
        let text = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            return Data(text.utf8)
        }
        return hexDecoded(text) ?? Data(text.utf8)
    }

    private static func hexDecoded(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(decoding: chars[index..<index + 2], as: UTF8.self), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index += 2
        }
        return Data(bytes)
    }

    // MARK: - Formato de las credenciales

    private static func decode(_ data: Data) throws -> ClaudeSession {
        guard let file = try? JSONDecoder().decode(CredentialsFile.self, from: data) else {
            throw SessionError.malformed
        }
        return ClaudeSession(
            accessToken: file.claudeAiOauth.accessToken,
            // Claude Code guarda la caducidad en milisegundos.
            expiresAt: Date(timeIntervalSince1970: file.claudeAiOauth.expiresAt / 1000)
        )
    }

    // Solo se decodifica lo imprescindible; las credenciales de Claude Code traen
    // más campos (refresh token, scopes, tier de suscripción) que esta app no toca.
    private struct CredentialsFile: Codable {
        struct OAuth: Codable {
            let accessToken: String
            let expiresAt: Double
        }
        let claudeAiOauth: OAuth
    }
}

// Ejecuta una herramienta de línea de comandos y devuelve su salida, con un
// tiempo máximo para que un proceso colgado nunca bloquee el sondeo.
enum CommandRunner {
    struct Output {
        let status: Int32
        let stdout: Data
    }

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 5) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Se lee antes de esperar: si la salida llenara el buffer del pipe, el
        // proceso se quedaría bloqueado escribiendo y nunca terminaría.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal {
            return nil
        }
        return Output(status: process.terminationStatus, stdout: data)
    }
}
