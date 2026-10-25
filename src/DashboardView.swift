import SwiftUI

typealias StatusBadge = (label: String, color: Color)

struct DashboardView: View {
    @ObservedObject var manager: TelemetryManager

    // Live timer to refresh countdowns and checks every second without scanning logs
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // State to trigger UI redraw on timer tick (y parpadeo del cursor de la cabecera)
    @State private var tick: Bool = false

    // Cajones plegables: el detalle por modelo y los ajustes no hacen falta
    // para el vistazo rápido.
    @State private var showModels: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    claudeSection
                    geminiSection

                    DashedLine()

                    VStack(alignment: .leading, spacing: 10) {
                        drawerToggle(title: "MODELOS", isOpen: $showModels)
                        if showModels {
                            modelsDrawer
                        }

                        drawerToggle(title: "CONFIG", isOpen: $showSettings)
                        if showSettings {
                            settingsDrawer
                        }
                    }
                }
                .padding(16)
            }

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            footerView
        }
        .frame(width: 380, height: 600)
        .background(VisualEffectBackground(material: .hudWindow).ignoresSafeArea())
        .foregroundColor(Theme.textPrimary)
        .onReceive(timer) { _ in
            tick.toggle() // Forces redraw of countdown strings
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
                        .opacity(tick ? 1 : 0.15)
                }
                .foregroundColor(Theme.accent)
                .font(Theme.monospaced(14, weight: .bold))

                Text("AI_TELEMETRY")
                    .font(Theme.monospaced(13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
            }

            Spacer()

            statusPill(overallStatus, size: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Claude

    private var claudeSection: some View {
        providerSection("CLAUDE", color: Theme.claude, status: claudeStatus, comment: claudeScopeComment) {
            meterRow(
                "SESION_5H",
                percent: Double(displaySessionPercent),
                trailing: sessionResetShort,
                color: Theme.claude
            )
            DashedLine()
            meterRow(
                "SEMANA",
                percent: weeklyAllPercent,
                trailing: manager.accountUsage?.sevenDay?.resetsAt.map { shortReset($0) } ?? "dom 08:00",
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
                DashedLine()
                meterRow(
                    "SEM_" + snakeCase(scoped.displayName, dropping: "CLAUDE"),
                    percent: min(scoped.window.utilizationPercent, 100.0),
                    trailing: scoped.window.resetsAt.map { shortReset($0) } ?? "—",
                    color: Theme.claude
                )
            }
        } else {
            DashedLine()
            valueRow(
                "FABLE_7D",
                value: "\(manager.fableRequests) prompts · \(formatNumber(manager.fableInputTokens + manager.fableOutputTokens)) tok"
            )
        }
    }

    // Créditos de uso (con lo que se paga Fable al agotar la cuota del plan)
    // y saldo prepago. Sin dato en vivo no se pinta nada: el comentario de la
    // sección ya explica por qué.
    @ViewBuilder
    private var claudeCreditRows: some View {
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
                        valueColor: barColor(for: pct, base: Theme.textPrimary)
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
                        trailing: model.resetsAt.map { shortReset($0) } ?? "—",
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
                trailing: geminiResetLabel(usage.current),
                color: Theme.gemini
            )
            DashedLine()
            meterRow(
                "SEMANA",
                percent: usage.weekly?.usedPercent ?? 0,
                trailing: geminiResetLabel(usage.weekly),
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
        VStack(alignment: .leading, spacing: 10) {
            if manager.launchAtLoginSupported {
                Toggle(isOn: $manager.launchAtLoginEnabled) {
                    Text("INICIAR_CON_MACOS")
                        .font(Theme.monospaced(10, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                }
                .toggleStyle(.checkbox)

                DashedLine()
            }

            if manager.geminiApp != .needsLogin {
                Button(action: {
                    manager.disconnectGoogleAccount()
                }) {
                    Text("DESCONECTAR_GOOGLE")
                        .font(Theme.monospaced(10, weight: .bold))
                        .foregroundColor(Theme.error)
                }
                .buttonStyle(.plain)

                DashedLine()
            }

            Text("// límites de respaldo de Claude: solo se usan sin dato en vivo de la cuenta")
                .font(Theme.monospaced(8))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            stepperRow(title: "SESION_5H", value: $manager.fiveHourLimit, step: 5, range: 10...200)
            stepperRow(title: "SEMANA", value: $manager.weeklyLimit, step: 100, range: 200...5000)
        }
        .padding(12)
        .glassCard()
    }

    private func drawerToggle(title: String, isOpen: Binding<Bool>) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOpen.wrappedValue.toggle()
            }
        }) {
            HStack {
                Text(isOpen.wrappedValue ? "[-] \(title)" : "[+] \(title)")
                    .font(Theme.monospaced(10, weight: .bold))
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
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Text("SYNC \(formatTime(manager.lastRefreshed))")
                .font(Theme.monospaced(9))
                .foregroundColor(Theme.textMuted)

            Spacer()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("QUIT")
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.error)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.error.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Theme.error.opacity(0.45), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Piezas reutilizables

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
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    statusPill(status, size: 9)
                }
                .font(Theme.monospaced(12, weight: .bold))

                Text("// \(comment)")
                    .font(Theme.monospaced(9))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    private func statusPill(_ status: StatusBadge, size: CGFloat) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: size - 3, height: size - 3)
            Text(status.label)
                .font(Theme.monospaced(size, weight: .bold))
                .foregroundColor(status.color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(status.color.opacity(0.10))
        )
        .overlay(
            Capsule().stroke(status.color.opacity(0.35), lineWidth: 1)
        )
    }

    // Una línea por límite: etiqueta, medidor, % y cuándo se restablece.
    private func meterRow(_ label: String, percent: Double, trailing: String, color: Color) -> some View {
        let tint = barColor(for: percent, base: color)

        return HStack(spacing: 10) {
            Text(label)
                .font(Theme.monospaced(10, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 100, alignment: .leading)

            SegmentedMeter(percent: percent, color: tint, segments: 18)

            Text("\(Int(percent))%")
                .font(Theme.monospaced(10, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 34, alignment: .trailing)

            Text(trailing)
                .font(Theme.monospaced(9))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func valueRow(_ label: String, value: String, valueColor: Color = Theme.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(Theme.monospaced(10, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .fixedSize()

            DashedLine(dash: [1, 3])

            Text(value)
                .font(Theme.monospaced(10, weight: .bold))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
                    .frame(width: 60, alignment: .trailing)
                Text("TOKENS")
                    .frame(width: 60, alignment: .trailing)
            }
            .font(Theme.monospaced(9, weight: .bold))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if rows.isEmpty {
                DashedLine()
                Text("Sin actividad en los logs.")
                    .font(Theme.monospaced(10))
                    .foregroundColor(Theme.textMuted)
                    .padding(12)
            } else {
                ForEach(rows) { usage in
                    DashedLine()
                    HStack {
                        Text(usage.modelName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text("\(usage.requestsCount)")
                            .frame(width: 60, alignment: .trailing)
                        Text(formatNumber(usage.inputTokens + usage.outputTokens))
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(highlight(usage.modelName) ? color : Theme.textPrimary)
                    }
                    .font(Theme.monospaced(10))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
        }
        .glassCard()
    }

    private func stepperRow(title: String, value: Binding<Int>, step: Int, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
                .font(Theme.monospaced(10))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            HStack(spacing: 8) {
                Button("-") {
                    if value.wrappedValue - step >= range.lowerBound {
                        value.wrappedValue -= step
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.monospaced(12, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Theme.border)
                .cornerRadius(3)

                Text("\(value.wrappedValue)")
                    .font(Theme.monospaced(10, weight: .bold))
                    .frame(width: 40, alignment: .center)

                Button("+") {
                    if value.wrappedValue + step <= range.upperBound {
                        value.wrappedValue += step
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.monospaced(12, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Theme.border)
                .cornerRadius(3)
            }
        }
    }

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

    // La cabecera resume lo peor de los dos.
    private var overallStatus: StatusBadge {
        let candidates = [claudeStatus, geminiStatus]
        for label in ["RATE_LIMITED", "HIGH_USAGE"] {
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
    private var sessionResetShort: String {
        guard hasMeaningfulSessionUsage || isSessionLimitReached,
              let resetDate = manager.nextResetDate else {
            return "—"
        }
        return shortReset(resetDate)
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

    // Hora o cuenta atrás si se pudo interpretar; si no, el texto de Google.
    private func geminiResetLabel(_ window: GeminiAppWindow?) -> String {
        if let date = window?.resetsAt {
            return shortReset(date)
        }
        guard let text = window?.resetText else { return "—" }
        return text.split(separator: " ").suffix(1).joined()
    }

    // MARK: - Formato

    private func barColor(for percent: Double, base: Color) -> Color {
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

    // Menos de un día: cuenta atrás ("2h 10m"). Más: día y hora ("dom 08:00").
    private func shortReset(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        guard diff > 0 else { return "ahora" }

        let mins = Int(ceil(diff / 60.0))
        if mins >= 24 * 60 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_ES")
            formatter.dateFormat = "E HH:mm"
            return formatter.string(from: date)
        }
        if mins >= 60 {
            return "\(mins / 60)h \(mins % 60)m"
        }
        return "\(mins)m"
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

// Panel de cristal: relleno blanco muy tenue y borde fino redondeado.
private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

private extension View {
    func glassCard() -> some View {
        modifier(GlassCard())
    }
}

// Desenfoque del sistema detrás del popover. `.active` porque el popover no
// siempre es la ventana activa y, si no, macOS lo pintaría opaco.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// Barra de uso por segmentos, como un medidor de terminal.
struct SegmentedMeter: View {
    let percent: Double // 0.0 to 100.0
    let color: Color
    var segments: Int = 28

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < filledSegments ? color : Theme.meterTrack)
                        .frame(width: segmentWidth(in: geo.size.width))
                }
            }
        }
        .frame(height: 8)
    }

    // Cualquier uso por encima de cero enciende al menos un segmento.
    private var filledSegments: Int {
        let clamped = min(max(percent, 0), 100)
        let filled = Int((clamped / 100 * Double(segments)).rounded())
        return clamped > 0 ? max(filled, 1) : 0
    }

    private func segmentWidth(in totalWidth: CGFloat) -> CGFloat {
        let spacing = CGFloat(segments - 1) * 2
        return max((totalWidth - spacing) / CGFloat(segments), 1)
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
