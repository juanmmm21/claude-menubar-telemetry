import Foundation
import Security

// Sesión OAuth que Claude Code guarda en el Keychain, reducida a lo único que
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
    case notLoggedIn          // No hay item de credenciales de Claude Code en este Mac
    case authorizationRequired // Hace falta el permiso del llavero y no se ha pedido abrir el diálogo
    case accessDenied         // El usuario denegó el diálogo, o macOS rechazó el acceso
    case expired              // El token guardado ya caducó: solo Claude Code puede renovarlo
    case malformed            // El item existe pero no tiene la forma esperada
}

// Guarda el token de Claude Code en un item propio de la app para no tener que
// volver al llavero del CLI en cada sondeo.
//
// Por qué hace falta: el item "Claude Code-credentials" lo escribe el CLI cada
// vez que renueva su token OAuth, y esa reescritura invalida el "Permitir
// siempre" que el usuario ya había concedido. Por eso el diálogo del sistema
// vuelve a salir cada día por mucho que se pulse "Permitir siempre". No se puede
// evitar del todo sin dejar de leer ese item, pero sí se puede reducir a una
// sola vez por renovación y, sobre todo, que nunca salte solo: los sondeos
// consultan el llavero con la interacción desactivada, y el diálogo únicamente
// aparece cuando el usuario lo pide desde el panel.
final class ClaudeSessionStore {
    private static let claudeCodeService = "Claude Code-credentials"
    private static let cacheService = "com.juanmmm21.ClaudeTelemetry.session"
    private static let cacheAccount = "claude-code-oauth-access-token"

    // SecKeychainSetUserInteractionAllowed es un flag de proceso, así que dos
    // lecturas simultáneas se pisarían entre sí.
    private let lock = NSLock()

    // `allowingPrompt: false` garantiza que la llamada no abre ningún diálogo:
    // si hiciera falta el permiso del usuario, devuelve .authorizationRequired.
    func session(allowingPrompt: Bool) throws -> ClaudeSession {
        lock.lock()
        defer { lock.unlock() }

        if let cached = readCachedSession(), cached.isUsable {
            return cached
        }

        let fresh = try readClaudeCodeSession(allowingPrompt: allowingPrompt)
        guard fresh.isUsable else {
            deleteCachedSession()
            throw SessionError.expired
        }
        writeCachedSession(fresh)
        return fresh
    }

    // Se llama cuando la API rechaza el token (401): la copia en caché ya no
    // sirve y el siguiente intento debe volver al llavero de Claude Code.
    func invalidateCachedSession() {
        lock.lock()
        defer { lock.unlock() }
        deleteCachedSession()
    }

    // MARK: - Item propio de la app

    private struct CachedSession: Codable {
        let accessToken: String
        let expiresAt: Date
    }

    private func readCachedSession() -> ClaudeSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cacheService,
            kSecAttrAccount as String: Self.cacheAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = withUserInteraction(false) {
            SecItemCopyMatching(query as CFDictionary, &item)
        }

        guard status == errSecSuccess, let data = item as? Data else {
            // El item existe pero esta build ya no está en su lista de
            // aplicaciones autorizadas (pasa al recompilar: cambia la firma
            // ad-hoc del binario). Se borra para que la siguiente lectura del
            // llavero de Claude Code lo vuelva a crear a nombre de la build
            // nueva, en vez de dejar un item que solo sabe pedir permiso.
            if status != errSecItemNotFound {
                deleteCachedSession()
            }
            return nil
        }

        guard let cached = try? JSONDecoder().decode(CachedSession.self, from: data) else {
            deleteCachedSession()
            return nil
        }
        return ClaudeSession(accessToken: cached.accessToken, expiresAt: cached.expiresAt)
    }

    private func writeCachedSession(_ session: ClaudeSession) {
        guard let data = try? JSONEncoder().encode(
            CachedSession(accessToken: session.accessToken, expiresAt: session.expiresAt)
        ) else { return }

        deleteCachedSession()

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cacheService,
            kSecAttrAccount as String: Self.cacheAccount,
            kSecAttrLabel as String: "ClaudeTelemetry (copia de sesión)",
            kSecAttrDescription as String: "Token de lectura de cuota, renovado por Claude Code",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        // Un fallo aquí no rompe nada: solo significa que el próximo sondeo
        // tendrá que volver a pedir el token al llavero de Claude Code.
        _ = withUserInteraction(false) {
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    private func deleteCachedSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.cacheService,
            kSecAttrAccount as String: Self.cacheAccount
        ]
        _ = withUserInteraction(false) {
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Item de Claude Code

    private func readClaudeCodeSession(allowingPrompt: Bool) throws -> ClaudeSession {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeCodeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = withUserInteraction(allowingPrompt) {
            SecItemCopyMatching(query as CFDictionary, &item)
        }

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw SessionError.notLoggedIn
        case errSecInteractionNotAllowed, errSecInteractionRequired:
            throw SessionError.authorizationRequired
        default:
            // errSecUserCanceled / errSecAuthFailed cuando el usuario cierra o
            // deniega el diálogo del sistema.
            throw SessionError.accessDenied
        }

        guard let data = item as? Data,
              let file = try? JSONDecoder().decode(CredentialsFile.self, from: data) else {
            throw SessionError.malformed
        }

        return ClaudeSession(
            accessToken: file.claudeAiOauth.accessToken,
            // Claude Code guarda la caducidad en milisegundos.
            expiresAt: Date(timeIntervalSince1970: file.claudeAiOauth.expiresAt / 1000)
        )
    }

    // Solo se decodifica lo imprescindible; el item de Claude Code trae más
    // campos (refresh token, scopes, tier de suscripción) que esta app no toca.
    private struct CredentialsFile: Codable {
        struct OAuth: Codable {
            let accessToken: String
            let expiresAt: Double
        }
        let claudeAiOauth: OAuth
    }

    // MARK: - Control del diálogo del sistema

    // SecKeychainSetUserInteractionAllowed está deprecada desde macOS 12, pero
    // sigue siendo la única forma de consultar el llavero heredado sin que macOS
    // decida por su cuenta abrir el diálogo de permiso. Es justo lo que hace
    // falta aquí: que el aviso salga cuando el usuario lo pide, no en mitad de
    // un sondeo en segundo plano.
    private func withUserInteraction<T>(_ allowed: Bool, _ body: () -> T) -> T {
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(allowed)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return body()
    }
}
