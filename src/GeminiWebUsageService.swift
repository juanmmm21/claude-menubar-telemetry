import Cocoa
import WebKit

// Una de las dos barras de gemini.google.com/usage.
struct GeminiAppWindow: Equatable {
    let usedPercent: Double
    let resetsAt: Date?
    let resetText: String?   // Texto tal cual, por si la fecha no se pudo interpretar
}

// Uso de la app de Gemini (web, móvil, Android...): el mismo dato que enseña
// gemini.google.com/usage. Google lo mide como un cupo de cómputo que se
// renueva cada 5 horas con un tope semanal, no como número de prompts.
struct GeminiAppUsage: Equatable {
    let current: GeminiAppWindow?
    let weekly: GeminiAppWindow?
    let planName: String?
}

enum GeminiAppUsageState: Equatable {
    case unknown
    case needsLogin
    case unavailable(String)
    case loaded(GeminiAppUsage)
}

// Lee el uso de la app de Gemini cargando gemini.google.com/usage en un
// WKWebView invisible y extrayendo el texto de la página.
//
// Google no publica ninguna API para este dato: solo existe esa página, y
// solo con una sesión de Google iniciada. Para no tocar las cookies del
// navegador (las de Chrome están cifradas con una clave del llavero y
// volverían a salir diálogos de contraseña), la app tiene su propia sesión:
// el usuario entra una vez en una ventana de la app y WebKit guarda las cookies
// en el almacén de esta app. La página no es API estable; si Google la cambia,
// el estado pasa a .unavailable y el resto de la app sigue funcionando.
//
// Todo en el hilo principal: WebKit lo exige.
final class GeminiWebUsageService: NSObject, WKNavigationDelegate {
    private static let usageURL = URL(string: "https://gemini.google.com/usage")!
    private static let loginURL = URL(string:
        "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fusage"
    )!

    // Google rechaza el inicio de sesión en navegadores que se identifican como
    // vista web incrustada; con la firma de Safari lo trata como el navegador
    // normal que en el fondo es.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private var backgroundWebView: WKWebView?
    private var pendingCompletion: ((GeminiAppUsageState) -> Void)?
    private var pollTimer: Timer?
    private var pollAttempts = 0

    private var loginWindow: NSWindow?
    private var loginWebView: WKWebView?
    private var onLoginFinished: (() -> Void)?

    // MARK: - Lectura

    func fetchUsage(completion: @escaping (GeminiAppUsageState) -> Void) {
        // Ya hay una lectura en marcha: su resultado llegará igualmente.
        guard pendingCompletion == nil else { return }
        pendingCompletion = completion

        hasGoogleSession { [weak self] hasSession in
            guard let self = self else { return }
            guard hasSession else {
                self.finish(.needsLogin)
                return
            }
            let webView = self.makeWebView()
            self.backgroundWebView = webView
            webView.load(URLRequest(url: Self.usageURL))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === loginWebView {
            loginNavigationFinished(webView)
            return
        }
        guard webView === backgroundWebView else { return }

        if webView.url?.host?.hasSuffix("accounts.google.com") == true {
            finish(.needsLogin)
            return
        }
        startPolling(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === backgroundWebView else { return }
        finish(.unavailable("Sin conexión con Google"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === backgroundWebView else { return }
        finish(.unavailable("Sin conexión con Google"))
    }

    // La página es una app de una sola página: el HTML llega vacío y los
    // porcentajes aparecen cuando termina su propia petición. Se pregunta por
    // el texto cada medio segundo durante unos segundos.
    private func startPolling(_ webView: WKWebView) {
        pollTimer?.invalidate()
        pollAttempts = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self, weak webView] _ in
            guard let self = self, let webView = webView else { return }
            self.pollAttempts += 1
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, _ in
                // Respuesta tardía de una lectura que ya terminó.
                guard webView === self.backgroundWebView else { return }
                let text = result as? String ?? ""
                if let usage = GeminiUsagePageParser.parse(text) {
                    self.finish(.loaded(usage))
                } else if self.pollAttempts >= 40 {
                    let onUsagePage = webView.url?.path.hasPrefix("/usage") == true
                    self.finish(.unavailable(onUsagePage
                        ? "No se pudo leer gemini.google.com/usage"
                        : "Tu cuenta no tiene la página de uso de Gemini"))
                }
            }
        }
        // .common para que siga corriendo mientras el popover está abierto.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func finish(_ state: GeminiAppUsageState) {
        pollTimer?.invalidate()
        pollTimer = nil
        backgroundWebView?.stopLoading()
        backgroundWebView = nil

        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(state)
    }

    // MARK: - Sesión de Google

    private func hasGoogleSession(_ completion: @escaping (Bool) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let signedIn = cookies.contains { cookie in
                cookie.domain.hasSuffix("google.com") &&
                    (cookie.name == "SID" || cookie.name == "__Secure-1PSID")
            }
            completion(signedIn)
        }
    }

