import SwiftUI

typealias StatusBadge = (label: String, color: Color)

struct DashboardView: View {
    @ObservedObject var manager: TelemetryManager

    // Live timer to refresh countdowns and checks every second without scanning logs
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // Hora de referencia de las cuentas atrás: al cambiar cada segundo, las
    // vuelve a pintar.
    @State private var now = Date()

    // Secciones plegables: el detalle por modelo y los ajustes no hacen falta
    // para el vistazo rápido.
    @State private var showModels: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerView

            separator

            // Sin ScrollView: el panel mide exactamente lo que ocupa el
            // contenido y AppDelegate hace que el popover tome ese tamaño. Para
            // que nunca se salga de la pantalla, las secciones plegables son
            // excluyentes y las tablas enseñan solo los modelos con más uso.
            VStack(alignment: .leading, spacing: 12) {
                claudeSection
                geminiSection
                foldableSections
            }
            .padding(14)

            separator

            footerView
        }
        .frame(width: 360)
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
        HStack(spacing: 8) {
            Text("Uso de IA")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            statusPill(overallStatus)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Claude

    private var claudeSection: some View {
        providerCard("Claude", color: Theme.claude, status: claudeStatus, caption: claudeScopeComment) {
            meterRow(
                "Sesión (5 h)",
                percent: Double(displaySessionPercent),
                caption: sessionResetCaption,
                color: Theme.claude
            )
            rowDivider
            meterRow(
                "Semana",
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
    // porcentaje.
    @ViewBuilder
    private var claudeModelWindows: some View {
        if let modelWindows = manager.accountUsage?.modelWindows, !modelWindows.isEmpty {
            ForEach(modelWindows) { scoped in
                rowDivider
                meterRow(
                    "Semana · " + dropBrand(scoped.displayName, "Claude"),
                    percent: min(scoped.window.utilizationPercent, 100.0),
                    caption: scoped.window.resetsAt.map { resetCaption($0) },
                    color: Theme.claude
                )
            }
        } else {
            rowDivider
            valueRow(
                "Fable · 7 días",
                value: "\(manager.fableRequests) prompts · \(formatNumber(manager.fableInputTokens + manager.fableOutputTokens)) tokens"
            )
        }
    }

    // Créditos de uso (con lo que se paga Fable al agotar la cuota del plan)
    // y saldo prepago. Sin dato en vivo no se pinta nada: el subtítulo de la
    // tarjeta ya explica por qué.
    @ViewBuilder
    private var claudeCreditRows: some View {
        if let credits = manager.accountUsage?.credits {
            rowDivider
            if credits.isEnabled {
                let used = credits.usedMinorUnits ?? 0
                let usedText = formatMoney(used, currency: credits.currencyCode)

                if let limit = credits.monthlyLimitMinorUnits {
                    let pct = min(credits.utilizationPercent ?? percentage(used, of: limit), 100.0)
                    valueRow(
                        "Créditos",
                        value: "\(usedText) de \(formatMoney(limit, currency: credits.currencyCode))",
                        valueColor: levelColor(for: pct, base: Theme.textPrimary)
                    )
                } else {
                    valueRow("Créditos", value: "\(usedText) · sin tope")
                }
            } else {
                valueRow("Créditos", value: creditsDisabledLabel(credits.disabledReason), valueColor: Theme.warning)
            }
        }

        if let prepaid = manager.accountUsage?.prepaid {
            rowDivider
            valueRow("Saldo prepago", value: formatMoney(prepaid.balanceMinorUnits, currency: prepaid.currencyCode))
        }
    }

    // MARK: - Gemini

    private var geminiSection: some View {
        providerCard("Gemini", color: Theme.gemini, status: geminiStatus, caption: geminiScopeComment) {
            geminiAppRows

            // Gemini CLI solo aparece si se usa: cuota por modelo si hay
            // sesión del CLI, y actividad local si hay logs.
            if let models = manager.geminiUsage?.models, !models.isEmpty {
                ForEach(models) { model in
                    rowDivider
                    meterRow(
                        "CLI · " + dropBrand(GeminiModelNames.displayName(model.modelId), "Gemini"),
                        percent: model.usedPercent,
                        caption: model.resetsAt.map { resetCaption($0) },
                        color: Theme.gemini
                    )
                }
            }
            if manager.geminiLocal.prompts7d > 0 {
                rowDivider
                valueRow(
                    "CLI · últimas 24 h",
                    value: "\(manager.geminiLocal.prompts24h) prompts · \(formatNumber(manager.geminiLocal.tokens24h)) tokens"
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
                "Sesión (5 h)",
                percent: usage.current?.usedPercent ?? 0,
                caption: geminiResetCaption(usage.current),
                color: Theme.gemini
            )
            rowDivider
            meterRow(
                "Semana",
                percent: usage.weekly?.usedPercent ?? 0,
                caption: geminiResetCaption(usage.weekly),
                color: Theme.gemini
            )
        case .needsLogin:
            Button(action: {
                manager.connectGoogleAccount()
            }) {
                valueRow("Cuenta de Google", value: "Conectar →", valueColor: Theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .unknown:
            valueRow("App de Gemini", value: "Consultando…", valueColor: Theme.textSecondary)
        case .unavailable:
            valueRow("App de Gemini", value: "Sin datos", valueColor: Theme.textSecondary)
        }
    }

    // MARK: - Secciones plegables

    private var foldableSections: some View {
        VStack(alignment: .leading, spacing: 0) {
            foldToggle("Modelos", systemImage: "list.bullet", isOpen: showModels) {
                showModels.toggle()
                if showModels { showSettings = false }
            }
            if showModels {
                modelsSection
            }

            rowDivider

            foldToggle("Ajustes", systemImage: "gearshape", isOpen: showSettings) {
                showSettings.toggle()
                if showSettings { showModels = false }
            }
            if showSettings {
                settingsSection
            }
        }
        .card()
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelTable(
                title: "Claude · histórico",
                rows: manager.modelUsageBreakdown,
                color: Theme.claude
            ) { $0.contains("Fable") }

            if !manager.geminiLocal.models7d.isEmpty {
                modelTable(
                    title: "Gemini CLI · 7 días",
                    rows: manager.geminiLocal.models7d,
                    color: Theme.gemini
                ) { $0.contains("Pro") }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if manager.launchAtLoginSupported {
                HStack {
                    Text("Iniciar con macOS")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("Iniciar con macOS", isOn: $manager.launchAtLoginEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            if manager.geminiApp != .needsLogin {
                Button(action: {
                    manager.disconnectGoogleAccount()
                }) {
                    Text("Desconectar cuenta de Google")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.error)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Límites de respaldo de Claude: solo se usan cuando no hay dato en vivo de la cuenta.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                stepperRow("Sesión (5 h)", value: $manager.fiveHourLimit, step: 5, range: 10...200)
                stepperRow("Semana", value: $manager.weeklyLimit, step: 100, range: 200...5000)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func foldToggle(_ title: String, systemImage: String, isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                action()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Actualizar")
            }

            Text("Actualizado a las \(formatTime(manager.lastRefreshed))")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)

            Spacer()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("Salir")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
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

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func providerCard<Content: View>(_ name: String,
                                             color: Color,
                                             status: StatusBadge,
                                             caption: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    statusPill(status)
                }

                Text(caption)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 10)

            rowDivider

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func statusPill(_ status: StatusBadge) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(status.color.opacity(0.14))
        )
    }

    // Un límite: nombre y % arriba, la barra entera debajo y cuándo se
    // renueva. El % va en el color del texto y solo cambia (con un icono de
    // aviso, para no depender del color) desde el 70 %.
    private func meterRow(_ label: String, percent: Double, caption: String?, color: Color) -> some View {
        let isHigh = percent >= 70

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if isHigh {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(levelColor(for: percent, base: color))
                }
                Text("\(Int(percent)) %")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(levelColor(for: percent, base: Theme.textPrimary))
            }

            UsageBar(percent: percent, color: levelColor(for: percent, base: color))

            if let caption = caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func valueRow(_ label: String, value: String, valueColor: Color = Theme.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .fixedSize()

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func modelTable(title: String,
                            rows: [ModelUsage],
                            color: Color,
                            highlight: @escaping (String) -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("Prompts")
                    .frame(width: 60, alignment: .trailing)
                Text("Tokens")
                    .frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.textSecondary)

            if rows.isEmpty {
                Text("Sin actividad en los logs.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            } else {
                ForEach(Array(rows.prefix(Self.maxModelRows))) { usage in
                    HStack {
                        Text(usage.modelName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text("\(usage.requestsCount)")
                            .frame(width: 60, alignment: .trailing)
                        Text(formatNumber(usage.inputTokens + usage.outputTokens))
                            .fontWeight(highlight(usage.modelName) ? .semibold : .regular)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .font(.system(size: 12).monospacedDigit())
                }
            }
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, step: Int, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Text("\(value.wrappedValue) prompts")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            Stepper(title, value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    // Filas por tabla de modelos, para que el panel quepa en pantalla.
    private static let maxModelRows = 6

    // MARK: - Estado

    private static let limitLabel = "Límite alcanzado"
    private static let highUsageLabel = "Uso alto"
    private static let liveLabel = "En vivo"
    private static let estimatedLabel = "Estimado"

    private var claudeStatus: StatusBadge {
        if isSessionLimitReached { return (Self.limitLabel, Theme.error) }
        if displaySessionPercent >= 90 { return (Self.highUsageLabel, Theme.warning) }
        return hasLiveSessionWindow ? (Self.liveLabel, Theme.success) : (Self.estimatedLabel, Theme.textSecondary)
    }

    private var geminiStatus: StatusBadge {
        if isGeminiLimitReached { return (Self.limitLabel, Theme.error) }
        if (geminiMaxUsedPercent ?? 0) >= 90 { return (Self.highUsageLabel, Theme.warning) }
        switch manager.geminiApp {
        case .loaded:
            return (Self.liveLabel, Theme.success)
        case .needsLogin:
            return ("Sin conectar", Theme.warning)
        case .unknown, .unavailable:
            return manager.geminiUsage != nil ? (Self.liveLabel, Theme.success) : ("Sin datos", Theme.textSecondary)
        }
    }

    // La cabecera resume lo peor de los dos.
    private var overallStatus: StatusBadge {
        let candidates = [claudeStatus, geminiStatus]
        for label in [Self.limitLabel, Self.highUsageLabel] {
            if let match = candidates.first(where: { $0.label == label }) {
                return match
            }
        }
        if candidates.contains(where: { $0.label == Self.liveLabel }) {
            return (Self.liveLabel, Theme.success)
        }
        return (Self.estimatedLabel, Theme.textSecondary)
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
            return "Aún sin uso en esta ventana"
        }
        return resetCaption(resetDate)
    }

    private var claudeScopeComment: String {
        if hasLiveSessionWindow {
            return "Datos reales de tu cuenta · escritorio, web y CLI"
        }
        if let reason = manager.liveQuotaUnavailableReason {
            return "Aproximado por los logs del CLI · \(reason)"
        }
        return "Aproximado por los logs del CLI"
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
            let parts = ["Datos reales de tu cuenta de Google", usage.planName.map { "plan \($0)" }].compactMap { $0 }
            return parts.joined(separator: " · ")
        case .needsLogin:
            return "Conecta tu cuenta de Google una vez para ver el uso de la app"
        case .unavailable(let reason):
            return reason
        case .unknown:
            return "Consultando gemini.google.com/usage…"
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

    // "Claude Opus 5" -> "Opus 5": la marca ya la da la tarjeta.
    private func dropBrand(_ name: String, _ brand: String) -> String {
        let prefix = brand + " "
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    // Menos de un día: cuenta atrás ("en 2 h 10 min"). Más: día y hora
    // ("el domingo a las 08:00").
    private func resetCaption(_ date: Date) -> String {
        let diff = date.timeIntervalSince(now)
        guard diff > 0 else { return "Se renueva ahora" }

        let mins = Int(ceil(diff / 60.0))
        if mins >= 24 * 60 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_ES")
            formatter.dateFormat = "EEEE 'a las' HH:mm"
            return "Se renueva el \(formatter.string(from: date))"
        }
        if mins >= 60 {
            return "Se renueva en \(mins / 60) h \(mins % 60) min"
        }
        return "Se renueva en \(mins) min"
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
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// Tarjeta: superficie opaca con borde fino redondeado.
private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

private extension View {
    func card() -> some View {
        modifier(Card())
    }
}

// Barra de uso continua sobre un carril visible: de un vistazo se ve cuánto
// está lleno.
struct UsageBar: View {
    let percent: Double // 0.0 to 100.0
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: fillWidth(in: geo.size.width))
            }
        }
        .frame(height: 6)
    }

    // Cualquier uso por encima de cero se ve, aunque sea como un punto.
    private func fillWidth(in totalWidth: CGFloat) -> CGFloat {
        let clamped = min(max(percent, 0), 100)
        guard clamped > 0 else { return 0 }
        return max(totalWidth * CGFloat(clamped / 100), 6)
    }
}
