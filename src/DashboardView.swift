import SwiftUI

typealias StatusBadge = (label: String, color: Color)

struct DashboardView: View {
    @ObservedObject var manager: TelemetryManager

    // Live timer to refresh countdowns and checks every second without scanning logs
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // Hora de referencia de las cuentas atrás y del parpadeo del cursor de la
    // cabecera: al cambiar cada segundo, los vuelve a pintar.
    @State private var now = Date()

    // Cajones plegables: el detalle por modelo y los ajustes no hacen falta
    // para el vistazo rápido.
    @State private var showModels: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerView

            separator

            // Sin ScrollView: el panel mide exactamente lo que ocupa el
            // contenido y AppDelegate hace que el popover tome ese tamaño. Para
            // que nunca se salga de la pantalla, los cajones son excluyentes y
            // las tablas enseñan solo los modelos con más uso.
            VStack(alignment: .leading, spacing: 16) {
                claudeSection
                geminiSection
                openAISection

                DashedLine()

                VStack(alignment: .leading, spacing: 10) {
                    drawerToggle(title: "MODELOS", isOpen: showModels) {
                        showModels.toggle()
                        if showModels { showSettings = false }
                    }
                    if showModels {
                        modelsDrawer
                    }

                    drawerToggle(title: "CONFIG", isOpen: showSettings) {
                        showSettings.toggle()
                        if showSettings { showModels = false }
                    }
                    if showSettings {
                        settingsDrawer
                    }
                }
            }
            .padding(16)

            separator