    func presentLogin(onFinished: @escaping () -> Void) {
        onLoginFinished = onFinished

        if let window = loginWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let webView = makeWebView()
        loginWebView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Conectar cuenta de Google"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        loginWindow = window

        webView.load(URLRequest(url: Self.loginURL))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // En cuanto Google devuelve al usuario a gemini.google.com, la sesión ya
    // está guardada: se cierra la ventana y se lee el uso.
    private func loginNavigationFinished(_ webView: WKWebView) {
        guard webView.url?.host == "gemini.google.com" else { return }
        loginWindow?.close()
        loginWindow = nil
        loginWebView = nil

        let callback = onLoginFinished
        onLoginFinished = nil
        callback?()
    }

    // Borra la sesión de Google que guarda la app (no la del navegador).
    func signOut(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let google = records.filter { $0.displayName.contains("google") }
            store.removeData(ofTypes: types, for: google, completionHandler: completion)
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 900), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        return webView
    }
}

// Saca los dos porcentajes y sus fechas de reset del texto de la página.
//
// No se ata a los títulos ("Uso actual", "Límite semanal") porque cambian con
// el idioma de la cuenta. Se apoya en el orden: la página pinta primero el
// cupo actual y después el semanal, cada uno con un "N % usado" y una línea
// "Se restablece ..." / "Resets ...".
enum GeminiUsagePageParser {
    static func parse(_ text: String, now: Date = Date()) -> GeminiAppUsage? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Hasta que no están las dos tarjetas, la página no ha terminado de pintar.
        let percents = lines.compactMap { percentage(in: $0) }
        guard percents.count >= 2 else { return nil }

        let resetLines = lines.filter(isResetLine)
        func window(_ index: Int) -> GeminiAppWindow? {
            guard index < percents.count else { return nil }
            let resetText = index < resetLines.count ? resetLines[index] : nil
            return GeminiAppWindow(
                usedPercent: percents[index],
                resetsAt: resetText.flatMap { resetDate(from: $0, now: now) },
                resetText: resetText
            )
        }

        // La insignia del plan es una línea suelta en mayúsculas.
        let plan = lines.first { ["PLUS", "PRO", "ULTRA"].contains($0.uppercased()) && $0 == $0.uppercased() }

        return GeminiAppUsage(current: window(0), weekly: window(1), planName: plan)
    }

    // "0 % usado", "37% used", "12,5 % usado"
    private static func percentage(in line: String) -> Double? {
        guard let match = firstMatch(#"(\d{1,3}(?:[.,]\d+)?)\s*%"#, in: line) else { return nil }
        return Double(match[0].replacingOccurrences(of: ",", with: "."))
    }

    private static func isResetLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("restablece") || lower.contains("reset") || lower.contains("renueva")
    }

    // "Se restablece a las 19:30", "Se restablece el 27 oct a las 20:30",
    // "Resets at 7:30 PM", "Resets Oct 27 at 8:30 PM"
    static func resetDate(from line: String, now: Date) -> Date? {
        let lower = line.lowercased()
        guard let time = firstMatch(#"(\d{1,2})[:.](\d{2})\s*([ap])?\.?\s?m?\.?"#, in: lower),
              var hour = Int(time[0]),
              let minute = Int(time[1]) else {
            return nil
        }
        if time.count > 2, let meridiem = time[2].first {
            if meridiem == "p" && hour < 12 { hour += 12 }
            if meridiem == "a" && hour == 12 { hour = 0 }
        }

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute

        if let (day, month) = dayAndMonth(in: lower) {
            components.day = day
            components.month = month
            guard var date = calendar.date(from: components) else { return nil }
            // Un reset de enero visto en diciembre es del año que viene.
            if date < now.addingTimeInterval(-24 * 3600) {
                date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
            }
            return date
        }

        guard var date = calendar.date(from: components) else { return nil }
        if date < now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    private static let months: [String: Int] = [
        "ene": 1, "jan": 1, "feb": 2, "mar": 3, "abr": 4, "apr": 4, "may": 5,
        "jun": 6, "jul": 7, "ago": 8, "aug": 8, "sep": 9, "oct": 10, "nov": 11,
        "dic": 12, "dec": 12
    ]

    private static func dayAndMonth(in lower: String) -> (Int, Int)? {
        let monthPattern = "(ene|jan|feb|mar|abr|apr|may|jun|jul|ago|aug|sep|oct|nov|dic|dec)[a-z]*\\.?"
        // "27 oct", "27 de octubre"
        if let match = firstMatch("(\\d{1,2})\\s+(?:de\\s+)?" + monthPattern, in: lower),
           let day = Int(match[0]), let month = months[match[1]] {
            return (day, month)
        }
        // "oct 27"
        if let match = firstMatch("\\b" + monthPattern + "\\s+(\\d{1,2})\\b", in: lower),
           let month = months[match[0]], let day = Int(match[1]) {
            return (day, month)
        }
        return nil
    }

    // Grupos capturados de la primera coincidencia (los que no participan se omiten).
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                groups.append(String(text[range]))
            }
        }
        return groups
    }
}
