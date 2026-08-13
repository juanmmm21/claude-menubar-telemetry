import Foundation

// Una ventana de límite tal y como la sirve /api/oauth/usage: el porcentaje ya
// viene en escala 0-100, no como fracción.
struct UsageWindow: Equatable {
    let utilizationPercent: Double
    let resetsAt: Date?
}

// Ventana semanal acotada a un modelo concreto (Fable, Opus...). Anthropic las
// envía en el array `limits` con kind == "weekly_scoped".
struct ScopedUsageWindow: Equatable, Identifiable {
    let displayName: String
    let window: UsageWindow
    var id: String { displayName }
}

// Créditos de uso ("usage credits"): el saldo con el que se paga el consumo que
// ya no cabe en la cuota del plan — que es como se factura Fable desde que dejó
// de ir contra el límite semanal.
//
// Los importes vienen en unidades menores de la divisa (céntimos para EUR/USD).
// monthlyLimitMinorUnits == nil significa "sin tope mensual".
struct CreditStatus: Equatable {
    let isEnabled: Bool
    let monthlyLimitMinorUnits: Int?
    let usedMinorUnits: Int?
    let utilizationPercent: Double?
    let currencyCode: String
    let disabledReason: String?

    var remainingMinorUnits: Int? {
        guard let limit = monthlyLimitMinorUnits else { return nil }
        return max(limit - (usedMinorUnits ?? 0), 0)
    }
}

// Saldo prepago de la organización. Solo existe en cuentas que compran bolsas de
// crédito por adelantado; en una cuenta personal de suscripción el endpoint
// responde que no aplica y este dato queda a nil.
struct PrepaidBalance: Equatable {
    let balanceMinorUnits: Int
    let currencyCode: String
}

struct AccountUsage: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let modelWindows: [ScopedUsageWindow]
    let credits: CreditStatus?
    let prepaid: PrepaidBalance?

    // Ventana semanal del modelo cuyo nombre coincide con el buscado, si el
    // servidor la está publicando.
    func modelWindow(matching needle: String) -> ScopedUsageWindow? {
        let needle = needle.lowercased()
        return modelWindows.first { $0.displayName.lowercased().contains(needle) }
    }
}

enum LiveQuotaError: Error {
    case notLoggedIn            // No hay sesión de Claude Code en este Mac
    case authorizationRequired  // Falta el permiso del llavero; el usuario debe concederlo desde el panel
    case keychainAccessDenied   // El usuario denegó el diálogo del sistema
    case sessionExpired         // El token guardado caducó: solo Claude Code puede renovarlo
    case unauthorized           // La API rechazó el token
    case network(String)
    case unavailable            // Respuesta recibida pero ilegible
}

extension LiveQuotaError {
    // Distingue los fallos que el usuario puede resolver con un clic (conceder
    // el permiso del llavero) de los que no dependen de él.
    var isKeychainAuthorizationIssue: Bool {
        switch self {
        case .authorizationRequired, .keychainAccessDenied, .unauthorized: return true
        default: return false
        }
    }

    var userMessage: String {
        switch self {
        case .notLoggedIn:
            return "Sin sesión de Claude Code en este Mac"
        case .authorizationRequired:
            return "Falta el permiso del llavero"
        case .keychainAccessDenied:
            return "Permiso del llavero denegado"
        case .sessionExpired:
            return "Sesión de Claude Code caducada — ábrelo para renovarla"
        case .unauthorized:
            return "Anthropic rechazó el token — vuelve a autorizar"
        case .network(let detail):
            return "Sin conexión con Anthropic (\(detail))"
        case .unavailable:
            return "Dato en vivo no disponible ahora mismo"
        }
    }
}

// Lee el uso real de la cuenta reutilizando la sesión OAuth que Claude Code ya
// tiene guardada en este Mac.
//
// La fuente es GET /api/oauth/usage, el mismo endpoint que alimenta al comando
// /usage del CLI: no consume cuota (antes esta app mandaba un /v1/messages de
// un token solo para leer las cabeceras de rate limit) y trae bastante más
// dato — ventanas por modelo y estado de los créditos de uso. No es API pública
// documentada, así que si Anthropic la cambia la app se queda sin dato en vivo y
// cae de vuelta a la estimación local por logs (ver TelemetryManager).
final class AccountUsageService {
    private static let host = "https://api.anthropic.com"

    private let session: URLSession
    private let store: ClaudeSessionStore

    init(session: URLSession = URLSession(configuration: .ephemeral),
         store: ClaudeSessionStore = ClaudeSessionStore()) {
        self.session = session
        self.store = store
    }