            footerView
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .foregroundColor(Theme.textPrimary)
        .onReceive(timer) { date in
            now = date
            manager.updateBlockStateIfNeeded() // Checks timeline for real-time status transitions
        }
    }

    // MARK: - Cabecera

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Text(">")
                    Text("_")
                        .opacity(cursorVisible ? 1 : 0.15)
                }
                .foregroundColor(Theme.accent)
                .font(Theme.monospaced(15, weight: .bold))

                Text("AI_TELEMETRY")
                    .font(Theme.monospaced(14, weight: .bold))
            }

            Spacer()

            statusPill(overallStatus)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var cursorVisible: Bool {
        Int(now.timeIntervalSince1970) % 2 == 0
    }

    // MARK: - Claude

    private var claudeSection: some View {
        providerSection("CLAUDE", color: Theme.claude, status: claudeStatus, comment: claudeScopeComment) {
            meterRow(
                "SESION_5H",
                percent: Double(displaySessionPercent),
                caption: sessionResetCaption,
                color: Theme.claude
            )
            DashedLine()
            meterRow(
                "SEMANA",
                percent: weeklyAllPercent,
                caption: manager.accountUsage?.sevenDay?.resetsAt.map { resetCaption($0) },
                color: Theme.claude
            )
            claudeModelWindows
            claudeCreditRows
        }
    }

    // Cada ventana semanal por modelo que sirva Anthropic. Cuando no hay
    // ninguna, se muestra el contador local de Fable en vez de inventarse un
    // porcentaje (si está activado en CONFIG).
    @ViewBuilder
    private var claudeModelWindows: some View {
        if let modelWindows = manager.accountUsage?.modelWindows, !modelWindows.isEmpty {
            ForEach(modelWindows) { scoped in
                DashedLine()
                meterRow(
                    "SEM_" + snakeCase(scoped.displayName, dropping: "CLAUDE"),
                    percent: min(scoped.window.utilizationPercent, 100.0),
                    caption: scoped.window.resetsAt.map { resetCaption($0) },
                    color: Theme.claude
                )
            }
        } else if manager.showClaudeExtras {
            DashedLine()
            valueRow(
                "FABLE_7D",
                value: "\(manager.fableRequests) prompts · \(formatNumber(manager.fableInputTokens + manager.fableOutputTokens)) tok"
            )
        }
    }

    // Créditos de uso (con lo que se paga Fable al agotar la cuota del plan)
    // y saldo prepago, solo si están activados en CONFIG. Sin dato en vivo no
    // se pinta nada: el comentario de la sección ya explica por qué.
    @ViewBuilder
    private var claudeCreditRows: some View {
        if manager.showClaudeExtras {
            claudeCreditDetails
        }
    }

    @ViewBuilder
    private var claudeCreditDetails: some View {
        if let credits = manager.accountUsage?.credits {
            DashedLine()
            if credits.isEnabled {
                let used = credits.usedMinorUnits ?? 0
                let usedText = formatMoney(used, currency: credits.currencyCode)

                if let limit = credits.monthlyLimitMinorUnits {
                    let pct = min(credits.utilizationPercent ?? percentage(used, of: limit), 100.0)
                    valueRow(
                        "CREDITOS",
                        value: "\(usedText) / \(formatMoney(limit, currency: credits.currencyCode))",
                        valueColor: levelColor(for: pct, base: Theme.textPrimary)
                    )
                } else {
                    valueRow("CREDITOS", value: "\(usedText) · sin tope")
                }
            } else {
                valueRow("CREDITOS", value: creditsDisabledLabel(credits.disabledReason), valueColor: Theme.warning)
            }
        }

        if let prepaid = manager.accountUsage?.prepaid {
            DashedLine()
            valueRow("PREPAGO", value: formatMoney(prepaid.balanceMinorUnits, currency: prepaid.currencyCode))
        }
    }

    // MARK: - Gemini

    private var geminiSection: some View {
        providerSection("GEMINI", color: Theme.gemini, status: geminiStatus, comment: geminiScopeComment) {
            geminiAppRows

            // Gemini CLI solo aparece si se usa: cuota por modelo si hay
            // sesión del CLI, y actividad local si hay logs.
            if let models = manager.geminiUsage?.models, !models.isEmpty {
                ForEach(models) { model in
                    DashedLine()
                    meterRow(
                        "CLI_" + snakeCase(GeminiModelNames.displayName(model.modelId), dropping: "GEMINI"),
                        percent: model.usedPercent,
                        caption: model.resetsAt.map { resetCaption($0) },
                        color: Theme.gemini
                    )
                }
            }
            if manager.geminiLocal.prompts7d > 0 {
                DashedLine()
                valueRow(
                    "CLI_24H",
                    value: "\(manager.geminiLocal.prompts24h) prompts · \(formatNumber(manager.geminiLocal.tokens24h)) tok"
                )
            }
        }
    }

    // Uso de la app de Gemini (gemini.google.com/usage): cupo actual, que se
    // renueva cada 5 horas, y límite semanal.
    @ViewBuilder
    private var geminiAppRows: some View {
        switch manager.geminiApp {
        case .loaded(let usage):
            meterRow(
                "SESION_5H",
                percent: usage.current?.usedPercent ?? 0,
                caption: geminiResetCaption(usage.current),
                color: Theme.gemini
            )
            DashedLine()
            meterRow(
                "SEMANA",
                percent: usage.weekly?.usedPercent ?? 0,
                caption: geminiResetCaption(usage.weekly),
                color: Theme.gemini
            )
        case .needsLogin:
            Button(action: {
                manager.connectGoogleAccount()
            }) {
                valueRow("CUENTA_GOOGLE", value: "conectar →", valueColor: Theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .unknown:
            valueRow("APP_GEMINI", value: "consultando…", valueColor: Theme.textSecondary)
        case .unavailable:
            valueRow("APP_GEMINI", value: "sin dato", valueColor: Theme.textSecondary)
        }
    }

    // MARK: - OpenAI

    private var openAISection: some View {
        providerSection("OPENAI", color: Theme.openAI, status: openAIStatus, comment: openAIScopeComment) {
            switch manager.openAIBalance {
            case .loaded(let balance):
                valueRow(
                    "SALDO_API",
                    value: balance.displayText,
                    valueColor: balance.amount <= 0 ? Theme.error : Theme.textPrimary
                )
            case .needsLogin:
                Button(action: {
                    manager.connectOpenAIAccount()
                }) {
                    valueRow("CUENTA_OPENAI", value: "conectar →", valueColor: Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .unknown:
                valueRow("SALDO_API", value: "consultando…", valueColor: Theme.textSecondary)
            case .unavailable:
                valueRow("SALDO_API", value: "sin dato", valueColor: Theme.textSecondary)
            }
        }
    }

    // MARK: - Cajones

    private var modelsDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelTable(
                title: "CLAUDE · histórico",
                rows: manager.modelUsageBreakdown,
                color: Theme.claude
            ) { $0.contains("Fable") }

            if !manager.geminiLocal.models7d.isEmpty {
                modelTable(
                    title: "GEMINI CLI · 7 días",
                    rows: manager.geminiLocal.models7d,
                    color: Theme.gemini
                ) { $0.contains("Pro") }
            }
        }
    }

    private var settingsDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if manager.launchAtLoginSupported {
                switchRow("INICIAR_CON_MACOS", isOn: $manager.launchAtLoginEnabled)
                DashedLine()
            }

            switchRow(
                "EXTRAS_CLAUDE",
                comment: "fable, créditos de uso y saldo prepago",
                isOn: $manager.showClaudeExtras
            )
            DashedLine()

            if manager.geminiApp != .needsLogin {
                disconnectRow("DESCONECTAR_GOOGLE") {
                    manager.disconnectGoogleAccount()
                }
                DashedLine()
            }

            if manager.openAIBalance != .needsLogin {
                disconnectRow("DESCONECTAR_OPENAI") {
                    manager.disconnectOpenAIAccount()
                }
                DashedLine()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("// límites de respaldo de Claude: solo se usan sin dato en vivo de la cuenta")
                    .font(Theme.monospaced(10))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                stepperRow("SESION_5H", value: $manager.fiveHourLimit, step: 5, range: 10...200)
                stepperRow("SEMANA", value: $manager.weeklyLimit, step: 100, range: 200...5000)
            }
            .padding(12)
        }
        .panel()
    }

    private func disconnectRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(Theme.error)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func drawerToggle(title: String, isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                action()
            }
        }) {
            HStack {
                Text(isOpen ? "[-] \(title)" : "[+] \(title)")
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(Theme.accent)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pie

    private var footerView: some View {
        HStack(spacing: 8) {
            if manager.isScanning {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            } else {
                Button(action: {
                    manager.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Actualizar")
            }

            Text("SYNC \(formatTime(manager.lastRefreshed))")
                .font(Theme.monospaced(10))
                .foregroundColor(Theme.textSecondary)

            Spacer()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("QUIT")
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(Theme.error)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.error.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Theme.error.opacity(0.5), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Piezas reutilizables

    private var separator: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
    }

    private func providerSection<Content: View>(_ name: String,
                                                color: Color,
                                                status: StatusBadge,
                                                comment: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(">")
                        .foregroundColor(color)
                    Text(name)
                    Spacer()
                    statusPill(status)
                }
                .font(Theme.monospaced(13, weight: .bold))

                Text("// \(comment)")
                    .font(Theme.monospaced(10))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    private func statusPill(_ status: StatusBadge) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(Theme.monospaced(10, weight: .bold))
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(status.color.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(status.color.opacity(0.4), lineWidth: 1)
        )
    }

    // Un límite: etiqueta y cuándo se renueva a la izquierda, el % grande a la
    // derecha y la barra entera debajo. El % va en el color del texto y solo
    // cambia (con un icono de aviso, para no depender del color) desde el 70 %.
    private func meterRow(_ label: String, percent: Double, caption: String?, color: Color) -> some View {
        let isHigh = percent >= 70

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(Theme.monospaced(12, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let caption = caption {
                        Text(caption)
                            .font(Theme.monospaced(10))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    if isHigh {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(levelColor(for: percent, base: color))
                            .padding(.trailing, 4)
                    }
                    Text("\(Int(percent))")
                        .font(Theme.monospaced(20, weight: .bold))
                        .foregroundColor(levelColor(for: percent, base: Theme.textPrimary))
                    Text("%")
                        .font(Theme.monospaced(12, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            UsageBar(percent: percent, color: levelColor(for: percent, base: color))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private func valueRow(_ label: String, value: String, valueColor: Color = Theme.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(Theme.monospaced(12, weight: .bold))
                .fixedSize()

            DashedLine(dash: [1, 3])

            Text(value)
                .font(Theme.monospaced(12, weight: .bold))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private func switchRow(_ title: String, comment: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.monospaced(11, weight: .bold))
                if let comment = comment {
                    Text("// \(comment)")
                        .font(Theme.monospaced(10))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func modelTable(title: String,
                            rows: [ModelUsage],
                            color: Color,
                            highlight: @escaping (String) -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .foregroundColor(color)
                Spacer()
                Text("PROMPTS")
                    .frame(width: 64, alignment: .trailing)
                Text("TOKENS")
                    .frame(width: 64, alignment: .trailing)
            }
            .font(Theme.monospaced(10, weight: .bold))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if rows.isEmpty {
                DashedLine()
                Text("Sin actividad en los logs.")
                    .font(Theme.monospaced(11))
                    .foregroundColor(Theme.textSecondary)
                    .padding(12)
            } else {
                ForEach(Array(rows.prefix(Self.maxModelRows))) { usage in
                    DashedLine()
                    HStack {
                        Text(usage.modelName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text("\(usage.requestsCount)")
                            .frame(width: 64, alignment: .trailing)
                        Text(formatNumber(usage.inputTokens + usage.outputTokens))
                            .frame(width: 64, alignment: .trailing)
                            .foregroundColor(highlight(usage.modelName) ? color : Theme.textPrimary)
                    }
                    .font(Theme.monospaced(11))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .panel()
    }

    private func stepperRow(_ title: String, value: Binding<Int>, step: Int, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.monospaced(11, weight: .bold))
            Spacer()
            Text("\(value.wrappedValue)")
                .font(Theme.monospaced(12, weight: .bold))
            Stepper(title, value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    // Filas por tabla de modelos, para que el panel quepa en pantalla.
    private static let maxModelRows = 6

    // MARK: - Estado

    private var claudeStatus: StatusBadge {
        if isSessionLimitReached { return ("RATE_LIMITED", Theme.error) }
        if displaySessionPercent >= 90 { return ("HIGH_USAGE", Theme.warning) }
        return hasLiveSessionWindow ? ("LIVE", Theme.success) : ("LOGS_ONLY", Theme.textSecondary)
    }

    private var geminiStatus: StatusBadge {
        if isGeminiLimitReached { return ("RATE_LIMITED", Theme.error) }
        if (geminiMaxUsedPercent ?? 0) >= 90 { return ("HIGH_USAGE", Theme.warning) }
        switch manager.geminiApp {
        case .loaded:
            return ("LIVE", Theme.success)
        case .needsLogin:
            return ("LOGIN", Theme.warning)
        case .unknown, .unavailable:
            return manager.geminiUsage != nil ? ("LIVE", Theme.success) : ("NO_DATA", Theme.textSecondary)
        }
    }

    private var openAIStatus: StatusBadge {
        switch manager.openAIBalance {
        case .loaded(let balance):
            return balance.amount <= 0 ? ("NO_CREDIT", Theme.error) : ("LIVE", Theme.success)
        case .needsLogin:
            return ("LOGIN", Theme.warning)
        case .unknown, .unavailable:
            return ("NO_DATA", Theme.textSecondary)
        }
    }

    // La cabecera resume lo peor de los tres.
    private var overallStatus: StatusBadge {
        let candidates = [claudeStatus, geminiStatus, openAIStatus]
        for label in ["RATE_LIMITED", "NO_CREDIT", "HIGH_USAGE"] {
            if let match = candidates.first(where: { $0.label == label }) {
                return match
            }
        }
        if candidates.contains(where: { $0.label == "LIVE" }) {
            return ("LIVE", Theme.success)
        }
        return ("LOGS_ONLY", Theme.textSecondary)
    }

    // MARK: - Helpers Claude

    private var hasLiveSessionWindow: Bool {
        manager.accountUsage?.fiveHour != nil
    }

    private var sessionUtilizationPercent: Double {
        if let live = manager.accountUsage?.fiveHour {
            return min(live.utilizationPercent, 100.0)
        }
        return min(Double(manager.fiveHourRequests) / Double(manager.fiveHourLimit) * 100.0, 100.0)
    }

    // Uso residual (<1%) o ventana vacía: mostrar 0%.
    private var displaySessionPercent: Int {
        if hasLiveSessionWindow {
            return sessionUtilizationPercent < 1.0 ? 0 : Int(sessionUtilizationPercent)
        }
        return manager.fiveHourRequests == 0 ? 0 : Int(sessionUtilizationPercent)
    }

    private var hasMeaningfulSessionUsage: Bool {
        if hasLiveSessionWindow {
            return sessionUtilizationPercent >= 1.0
        }
        return manager.fiveHourRequests > 0
    }

    private var isSessionLimitReached: Bool {
        sessionUtilizationPercent >= 99.0
    }

    private var weeklyAllPercent: Double {
        if let live = manager.accountUsage?.sevenDay {
            return min(live.utilizationPercent, 100.0)
        }
        return min(Double(manager.weeklyRequests) / Double(manager.weeklyLimit) * 100.0, 100.0)
    }

    // Con la ventana vacía no hay reset que contar.
    private var sessionResetCaption: String {
        guard hasMeaningfulSessionUsage || isSessionLimitReached,
              let resetDate = manager.nextResetDate else {
            return "sin uso en esta ventana"
        }
        return resetCaption(resetDate)
    }

    private var claudeScopeComment: String {
        if hasLiveSessionWindow {
            return "dato real de tu cuenta · desktop + web + cli"
        }
        if let reason = manager.liveQuotaUnavailableReason {
            return "aprox. por logs del CLI · \(reason)"
        }
        return "aprox. por logs del CLI"
    }

    // Motivos que devuelve Anthropic cuando los créditos no están operativos.
    private func creditsDisabledLabel(_ reason: String?) -> String {
        switch reason {
        case "out_of_credits":
            return "Sin créditos"
        case "org_spend_cap_reached":
            return "Tope de la organización"
        case "org_level_disabled_until", "org_service_level_disabled":
            return "Desactivados por la org."
        case "member_zero_credit_limit", "seat_tier_zero_credit_limit", "group_zero_credit_limit":
            return "Tu límite está a 0"
        case .some(let other):
            return other
        case nil:
            return "Desactivados"
        }
    }

    // MARK: - Helpers Gemini

    private var geminiAppUsage: GeminiAppUsage? {
        if case .loaded(let usage) = manager.geminiApp {
            return usage
        }
        return nil
    }

    // Lo más gastado entre la app (cupo actual y semanal) y Gemini CLI.
    private var geminiMaxUsedPercent: Double? {
        let app = [geminiAppUsage?.current?.usedPercent, geminiAppUsage?.weekly?.usedPercent].compactMap { $0 }
        let cli = manager.geminiUsage?.models.map(\.usedPercent) ?? []
        return (app + cli).max()
    }

    private var isGeminiLimitReached: Bool {
        (geminiMaxUsedPercent ?? 0) >= 99.0
    }

    private var geminiScopeComment: String {
        switch manager.geminiApp {
        case .loaded(let usage):
            let parts = ["dato real de tu cuenta de Google", usage.planName.map { "plan \($0)" }].compactMap { $0 }
            return parts.joined(separator: " · ")
        case .needsLogin:
            return "conecta tu cuenta de Google una vez para ver el uso de la app"
        case .unavailable(let reason):
            return reason
        case .unknown:
            return "consultando gemini.google.com/usage…"
        }
    }

    // MARK: - Helpers OpenAI

    private var openAIScopeComment: String {
        switch manager.openAIBalance {
        case .loaded:
            return "saldo de créditos de la API · platform.openai.com"
        case .needsLogin:
            return "conecta tu cuenta de OpenAI una vez para ver el saldo de la API"
        case .unavailable(let reason):
            return reason
        case .unknown:
            return "consultando platform.openai.com…"
        }
    }

    // Cuenta atrás o día y hora si se pudo interpretar; si no, el texto de Google.
    private func geminiResetCaption(_ window: GeminiAppWindow?) -> String? {
        if let date = window?.resetsAt {
            return resetCaption(date)
        }
        return window?.resetText
    }

    // MARK: - Formato

    private func levelColor(for percent: Double, base: Color) -> Color {
        if percent >= 90 { return Theme.error }
        if percent >= 70 { return Theme.warning }
        return base
    }

    // "Claude Opus 5" -> "OPUS_5" (sin el prefijo de la marca, que ya da la
    // sección), "Gemini 2.5 Flash Lite" -> "2.5_FLASH_LITE".
    private func snakeCase(_ name: String, dropping brand: String) -> String {
        var words = name.uppercased().split(whereSeparator: { $0 == " " || $0 == "-" })
        if words.count > 1, words.first == Substring(brand) {
            words.removeFirst()
        }
        return words.joined(separator: "_")
    }

    // Menos de un día: cuenta atrás ("reset en 2h 10m"). Más: día y hora
    // ("reset dom 08:00").
    private func resetCaption(_ date: Date) -> String {
        let diff = date.timeIntervalSince(now)
        guard diff > 0 else { return "reset ahora" }

        let mins = Int(ceil(diff / 60.0))
        if mins >= 24 * 60 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_ES")
            formatter.dateFormat = "E HH:mm"
            return "reset \(formatter.string(from: date))"
        }
        if mins >= 60 {
            return "reset en \(mins / 60)h \(mins % 60)m"
        }
        return "reset en \(mins)m"
    }

    private func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000.0)
        } else if num >= 1_000 {
            return String(format: "%.1fK", Double(num) / 1_000.0)
        }
        return "\(num)"
    }

    // Anthropic envía los importes en unidades menores de la divisa. El número de
    // decimales lo decide el propio formateador a partir del código de divisa,
    // que no siempre son dos (el yen no tiene ninguno).
    private func formatMoney(_ minorUnits: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let scale = pow(10.0, Double(formatter.maximumFractionDigits))
        let amount = Double(minorUnits) / scale
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }

    private func percentage(_ value: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total) * 100.0
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// Panel opaco con borde fino y esquinas poco redondeadas, como una ventana de
// terminal.
private struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

private extension View {
    func panel() -> some View {
        modifier(Panel())
    }
}

// Barra de uso continua sobre un carril visible: de un vistazo se ve cuánto
// está lleno. Esquinas casi rectas para el aire de terminal.
struct UsageBar: View {
    let percent: Double // 0.0 to 100.0
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.track)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: fillWidth(in: geo.size.width))
            }
        }
        .frame(height: 8)
    }

    // Cualquier uso por encima de cero se ve, aunque sea como un punto.
    private func fillWidth(in totalWidth: CGFloat) -> CGFloat {
        let clamped = min(max(percent, 0), 100)
        guard clamped > 0 else { return 0 }
        return max(totalWidth * CGFloat(clamped / 100), 4)
    }
}

// Línea discontinua de separación; con un trazo corto sirve de "puntos guía"
// entre una etiqueta y su valor.
struct DashedLine: View {
    var dash: [CGFloat] = [3, 3]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: dash))
        }
        .frame(height: 1)
    }
}
