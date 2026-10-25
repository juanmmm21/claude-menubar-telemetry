import Foundation

// Cuota diaria de un modelo de Gemini tal y como la sirve Code Assist: el
// servidor da la fracción que *queda*, aquí se guarda ya como % usado para que
// se pinte igual que las barras de Claude.
struct GeminiModelQuota: Equatable, Identifiable {
    let modelId: String
    let usedPercent: Double
    let remainingRequests: Int?
    let limitRequests: Int?
    let resetsAt: Date?
    var id: String { modelId }
}

struct GeminiAccountUsage: Equatable {
    let email: String?
    let planName: String?
    let models: [GeminiModelQuota]
}

enum GeminiQuotaError: Error {
    case notLoggedIn      // No hay oauth_creds.json: Gemini CLI no está instalado o usa API key
    case sessionExpired   // Google rechazó el refresh token: hay que volver a entrar en Gemini CLI
    case noProject        // La cuenta no tiene proyecto de Code Assist asociado
    case network(String)
    case unavailable
}

extension GeminiQuotaError {
    var userMessage: String {
        switch self {
        case .notLoggedIn:
            return "Sin sesión de Gemini CLI (login con Google) en este Mac"
        case .sessionExpired:
            return "Sesión de Gemini CLI caducada — ejecuta gemini y vuelve a entrar"
        case .noProject:
            return "Tu cuenta no tiene proyecto de Code Assist (¿GOOGLE_CLOUD_PROJECT?)"
        case .network(let detail):
            return "Sin conexión con Google (\(detail))"
        case .unavailable:
            return "Cuota de Gemini no disponible ahora mismo"
        }
    }
}

// Lee la cuota real de Gemini reutilizando la sesión que Gemini CLI deja en
// ~/.gemini/oauth_creds.json.
//
// Es lo mismo que hace el propio CLI en /stats: loadCodeAssist para saber el
// proyecto y el plan de la cuenta, y retrieveUserQuota para la cuota restante
// de cada modelo. Ninguna de las dos llamadas gasta cuota.
//
// A diferencia de Claude Code, aquí sí se renueva el token: Google no rota el
// refresh token al usarlo, así que hacerlo no le cierra la sesión al CLI. El
// token renovado se queda solo en memoria; el fichero del CLI no se toca nunca.
final class GeminiUsageService {
    private static let codeAssistBase = "https://cloudcode-pa.googleapis.com/v1internal"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    // Cliente OAuth de "app instalada" de Gemini CLI, publicado en su código
    // abierto (packages/core/src/code_assist/oauth2.ts). Google documenta que en
    // este tipo de cliente el secreto no se trata como secreto; hace falta para
    // renovar un token emitido a ese cliente.
    private static let clientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    private static let clientSecret = "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"

    private let session: URLSession

