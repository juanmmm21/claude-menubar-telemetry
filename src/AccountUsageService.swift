import Foundation
import Security

// Cuota unificada real de la cuenta (Desktop + web + CLI + móvil), tal y como la
// calcula el propio backend de Anthropic — no una estimación local.
struct UnifiedQuota: Equatable {
    let fiveHourUtilization: Double   // 0.0 - 1.0
    let fiveHourReset: Date
    let sevenDayUtilization: Double   // 0.0 - 1.0
    let sevenDayReset: Date
    let isRateLimited: Bool
}

enum LiveQuotaError: Error {
    case notLoggedIn        // No hay item de credenciales de Claude Code en el Keychain
    case keychainAccessDenied // El item existe pero macOS denegó el acceso (permiso no concedido)
    case sessionExpired     // El access token guardado ya caducó
    case network(String)
    case unavailable        // Respuesta recibida pero sin las cabeceras esperadas
}

// Lee la cuota de uso real de la cuenta reutilizando la sesión OAuth que Claude
// Code ya tiene guardada localmente (Keychain, item "Claude Code-credentials").
// No se escribe nada en ese item ni se intenta refrescar el token: si ha
// caducado, se informa al usuario en vez de intentar un refresh no documentado
// que podría interferir con la sesión real del CLI.
//
// Cómo se obtiene el dato: una llamada mínima (max_tokens: 1, coste de cuota
// despreciable) a /v1/messages con ese mismo token. La respuesta de Anthropic
// incluye cabeceras `anthropic-ratelimit-unified-*` con la utilización real de
// las ventanas de 5 horas y 7 días de la cuenta. Esas cabeceras no son API
// pública documentada, así que si Anthropic las renombra o las retira esta
// llamada dejará de aportar dato en vivo y la app debe caer de vuelta al
// cálculo local basado en logs (ver TelemetryManager).
final class AccountUsageService {
    private static let keychainService = "Claude Code-credentials"

    // Modelo usado solo para la llamada de sondeo (max_tokens: 1). Si Anthropic
    // retira este id en el futuro, actualízalo aquí; el resto de la lógica no
    // depende de qué modelo se use.
    private static let probeModel = "claude-haiku-4-5-20251001"

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func fetchLiveQuota(completion: @escaping (Result<UnifiedQuota, LiveQuotaError>) -> Void) {
        let oauth: CredentialsFile.OAuth
        do {
            oauth = try Self.readCredentials()
        } catch let error as LiveQuotaError {
            completion(.failure(error))
            return
        } catch {
            completion(.failure(.unavailable))
            return
        }

        let expiry = Date(timeIntervalSince1970: oauth.expiresAt / 1000)
        guard expiry > Date() else {
            completion(.failure(.sessionExpired))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": Self.probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ])

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, let quota = Self.parseQuota(from: http) else {
                completion(.failure(.unavailable))
                return
            }
            completion(.success(quota))
        }.resume()
    }

    private static func parseQuota(from response: HTTPURLResponse) -> UnifiedQuota? {
        func header(_ name: String) -> String? {
            response.value(forHTTPHeaderField: name)
        }
        guard let fiveHUtil = header("anthropic-ratelimit-unified-5h-utilization").flatMap(Double.init),
              let fiveHReset = header("anthropic-ratelimit-unified-5h-reset").flatMap(Double.init),
              let sevenDUtil = header("anthropic-ratelimit-unified-7d-utilization").flatMap(Double.init),
              let sevenDReset = header("anthropic-ratelimit-unified-7d-reset").flatMap(Double.init) else {
            return nil
        }
        let status = header("anthropic-ratelimit-unified-status") ?? "allowed"
        return UnifiedQuota(
            fiveHourUtilization: fiveHUtil,
            fiveHourReset: Date(timeIntervalSince1970: fiveHReset),
            sevenDayUtilization: sevenDUtil,
            sevenDayReset: Date(timeIntervalSince1970: sevenDReset),
            isRateLimited: status != "allowed"
        )
    }

    private static func readCredentials() throws -> CredentialsFile.OAuth {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        // errSecItemNotFound: no hay sesión de Claude Code en este Mac. Cualquier
        // otro fallo (p.ej. errSecUserCanceled/errSecAuthFailed) significa que el
        // item existe pero macOS denegó el acceso al Keychain — la app no está
        // firmada con el mismo certificado que creó el item, así que el primer
        // arranque pide permiso al usuario vía el diálogo nativo del sistema.
        guard status != errSecItemNotFound else {
            throw LiveQuotaError.notLoggedIn
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LiveQuotaError.keychainAccessDenied
        }
        return try JSONDecoder().decode(CredentialsFile.self, from: data).claudeAiOauth
    }

    // Solo se decodifican los campos que necesitamos; el archivo de credenciales
    // de Claude Code trae más metadatos (scopes, tier de suscripción...) que no
    // hacen falta aquí.
    private struct CredentialsFile: Codable {
        struct OAuth: Codable {
            let accessToken: String
            let expiresAt: Double
        }
        let claudeAiOauth: OAuth
    }
}