    // `allowingKeychainPrompt: false` en los sondeos periódicos, para que el
    // diálogo del llavero no interrumpa al usuario por sorpresa.
    func fetchAccountUsage(allowingKeychainPrompt: Bool,
                           completion: @escaping (Result<AccountUsage, LiveQuotaError>) -> Void) {
        let claudeSession: ClaudeSession
        do {
            claudeSession = try store.session(allowingPrompt: allowingKeychainPrompt)
        } catch let error as SessionError {
            completion(.failure(Self.map(error)))
            return
        } catch {
            completion(.failure(.unavailable))
            return
        }

        let request = authorizedRequest(path: "/api/oauth/usage", token: claudeSession.accessToken)

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.unavailable))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                // El token cacheado ya no vale: el siguiente intento debe volver
                // al llavero de Claude Code a por uno nuevo.
                self.store.invalidateCachedSession()
                completion(.failure(.unauthorized))
                return
            }
            guard http.statusCode == 200,
                  let data = data,
                  let payload = try? JSONDecoder().decode(UsagePayload.self, from: data) else {
                completion(.failure(.unavailable))
                return
            }

            let usage = payload.toAccountUsage(prepaid: nil)

            // El saldo prepago es un extra: si no aplica a esta cuenta, se
            // entrega el resto del dato igualmente.
            guard let orgUUID = LocalAccountInfo.organizationUUID() else {
                completion(.success(usage))
                return
            }
            self.fetchPrepaidBalance(orgUUID: orgUUID, token: claudeSession.accessToken) { prepaid in
                completion(.success(payload.toAccountUsage(prepaid: prepaid)))
            }
        }.resume()
    }

    private func fetchPrepaidBalance(orgUUID: String,
                                     token: String,
                                     completion: @escaping (PrepaidBalance?) -> Void) {
        var request = authorizedRequest(
            path: "/api/oauth/organizations/\(orgUUID)/prepaid/credits",
            token: token
        )
        request.setValue(orgUUID, forHTTPHeaderField: "x-organization-uuid")

        session.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let payload = try? JSONDecoder().decode(PrepaidPayload.self, from: data),
                  let cents = payload.amount ?? payload.balanceCents else {
                completion(nil)
                return
            }
            completion(PrepaidBalance(
                balanceMinorUnits: cents,
                currencyCode: payload.currency?.uppercased() ?? "USD"
            ))
        }.resume()
    }

    private func authorizedRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.host + path)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func map(_ error: SessionError) -> LiveQuotaError {
        switch error {
        case .notLoggedIn: return .notLoggedIn
        case .authorizationRequired: return .authorizationRequired
        case .accessDenied: return .keychainAccessDenied
        case .expired: return .sessionExpired
        case .malformed: return .unavailable
        }
    }
}

// MARK: - Respuesta de /api/oauth/usage

private struct UsagePayload: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: FlexibleDate?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var asUsageWindow: UsageWindow? {
            guard let utilization = utilization else { return nil }
            return UsageWindow(utilizationPercent: utilization, resetsAt: resetsAt?.date)
        }
    }

    struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?
        let currency: String?
        let disabledReason: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization
            case currency
            case disabledReason = "disabled_reason"
        }
    }

    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Named: Decodable { let displayName: String?

                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            let model: Named?
        }

        let kind: String?
        let percent: Double?
        let resetsAt: FlexibleDate?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let extraUsage: ExtraUsage?
    let limits: [Limit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    func toAccountUsage(prepaid: PrepaidBalance?) -> AccountUsage {
        let currency = extraUsage?.currency?.uppercased() ?? prepaid?.currencyCode ?? "USD"

        let credits = extraUsage.map { extra in
            CreditStatus(
                isEnabled: extra.isEnabled ?? false,
                monthlyLimitMinorUnits: extra.monthlyLimit.map { Int($0.rounded()) },
                usedMinorUnits: extra.usedCredits.map { Int($0.rounded()) },
                utilizationPercent: extra.utilization,
                currencyCode: currency,
                disabledReason: extra.disabledReason
            )
        }

        let scoped: [ScopedUsageWindow] = (limits ?? []).compactMap { limit in
            guard limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.displayName,
                  let percent = limit.percent else { return nil }
            return ScopedUsageWindow(
                displayName: name,
                window: UsageWindow(utilizationPercent: percent, resetsAt: limit.resetsAt?.date)
            )
        }

        return AccountUsage(
            fiveHour: fiveHour?.asUsageWindow,
            sevenDay: sevenDay?.asUsageWindow,
            sevenDayOpus: sevenDayOpus?.asUsageWindow,
            sevenDaySonnet: sevenDaySonnet?.asUsageWindow,
            modelWindows: scoped,
            credits: credits,
            prepaid: prepaid
        )
    }
}

private struct PrepaidPayload: Decodable {
    let amount: Int?
    let balanceCents: Int?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case amount, currency
        case balanceCents = "balance_cents"
    }
}

// resets_at llega como texto ISO-8601 en el endpoint de uso, pero el mismo campo
// viaja como epoch en segundos en otras respuestas de Anthropic. Se aceptan los
// dos para que un cambio de formato no deje la fila sin fecha.
private struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
            return
        }
        let text = try container.decode(String.self)
        date = FlexibleDate.parse(text)
    }

    private static func parse(_ text: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

// MARK: - Datos de cuenta que Claude Code deja en claro en disco

// El UUID de organización hace falta para el endpoint de saldo prepago. Claude
// Code lo escribe en ~/.claude.json, así que se lee de ahí en vez de gastar una
// llamada extra a /api/oauth/profile.
enum LocalAccountInfo {
    static func organizationUUID() -> String? {
        let path = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")

        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let uuid = account["organizationUuid"] as? String,
              !uuid.isEmpty else {
            return nil
        }
        return uuid
    }
}