    // Estado tocado solo desde `queue`.
    private let queue = DispatchQueue(label: "com.juanmmm21.ClaudeTelemetry.gemini")
    private var accessToken: (value: String, expiresAt: Date)?
    private var account: (projectID: String, planName: String?)?

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: GeminiPaths.root.path)
    }

    // `completion` llega en una cola cualquiera.
    func fetchUsage(completion: @escaping (Result<GeminiAccountUsage, GeminiQuotaError>) -> Void) {
        queue.async {
            completion(self.fetchUsageSync(isRetry: false))
        }
    }

    private func fetchUsageSync(isRetry: Bool) -> Result<GeminiAccountUsage, GeminiQuotaError> {
        do {
            let token = try validAccessToken()
            let account = try codeAssistAccount(token: token)
            let models = try retrieveQuota(projectID: account.projectID, token: token)
            return .success(GeminiAccountUsage(
                email: GeminiPaths.activeAccountEmail(),
                planName: account.planName,
                models: models
            ))
        } catch RequestError.unauthorized {
            // El token en memoria puede haber sido revocado: se descarta y se
            // prueba una vez más con uno recién leído o renovado.
            accessToken = nil
            return isRetry ? .failure(.sessionExpired) : fetchUsageSync(isRetry: true)
        } catch let error as GeminiQuotaError {
            return .failure(error)
        } catch RequestError.network(let detail) {
            return .failure(.network(detail))
        } catch {
            return .failure(.unavailable)
        }
    }

    // MARK: - Token

    private func validAccessToken() throws -> String {
        if let token = accessToken, token.expiresAt.timeIntervalSinceNow > 120 {
            return token.value
        }

        // Si el CLI renovó el token hace poco, el del fichero todavía vale y no
        // hace falta pedir otro.
        guard let data = try? Data(contentsOf: GeminiPaths.oauthCreds),
              let creds = try? JSONDecoder().decode(OAuthCredsFile.self, from: data) else {
            throw GeminiQuotaError.notLoggedIn
        }
        if let value = creds.accessToken, let expiry = creds.expiryDate {
            let expiresAt = Date(timeIntervalSince1970: expiry / 1000)
            if expiresAt.timeIntervalSinceNow > 120 {
                accessToken = (value, expiresAt)
                return value
            }
        }

        guard let refreshToken = creds.refreshToken else {
            throw GeminiQuotaError.sessionExpired
        }
        let refreshed = try refreshAccessToken(refreshToken)
        accessToken = refreshed
        return refreshed.value
    }

    private func refreshAccessToken(_ refreshToken: String) throws -> (value: String, expiresAt: Date) {
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])

        let (status, data) = try perform(request)
        // 400 invalid_grant: el refresh token se revocó o caducó (pasa si se
        // cambia la contraseña de Google o tras meses sin usar el CLI).
        if status == 400 || status == 401 {
            throw GeminiQuotaError.sessionExpired
        }
        guard status == 200,
              let payload = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GeminiQuotaError.unavailable
        }
        return (payload.accessToken, Date().addingTimeInterval(payload.expiresIn ?? 3600))
    }

    // MARK: - Code Assist

    private func codeAssistAccount(token: String) throws -> (projectID: String, planName: String?) {
        if let account = account {
            return account
        }

        let body: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            ]
        ]
        let data = try post("loadCodeAssist", body: body, token: token)
        guard let payload = try? JSONDecoder().decode(LoadCodeAssistResponse.self, from: data) else {
            throw GeminiQuotaError.unavailable
        }
        guard let projectID = payload.cloudaicompanionProject, !projectID.isEmpty else {
            throw GeminiQuotaError.noProject
        }

        // paidTier refleja la suscripción (Google AI Pro/Ultra) cuando la hay;
        // currentTier es el nivel de Code Assist (gratuito, Standard...).
        let resolved: (projectID: String, planName: String?) = (
            projectID,
            payload.paidTier?.name ?? payload.currentTier?.name
        )
        account = resolved
        return resolved
    }

    private func retrieveQuota(projectID: String, token: String) throws -> [GeminiModelQuota] {
        let data = try post("retrieveUserQuota", body: ["project": projectID], token: token)
        guard let payload = try? JSONDecoder().decode(RetrieveUserQuotaResponse.self, from: data) else {
            throw GeminiQuotaError.unavailable
        }

        // Puede haber más de un cubo por modelo (uno por tipo de límite); manda
        // el más gastado, que es el que te va a cortar antes.
        var byModel: [String: GeminiModelQuota] = [:]
        for bucket in payload.buckets ?? [] {
            guard let modelId = bucket.modelId, let fraction = bucket.remainingFraction else { continue }
            let remaining = bucket.remainingAmount.flatMap { Int($0) }
            let limit: Int? = {
                guard let remaining = remaining, fraction > 0 else { return nil }
                return Int((Double(remaining) / fraction).rounded())
            }()
            let quota = GeminiModelQuota(
                modelId: modelId,
                usedPercent: min(max((1 - fraction) * 100, 0), 100),
                remainingRequests: remaining,
                limitRequests: limit,
                resetsAt: bucket.resetTime.flatMap(GeminiDates.parse)
            )
            if let existing = byModel[modelId], existing.usedPercent >= quota.usedPercent {
                continue
            }
            byModel[modelId] = quota
        }
        return byModel.values.sorted { GeminiModelNames.sortKey($0.modelId) < GeminiModelNames.sortKey($1.modelId) }
    }

    private func post(_ method: String, body: [String: Any], token: String) throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.codeAssistBase):\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (status, data) = try perform(request)
        if status == 401 {
            throw RequestError.unauthorized
        }
        guard status == 200 else {
            throw GeminiQuotaError.unavailable
        }
        return data
    }

    // MARK: - Red

    private enum RequestError: Error {
        case unauthorized
        case network(String)
    }

    // Esta clase ya trabaja en su propia cola serie, así que es más legible
    // esperar a cada respuesta que encadenar cuatro callbacks.
    private func perform(_ request: URLRequest) throws -> (Int, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                box.failure = error
            } else if let http = response as? HTTPURLResponse {
                box.result = (http.statusCode, data ?? Data())
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let failure = box.failure {
            throw RequestError.network(failure.localizedDescription)
        }
        guard let result = box.result else {
            throw GeminiQuotaError.unavailable
        }
        return result
    }

    // El semáforo ordena la escritura (en el callback) antes de la lectura.
    private final class ResponseBox: @unchecked Sendable {
        var result: (Int, Data)?
        var failure: Error?
    }

    private static func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - Formatos de Gemini CLI y Code Assist

