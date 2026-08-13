import SwiftUI

struct DashboardView: View {
    @ObservedObject var manager: TelemetryManager

    // Live timer to refresh countdowns and checks every second without scanning logs
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // State to trigger UI redraw on timer tick
    @State private var tick: Bool = false

    // State to toggle visibility of limits configuration drawer
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView

            Divider()
                .background(Theme.border)

            // Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // El permiso del llavero se pide aquí, nunca con un diálogo
                    // del sistema lanzado por sorpresa desde un sondeo.
                    if manager.needsKeychainAuthorization {
                        keychainAuthorizationView
                    }

                    // Solo avisar de límite alcanzado cuando el uso real está al 99% o más.
                    if isSessionLimitReached {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.error)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("LÍMITE DE SESIÓN ALCANZADO")
                                    .font(Theme.monospaced(10, weight: .bold))
                                    .foregroundColor(Theme.error)
                                Text("Tu cuota de terminal está bloqueada temporalmente.")
                                    .font(Theme.monospaced(9))
                                    .foregroundColor(Theme.textPrimary)
                            }

                            Spacer()
                        }
                        .padding(10)
                        .background(Theme.error.opacity(0.1))
                        .border(Theme.error.opacity(0.4), width: 1)
                    }

                    // Pro Plan Usage Limits (matching screenshot style)
                    proLimitsSectionView

                    // Weekly Limits (matching screenshot style)
                    weeklyLimitsSectionView

                    // Créditos de uso: cómo se paga Fable desde que dejó de ir
                    // contra el límite semanal.
                    creditsSectionView

                    // Model Usage Breakdown Table
                    modelBreakdownSectionView

                    Divider()
                        .background(Theme.border)

                    // Settings configuration Drawer
                    settingsDrawerView
                }
                .padding(16)
            }
            .background(Theme.background)

            Divider()
                .background(Theme.border)

            // Footer Control Bar
            footerView
        }
        .frame(width: 380, height: 520)
        .foregroundColor(Theme.textPrimary)
        .onReceive(timer) { _ in
            tick.toggle() // Forces redraw of countdown strings
            manager.updateBlockStateIfNeeded() // Checks timeline for real-time status transitions
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Text(">_")
                    .foregroundColor(Theme.accent)
                    .font(Theme.monospaced(14, weight: .bold))
                Text("CLAUDE_TELEMETRY")
                    .font(Theme.monospaced(13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
            }

            Spacer()

            // Status Indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(sessionStatusColor)
                    .frame(width: 7, height: 7)
                Text(sessionStatusLabel)
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(sessionStatusColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(sessionStatusColor.opacity(0.4), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.cardBackground)
    }

    // 0. Petición explícita del permiso de llavero
    private var keychainAuthorizationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("ACCESO AL LLAVERO")
                        .font(Theme.monospaced(10, weight: .bold))
                        .foregroundColor(Theme.warning)
                    Text("Claude Code ha renovado su sesión y macOS ha revocado el permiso concedido.")
                        .font(Theme.monospaced(9))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Button(action: {
                manager.authorizeKeychainAccess()
            }) {
                Text("AUTORIZAR AHORA")
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.background)
                    .border(Theme.warning.opacity(0.5), width: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Theme.warning.opacity(0.1))
        .border(Theme.warning.opacity(0.4), width: 1)
    }

    // 1. Uso de cuenta (dato real si hay sesión de Claude Code; si no, aproximación por logs del CLI)
    private var proLimitsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hasLiveSessionWindow ? "Uso de tu cuenta Claude" : "Uso de Claude Code (CLI)")
                    .font(Theme.monospaced(12, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                Text(proScopeCaption)
                    .font(Theme.monospaced(8))
                    .foregroundColor(Theme.textMuted)
            }

            let pct = Double(displaySessionPercent)

            HStack(alignment: .center, spacing: 10) {
                // Info Column (Left)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sesión actual")
                        .font(Theme.monospaced(11, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Text(sessionResetTimeString())
                        .font(Theme.monospaced(9))
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(width: 135, alignment: .leading)

                // Progress Bar (Middle)
                CustomProgressBar(value: pct, color: barColor(for: pct))
                    .frame(height: 6)

                // Percentage Text (Right)
                Text("\(displaySessionPercent)% usado")
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 75, alignment: .trailing)
            }
            .padding(10)
            .background(Theme.cardBackground)
            .border(Theme.border, width: 1)
        }
    }

    // 2. Límites semanales: "todos los modelos" más las ventanas por modelo que
    // publique el servidor (Fable entre ellas). Sin dato en vivo se cae a la
    // estimación local por logs.
    private var weeklyLimitsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Límites semanales")
                    .font(Theme.monospaced(12, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                Text(weeklyScopeCaption)
                    .font(Theme.monospaced(8))
                    .foregroundColor(Theme.textMuted)
            }

            VStack(spacing: 0) {
                let pctAll: Double = {
                    if let live = manager.accountUsage?.sevenDay {
                        return min(live.utilizationPercent, 100.0)
                    }
                    return min(Double(manager.weeklyRequests) / Double(manager.weeklyLimit) * 100.0, 100.0)
                }()
                let weeklyResetLabel = manager.accountUsage?.sevenDay?.resetsAt
                    .map { formatWeeklyReset($0) } ?? "Se restablece dom, 8:00"

                progressRow(
                    title: "Todos los modelos",
                    subtitle: weeklyResetLabel,
                    percent: pctAll
                )

                // Cada ventana semanal por modelo que sirva Anthropic. Cuando no
                // hay ninguna, se muestra el contador local de Fable en vez de
                // inventarse un porcentaje.
                if let modelWindows = manager.accountUsage?.modelWindows, !modelWindows.isEmpty {
                    ForEach(modelWindows) { scoped in
                        Divider().background(Theme.border)
                        progressRow(
                            title: scoped.displayName,
                            subtitle: scoped.window.resetsAt.map { formatWeeklyReset($0) } ?? "Ventana semanal",
                            percent: min(scoped.window.utilizationPercent, 100.0)
                        )
                    }
                } else {
                    Divider().background(Theme.border)
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fable")
                                .font(Theme.monospaced(11, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                            Text("Se factura con créditos, no con esta cuota")
                                .font(Theme.monospaced(9))
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 135, alignment: .leading)

                        Spacer()

                        Text("\(manager.fableRequests) prompts · \(formatNumber(manager.fableInputTokens + manager.fableOutputTokens)) tok")
                            .font(Theme.monospaced(10, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .padding(10)
                }
            }
            .background(Theme.cardBackground)
            .border(Theme.border, width: 1)
        }
    }

    // 3. Créditos de uso: límite mensual, gastado, restante y saldo prepago.
    private var creditsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Créditos de uso")
                    .font(Theme.monospaced(12, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                Text("Con esto se paga Fable cuando se agota la cuota del plan")
                    .font(Theme.monospaced(8))
                    .foregroundColor(Theme.textMuted)
            }

            if let credits = manager.accountUsage?.credits {
                VStack(spacing: 0) {
                    if credits.isEnabled {
                        creditsUsageRow(credits)

                        if let remaining = credits.remainingMinorUnits {
                            Divider().background(Theme.border)
                            valueRow(
                                title: "Restante este mes",
                                subtitle: "Antes de tocar el tope",
                                value: formatMoney(remaining, currency: credits.currencyCode)
                            )
                        }
                    } else {
                        valueRow(
                            title: "Estado",
                            subtitle: "Ejecuta /usage-credits en Claude Code",
                            value: creditsDisabledLabel(credits.disabledReason)
                        )
                    }

                    if let prepaid = manager.accountUsage?.prepaid {
                        Divider().background(Theme.border)
                        valueRow(
                            title: "Saldo prepago",
                            subtitle: "Bolsa de crédito comprada",
                            value: formatMoney(prepaid.balanceMinorUnits, currency: prepaid.currencyCode)
                        )
                    }
                }
                .background(Theme.cardBackground)
                .border(Theme.border, width: 1)
            } else {
                emptyStateView(message: creditsUnavailableMessage)
            }
        }
    }

    private func creditsUsageRow(_ credits: CreditStatus) -> some View {
        let used = credits.usedMinorUnits ?? 0
        let usedText = formatMoney(used, currency: credits.currencyCode)

        return Group {
            if let limit = credits.monthlyLimitMinorUnits {
                let pct = min(credits.utilizationPercent ?? percentage(used, of: limit), 100.0)
                progressRow(
                    title: "Gastado este mes",
                    subtitle: "\(usedText) de \(formatMoney(limit, currency: credits.currencyCode))",
                    percent: pct
                )
            } else {
                valueRow(
                    title: "Gastado este mes",
                    subtitle: "Sin tope mensual configurado",
                    value: usedText
                )
            }
        }
    }

    // 4. Model Breakdown Table
    private var modelBreakdownSectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resumen de uso por modelo")
                .font(Theme.monospaced(12, weight: .bold))
                .foregroundColor(Theme.textSecondary)

            if manager.modelUsageBreakdown.isEmpty {
                emptyStateView(message: "Sin actividad en los logs.")
            } else {
                VStack(spacing: 0) {
                    // Table Header
                    HStack {
                        Text("MODELO")
                            .frame(width: 135, alignment: .leading)
                        Spacer()
                        Text("PETS")
                            .frame(width: 50, alignment: .trailing)
                        Spacer()
                        Text("TOKENS")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.border.opacity(0.3))

                    ForEach(manager.modelUsageBreakdown) { usage in
                        Divider()
                            .background(Theme.border)

                        HStack {
                            Text(usage.modelName)
                                .frame(width: 135, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(usage.requestsCount)")
                                .frame(width: 50, alignment: .trailing)
                            Spacer()
                            Text(formatNumber(usage.inputTokens + usage.outputTokens))
                                .frame(width: 80, alignment: .trailing)
                                .foregroundColor(usage.modelName.contains("Fable") ? Theme.accent : Theme.textPrimary)
                        }
                        .font(Theme.monospaced(10))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .background(Theme.cardBackground)
                .border(Theme.border, width: 1)
            }
        }
    }

    // 5. Config Drawer at bottom
    private var settingsDrawerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSettings.toggle()
                }
            }) {
                HStack {
                    Text(showSettings ? "[-] OCULTAR CONFIGURACIÓN" : "[+] CONFIGURACIÓN")
                        .font(Theme.monospaced(10, weight: .bold))
                        .foregroundColor(Theme.accent)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showSettings {
                VStack(spacing: 10) {
                    if manager.launchAtLoginSupported {
                        HStack {
                            Toggle(isOn: $manager.launchAtLoginEnabled) {
                                Text("Iniciar con macOS")
                                    .font(Theme.monospaced(10, weight: .bold))
                                    .foregroundColor(Theme.textPrimary)
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                        }

                        Divider()
                            .background(Theme.border)
                    }

                    Text("Los límites de abajo solo se usan cuando no hay dato en vivo de la cuenta disponible")
                        .font(Theme.monospaced(8))
                        .foregroundColor(Theme.textMuted)
                    stepperRow(title: "Límite sesión 5H:", value: $manager.fiveHourLimit, step: 5, range: 10...200)
                    stepperRow(title: "Límite semanal (Todos):", value: $manager.weeklyLimit, step: 100, range: 200...5000)
                }
                .padding(10)
                .background(Theme.cardBackground)
                .border(Theme.border, width: 1)
            }
        }
    }

    // MARK: - Filas reutilizables

    private func progressRow(title: String, subtitle: String, percent: Double) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(Theme.monospaced(9))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 135, alignment: .leading)

            CustomProgressBar(value: percent, color: barColor(for: percent))
                .frame(height: 6)

            Text("\(Int(percent))% usado")
                .font(Theme.monospaced(10, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 75, alignment: .trailing)
        }
        .padding(10)
    }

    private func valueRow(title: String, subtitle: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.monospaced(9))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 135, alignment: .leading)

            Spacer()

            Text(value)
                .font(Theme.monospaced(10, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
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
                .background(Theme.border.opacity(0.5))
                .cornerRadius(2)

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
                .background(Theme.border.opacity(0.5))
                .cornerRadius(2)
            }
        }
    }

    private func emptyStateView(message: String) -> some View {
        HStack {
            Spacer()
            Text(message)
                .font(Theme.monospaced(11))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.vertical, 16)
                .padding(.horizontal, 10)
            Spacer()
        }
        .background(Theme.cardBackground)
        .border(Theme.border, width: 1)
    }

    private var footerView: some View {
        HStack {
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

                Text("REFRESHED: \(formatTime(manager.lastRefreshed))")
                    .font(Theme.monospaced(9))
                    .foregroundColor(Theme.textMuted)
            }

            Spacer()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("QUIT")
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.error)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.background)
                    .border(Theme.error.opacity(0.5), width: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.cardBackground)
    }

    // MARK: - Helpers

    private var hasLiveSessionWindow: Bool {
        manager.accountUsage?.fiveHour != nil
    }

    private var sessionUtilizationPercent: Double {
        if let live = manager.accountUsage?.fiveHour {
            return min(live.utilizationPercent, 100.0)
        }
        return min(Double(manager.fiveHourRequests) / Double(manager.fiveHourLimit) * 100.0, 100.0)
    }

    // Uso residual (<1%) o ventana vacía: mostrar 0% y "Cuota completa".
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

    private var sessionStatusLabel: String {
        if isSessionLimitReached { return "RATE_LIMITED" }
        if displaySessionPercent >= 90 { return "HIGH_USAGE" }
        return "LOGS_ACTIVE"
    }

    private var sessionStatusColor: Color {
        if isSessionLimitReached { return Theme.error }
        if displaySessionPercent >= 90 { return Theme.warning }
        return Theme.success
    }

    private func barColor(for percent: Double) -> Color {
        if percent >= 90 { return Theme.error }
        if percent >= 70 { return Theme.warning }
        return Theme.accent
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

    private func sessionResetTimeString() -> String {
        if !hasMeaningfulSessionUsage && !isSessionLimitReached {
            return "Cuota completa"
        }
        guard let resetDate = manager.nextResetDate else {
            return "Cuota completa"
        }
        let diff = resetDate.timeIntervalSince(Date())
        if diff <= 0 {
            return "Restablecido"
        }

        let mins = Int(ceil(diff / 60.0))
        let labelPrefix = isSessionLimitReached ? "Límite: restablece en" : "Se restablece en"

        if mins >= 60 {
            let hours = mins / 60
            let remainingMins = mins % 60
            return "\(labelPrefix) \(hours) h \(remainingMins) min"
        } else {
            return "\(labelPrefix) \(mins) min"
        }
    }

    private var proScopeCaption: String {
        if hasLiveSessionWindow {
            return "Dato real de tu cuenta (Desktop + web + CLI)"
        }
        if let reason = manager.liveQuotaUnavailableReason {
            return "Aproximación por logs del CLI · \(reason)"
        }
        return "Solo terminal · no incluye Desktop, web ni móvil"
    }

    private var weeklyScopeCaption: String {
        if manager.accountUsage?.sevenDay != nil {
            return "Dato real de tu cuenta"
        }
        return "Aproximación por logs del CLI"
    }

    private var creditsUnavailableMessage: String {
        if let reason = manager.liveQuotaUnavailableReason {
            return "Sin dato de créditos · \(reason)"
        }
        return "Sin dato de créditos todavía."
    }

    // Motivos que devuelve Anthropic cuando los créditos no están operativos.
    private func creditsDisabledLabel(_ reason: String?) -> String {
        switch reason {
        case "out_of_credits":
            return "Sin créditos"
        case "org_spend_cap_reached":
            return "Tope de la organización alcanzado"
        case "org_level_disabled_until":
            return "Desactivados por la organización"
        case "org_service_level_disabled":
            return "Desactivados para tu organización"
        case "member_zero_credit_limit", "seat_tier_zero_credit_limit", "group_zero_credit_limit":
            return "Tu límite está a 0"
        case .some(let other):
            return other
        case nil:
            return "Desactivados"
        }
    }

    private func formatWeeklyReset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "E, HH:mm"
        return "Se restablece \(formatter.string(from: date))"
    }
}

// Flat Horizontal Progress Bar
struct CustomProgressBar: View {
    let value: Double // 0.0 to 100.0
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.border.opacity(0.5))
                    .frame(height: 6)

                // Active Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 100) / 100.0), height: 6)
            }
        }
        .frame(height: 6)
    }
}
