import Cocoa
import WebKit

// Saldo de créditos de la API de OpenAI: el mismo que enseña
// platform.openai.com/settings/organization/billing/overview.
struct OpenAIBalance: Equatable {
    let amount: Double       // Saldo restante; negativo si se ha gastado de más
    let displayText: String  // Tal cual lo pinta la página, con su divisa: "$4.83"
}

enum OpenAIBalanceState: Equatable {
    case unknown
    case needsLogin
    case unavailable(String)
    case loaded(OpenAIBalance)
}

// Lee el saldo cargando la página de facturación de OpenAI en un WKWebView
// invisible y extrayendo el texto de la página.
//
// OpenAI no publica ninguna API para el saldo. El endpoint interno que usan
// otras herramientas (dashboard/billing/credit_grants) rechaza las claves de
// proyecto (sk-proj-…), que son las únicas que se pueden crear hoy. Así que,
// como con Gemini, la app tiene su propia sesión de platform.openai.com: el
// usuario entra una vez en una ventana de la app y WebKit guarda la sesión en
// el almacén de esta app. No hace falta ninguna clave de API. La página no es
// API estable; si OpenAI la cambia, el estado pasa a .unavailable y el resto
// de la app sigue funcionando.
//
// Todo en el hilo principal: WebKit lo exige.
final class OpenAIBillingService: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let billingURL = URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
    private static let loginURL = URL(string: "https://platform.openai.com/login")!
    private static let connectedKey = "openAIConnected"

    // Con la firma de Safari, los proveedores de inicio de sesión (Google,
    // Apple, Microsoft) tratan la vista web como el navegador normal que es.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private var backgroundWebView: WKWebView?
    private var pendingCompletion: ((OpenAIBalanceState) -> Void)?
    private var pollTimer: Timer?
    private var pollAttempts = 0

    private var loginWindow: NSWindow?
    private var loginWebView: WKWebView?
    private var loginURLObservation: NSKeyValueObservation?
    private var loginCloseScheduled = false
    private var onLoginFinished: (() -> Void)?

    // Solo se carga la página si se conectó la cuenta: sin eso, la sección
    // ofrece conectar sin abrir nada en segundo plano.
    private var isConnected: Bool {
        get { UserDefaults.standard.bool(forKey: Self.connectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.connectedKey) }
    }

    // MARK: - Lectura

    func fetchBalance(completion: @escaping (OpenAIBalanceState) -> Void) {
        // Ya hay una lectura en marcha: su resultado llegará igualmente.
        guard pendingCompletion == nil else { return }
        guard isConnected else {
            completion(.needsLogin)
            return
        }
        pendingCompletion = completion

        let webView = makeWebView()
        backgroundWebView = webView
        webView.load(URLRequest(url: Self.billingURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // El fin del inicio de sesión se detecta por la URL (ver presentLogin).
        guard webView === backgroundWebView else { return }
        startPolling(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === backgroundWebView else { return }
        finish(.unavailable("Sin conexión con OpenAI"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === backgroundWebView else { return }
        finish(.unavailable("Sin conexión con OpenAI"))
    }

    // Enlaces que abren ventana nueva (algunos botones de inicio de sesión):
    // se cargan en la misma vista en vez de perderse.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // La página es una app de una sola página: el HTML llega vacío, el saldo
    // aparece cuando termina su propia petición y, sin sesión, la propia app
    // redirige al inicio de sesión. Se mira la URL y el texto cada medio
    // segundo durante unos segundos.
    private func startPolling(_ webView: WKWebView) {
        pollTimer?.invalidate()
        pollAttempts = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self, weak webView] _ in
            guard let self = self, let webView = webView else { return }
            self.pollAttempts += 1

            if Self.isLoginPage(webView.url) {
                // La sesión caducó o se cerró desde la web.
                self.isConnected = false
                self.finish(.needsLogin)
                return
            }

            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, _ in
                // Respuesta tardía de una lectura que ya terminó.
                guard webView === self.backgroundWebView else { return }
                let text = result as? String ?? ""
                if let balance = OpenAIBillingPageParser.parse(text) {
                    self.finish(.loaded(balance))
                } else if self.pollAttempts >= 50 {
                    self.finish(.unavailable("No se pudo leer el saldo de platform.openai.com"))
                }
            }
        }
        // .common para que siga corriendo mientras el popover está abierto.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func finish(_ state: OpenAIBalanceState) {
        pollTimer?.invalidate()
        pollTimer = nil
        backgroundWebView?.stopLoading()
        backgroundWebView = nil

        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(state)
    }

    // auth.openai.com, /login, /signup y /auth/callback son parte del inicio
    // de sesión, no de la plataforma.
    private static func isLoginPage(_ url: URL?) -> Bool {
        guard let url = url, let host = url.host else { return false }
        if host.hasPrefix("auth.") { return true }
        return ["/login", "/signup", "/auth"].contains { url.path.hasPrefix($0) }
    }

    // MARK: - Sesión de OpenAI

    func presentLogin(onFinished: @escaping () -> Void) {
        onLoginFinished = onFinished

        if let window = loginWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let webView = makeWebView()
        loginWebView = webView
        loginCloseScheduled = false
        // Tras el inicio de sesión, la plataforma cambia de página sin una
        // navegación completa, así que se vigila la URL en vez de didFinish.
        loginURLObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.loginURLChanged(webView)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Conectar cuenta de OpenAI"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        loginWindow = window

        webView.load(URLRequest(url: Self.loginURL))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // En cuanto OpenAI devuelve al usuario a la plataforma, la sesión está
    // casi lista: la página termina de guardarla justo después, así que se
    // espera un momento antes de cerrar la ventana y leer el saldo.
    private func loginURLChanged(_ webView: WKWebView) {
        guard webView === loginWebView, !loginCloseScheduled,
              let url = webView.url, url.host == "platform.openai.com",
              !Self.isLoginPage(url) else {
            return
        }
        loginCloseScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.completeLogin()
        }
    }

    private func completeLogin() {
        isConnected = true
        loginURLObservation = nil
        loginWindow?.close()
        loginWindow = nil
        loginWebView = nil

        let callback = onLoginFinished
        onLoginFinished = nil
        callback?()
    }

    // Borra la sesión de OpenAI que guarda la app (no la del navegador).
    func signOut(completion: @escaping () -> Void) {
        isConnected = false
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let openAI = records.filter { $0.displayName.contains("openai") }
            store.removeData(ofTypes: types, for: openAI, completionHandler: completion)
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }
}

// Saca el saldo del texto de la página de facturación: la etiqueta
// "Credit balance" seguida del importe, en la misma línea o en las siguientes.
enum OpenAIBillingPageParser {
    static func parse(_ text: String) -> OpenAIBalance? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let labelIndex = lines.firstIndex(where: isBalanceLabel) else { return nil }
        for line in lines[labelIndex..<min(labelIndex + 4, lines.count)] {
            if let balance = amount(in: line) {
                return balance
            }
        }
        return nil
    }

    private static func isBalanceLabel(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("credit balance") || lower.contains("saldo de crédito")
    }

    // "$4.83", "$1,234.50", "-$0.12", "$-0.12", "€10.00"
    private static let amountPattern = #"([-−]?)\s*([$€£])\s?([-−]?)(\d[\d,]*(?:\.\d+)?)"#

    private static func amount(in line: String) -> OpenAIBalance? {
        guard let regex = try? NSRegularExpression(pattern: amountPattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let whole = Range(match.range, in: line),
              let digits = Range(match.range(at: 4), in: line),
              let value = Double(line[digits].replacingOccurrences(of: ",", with: "")) else {
            return nil
        }
        let isNegative = [1, 3].contains { index in
            Range(match.range(at: index), in: line).map { !line[$0].isEmpty } ?? false
        }
        return OpenAIBalance(
            amount: isNegative ? -value : value,
            displayText: line[whole].trimmingCharacters(in: .whitespaces)
        )
    }
}