private struct OAuthCredsFile: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiryDate: Double? // milisegundos desde epoch

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiryDate = "expiry_date"
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private struct LoadCodeAssistResponse: Decodable {
    struct Tier: Decodable {
        let id: String?
        let name: String?
    }
    let currentTier: Tier?
    let paidTier: Tier?
    let cloudaicompanionProject: String?
}

private struct RetrieveUserQuotaResponse: Decodable {
    struct Bucket: Decodable {
        let remainingAmount: String?
        let remainingFraction: Double?
        let resetTime: String?
        let tokenType: String?
        let modelId: String?
    }
    let buckets: [Bucket]?
}

// Rutas que Gemini CLI usa en disco.
enum GeminiPaths {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }

    static var oauthCreds: URL { root.appendingPathComponent("oauth_creds.json") }

    // Las conversaciones se graban en ~/.gemini/tmp/<hash del proyecto>/chats/.
    static var sessionsRoot: URL { root.appendingPathComponent("tmp") }

    // Gemini CLI apunta aquí la cuenta de Google con la que se entró.
    static func activeAccountEmail() -> String? {
        let url = root.appendingPathComponent("google_accounts.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["active"] as? String,
              !email.isEmpty else {
            return nil
        }
        return email
    }
}

enum GeminiDates {
    static func parse(_ text: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

enum GeminiModelNames {
    // "gemini-2.5-pro" -> "Gemini 2.5 Pro". Los ids cambian con cada versión,
    // así que se formatean en vez de mantener una tabla de nombres.
    static func displayName(_ modelId: String) -> String {
        let trimmed = modelId.replacingOccurrences(of: "models/", with: "")
        guard trimmed.lowercased().hasPrefix("gemini") else { return trimmed }
        return trimmed
            .split(separator: "-")
            .map { part in
                part.first.map { String($0).uppercased() + part.dropFirst() } ?? String(part)
            }
            .joined(separator: " ")
    }

    // Pro primero, luego Flash, luego Flash Lite; dentro de cada familia, la
    // versión más nueva arriba.
    static func sortKey(_ modelId: String) -> String {
        let id = modelId.lowercased()
        let family: String
        if id.contains("flash-lite") || id.contains("flash_lite") {
            family = "2"
        } else if id.contains("flash") {
            family = "1"
        } else if id.contains("pro") {
            family = "0"
        } else {
            family = "3"
        }
        // Invertir los dígitos de la versión para que "3" vaya antes que "2.5".
        let inverted = String(id.map { char -> Character in
            guard let digit = char.wholeNumberValue else { return char }
            return Character(String(9 - digit))
        })
        return family + inverted
    }
}
