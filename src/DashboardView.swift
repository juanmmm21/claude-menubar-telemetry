import SwiftUI

enum Provider: String, CaseIterable, Identifiable {
    case claude
    case gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "CLAUDE"
        case .gemini: return "GEMINI"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Theme.claude
        case .gemini: return Theme.gemini
        }
    }
}

struct DashboardView: View {
    @ObservedObject var manager: TelemetryManager

    // Live timer to refresh countdowns and checks every second without scanning logs
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // State to trigger UI redraw on timer tick (y parpadeo del cursor de la cabecera)
    @State private var tick: Bool = false

    // State to toggle visibility of limits configuration drawer
    @State private var showSettings: Bool = false

    // La pestaña elegida se recuerda entre aperturas del popover.
    @AppStorage("selectedProvider") private var selectedProvider: Provider = .claude

    var body: some View {
        VStack(spacing: 0) {
            headerView
            tabBar

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedProvider {
                    case .claude:
                        claudeContent
                    case .gemini:
                        geminiContent
                    }

                    DashedLine()

                    settingsDrawerView
                }
                .padding(16)
            }
            .background(Theme.background)

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            footerView
        }
        .frame(width: 380, height: 560)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onReceive(timer) { _ in
            tick.toggle() // Forces redraw of countdown strings
            manager.updateBlockStateIfNeeded() // Checks timeline for real-time status transitions
        }
    }

    // MARK: - Cabecera y pestañas

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

            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                Text(status.label)
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(status.color)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(status.color.opacity(0.4), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Theme.cardBackground)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Provider.allCases) { provider in
                tabButton(provider)
            }
        }
        .padding(.horizontal, 16)
        .background(Theme.cardBackground)
    }

    private func tabButton(_ provider: Provider) -> some View {
        let isSelected = provider == selectedProvider

        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedProvider = provider
            }
        }) {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Text(isSelected ? "[\(provider.label)]" : " \(provider.label) ")
                        .font(Theme.monospaced(11, weight: .bold))
                        .foregroundColor(isSelected ? provider.color : Theme.textSecondary)

                    if let percent = headlinePercent(for: provider) {
                        Text("\(percent)%")
                            .font(Theme.monospaced(9, weight: .bold))
                            .foregroundColor(isSelected ? barColor(for: Double(percent), base: provider.color) : Theme.textMuted)
                    }
                }

                Rectangle()
                    .fill(isSelected ? provider.color : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pestaña Claude

    private var claudeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isSessionLimitReached {
                alertBanner(title: "LIMITE_ALCANZADO", message: "Tu cuota de Claude está bloqueada hasta el próximo reset.")
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("CUOTA_CLAUDE", comment: claudeScopeComment, color: Theme.claude)
                card {
                    meterRow(
                        "SESION_5H",
                        percent: Double(displaySessionPercent),
                        detail: sessionResetTimeString(),
                        color: Theme.claude
                    )
                    DashedLine()
                    meterRow(
                        "SEMANA_TODOS",
                        percent: weeklyAllPercent,
                        detail: manager.accountUsage?.sevenDay?.resetsAt.map { formatWeeklyReset($0) } ?? "Se restablece dom, 8:00",
                        color: Theme.claude
                    )
                    claudeModelWindows
                }
            }

            creditsSectionView

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("MODELOS", comment: "histórico de los logs de Claude Code", color: Theme.claude)
                modelTable(manager.modelUsageBreakdown, color: Theme.claude) { $0.contains("Fable") }
            }
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
                    "SEMANA_" + snakeCase(scoped.displayName),
                    percent: min(scoped.window.utilizationPercent, 100.0),
                    detail: scoped.window.resetsAt.map { formatWeeklyReset($0) } ?? "Ventana semanal",
                    color: Theme.claude
                )
            }
        } else {
            DashedLine()
            valueRow(
                "FABLE_7D",
                value: "\(manager.fableRequests) prompts · \(formatNumber(manager.fableInputTokens + manager.fableOutputTokens)) tok",
                detail: "Se factura con créditos, no con esta cuota"
            )
        }
    }

    // Créditos de uso: límite mensual, gastado, restante y saldo prepago.
    private var creditsSectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CREDITOS_USO", comment: "con esto se paga Fable al agotar la cuota del plan", color: Theme.claude)

            if let credits = manager.accountUsage?.credits {
                card {
                    if credits.isEnabled {
                        creditsUsageRow(credits)

                        if let remaining = credits.remainingMinorUnits {
                            DashedLine()
                            valueRow(
                                "RESTANTE",
                                value: formatMoney(remaining, currency: credits.currencyCode),
                                detail: "Antes de tocar el tope de este mes"
                            )
                        }
                    } else {
                        valueRow(
                            "ESTADO",
                            value: creditsDisabledLabel(credits.disabledReason),
                            detail: "Ejecuta /usage-credits en Claude Code",
                            valueColor: Theme.warning
                        )
                    }

                    if let prepaid = manager.accountUsage?.prepaid {
                        DashedLine()
                        valueRow(
                            "PREPAGO",
                            value: formatMoney(prepaid.balanceMinorUnits, currency: prepaid.currencyCode),
                            detail: "Bolsa de crédito comprada"
                        )
                    }
                }
            } else {
                emptyStateView(message: creditsUnavailableMessage)
            }
        }
    }

    @ViewBuilder
    private func creditsUsageRow(_ credits: CreditStatus) -> some View {
        let used = credits.usedMinorUnits ?? 0
        let usedText = formatMoney(used, currency: credits.currencyCode)

        if let limit = credits.monthlyLimitMinorUnits {
            meterRow(
                "GASTADO_MES",
                percent: min(credits.utilizationPercent ?? percentage(used, of: limit), 100.0),
                detail: "\(usedText) de \(formatMoney(limit, currency: credits.currencyCode))",
                color: Theme.claude
            )
        } else {
            valueRow("GASTADO_MES", value: usedText, detail: "Sin tope mensual configurado")
        }
    }

    // MARK: - Pestaña Gemini

    @ViewBuilder
    private var geminiContent: some View {
        if manager.geminiInstalled {
            VStack(alignment: .leading, spacing: 20) {
                if isGeminiLimitReached {
                    alertBanner(title: "LIMITE_ALCANZADO", message: "Has agotado la cuota diaria de algún modelo de Gemini.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("CUOTA_GEMINI", comment: geminiScopeComment, color: Theme.gemini)
                    geminiQuotaCard
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("ACTIVIDAD_LOCAL", comment: "logs de Gemini CLI en este Mac", color: Theme.gemini)
                    card {
                        valueRow("PROMPTS_24H", value: "\(manager.geminiLocal.prompts24h)")
                        DashedLine()
                        valueRow("TOKENS_24H", value: formatNumber(manager.geminiLocal.tokens24h))
                        DashedLine()
                        valueRow(
                            "SEMANA",
                            value: "\(manager.geminiLocal.prompts7d) prompts · \(formatNumber(manager.geminiLocal.tokens7d)) tok"
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("MODELOS_7D", comment: "prompts y tokens por modelo", color: Theme.gemini)
                    modelTable(manager.geminiLocal.models7d, color: Theme.gemini) { $0.contains("Pro") }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("GEMINI", comment: "no hay ~/.gemini en este Mac", color: Theme.gemini)
                emptyStateView(message: "Gemini CLI no detectado.\nInstálalo y entra con tu cuenta de Google:\nnpm i -g @google/gemini-cli")
            }
        }
    }

    @ViewBuilder
    private var geminiQuotaCard: some View {
        if let usage = manager.geminiUsage, !usage.models.isEmpty {
            card {
                ForEach(Array(usage.models.enumerated()), id: \.element.id) { index, model in
                    if index > 0 {
                        DashedLine()
                    }
                    meterRow(
                        snakeCase(GeminiModelNames.displayName(model.modelId)),
                        percent: model.usedPercent,
                        detail: geminiQuotaDetail(model),
                        color: Theme.gemini
                    )
                }
            }
        } else if manager.geminiUsage != nil {
            emptyStateView(message: "Tu cuenta no publica cuota por modelo.")
        } else {
            emptyStateView(message: manager.geminiUnavailableReason ?? "Consultando la cuota de Gemini…")
        }
    }

    // MARK: - Ajustes y pie

    private var settingsDrawerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSettings.toggle()
                }
            }) {
                HStack {
                    Text(showSettings ? "[-] CONFIG" : "[+] CONFIG")
                        .font(Theme.monospaced(10, weight: .bold))
                        .foregroundColor(Theme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSettings {
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

                    Text("// límites de respaldo de Claude: solo se usan sin dato en vivo de la cuenta")
                        .font(Theme.monospaced(8))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    stepperRow(title: "SESION_5H", value: $manager.fiveHourLimit, step: 5, range: 10...200)
                    stepperRow(title: "SEMANA_TODOS", value: $manager.weeklyLimit, step: 100, range: 200...5000)
                }
                .padding(12)
                .background(Theme.cardBackground)
                .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
            }
        }
    }

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
                    .background(Theme.background)
                    .overlay(Rectangle().stroke(Theme.error.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.cardBackground)
    }

    // MARK: - Piezas reutilizables

    private func sectionHeader(_ title: String, comment: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(">")
                    .foregroundColor(color)
                Text(title)
                    .foregroundColor(Theme.textPrimary)
            }
            .font(Theme.monospaced(12, weight: .bold))

            if let comment = comment {
                Text("// \(comment)")
                    .font(Theme.monospaced(9))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }

    private func meterRow(_ label: String, percent: Double, detail: String?, color: Color) -> some View {
        let tint = barColor(for: percent, base: color)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text("\(Int(percent))%")
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(tint)
            }

            SegmentedMeter(percent: percent, color: tint)

            if let detail = detail {
                Text(detail)
                    .font(Theme.monospaced(9))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private func valueRow(_ label: String,
                          value: String,
                          detail: String? = nil,
                          valueColor: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize()

                DashedLine(dash: [1, 3])

                Text(value)
                    .font(Theme.monospaced(11, weight: .bold))
                    .foregroundColor(valueColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .layoutPriority(1)
            }

            if let detail = detail {
                Text(detail)
                    .font(Theme.monospaced(9))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private func modelTable(_ rows: [ModelUsage], color: Color, highlight: @escaping (String) -> Bool) -> some View {
        Group {
            if rows.isEmpty {
                emptyStateView(message: "Sin actividad en los logs.")
            } else {
                card {
                    HStack {
                        Text("MODELO")
                        Spacer()
                        Text("PROMPTS")
                            .frame(width: 60, alignment: .trailing)
                        Text("TOKENS")
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(Theme.monospaced(9, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.border.opacity(0.3))

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
                                .frame(width: 64, alignment: .trailing)
                                .foregroundColor(highlight(usage.modelName) ? color : Theme.textPrimary)
                        }
                        .font(Theme.monospaced(10))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private func alertBanner(title: String, message: String) -> some View {
        HStack(spacing: 10) {
            Text("!!")
                .font(Theme.monospaced(14, weight: .bold))
                .foregroundColor(Theme.error)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.error)
                Text(message)
                    .font(Theme.monospaced(9))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(10)
        .background(Theme.error.opacity(0.1))
        .overlay(Rectangle().stroke(Theme.error.opacity(0.4), lineWidth: 1))
    }

    private func emptyStateView(message: String) -> some View {
        HStack {
            Spacer()
            Text(message)
                .font(Theme.monospaced(10))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 16)
                .padding(.horizontal, 10)
            Spacer()
        }
        .background(Theme.cardBackground)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
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

    // MARK: - Estado

    private var status: (label: String, color: Color) {
        switch selectedProvider {
        case .claude:
            if isSessionLimitReached { return ("RATE_LIMITED", Theme.error) }
            if displaySessionPercent >= 90 { return ("HIGH_USAGE", Theme.warning) }
            return hasLiveSessionWindow ? ("LIVE", Theme.success) : ("LOGS_ONLY", Theme.textSecondary)
        case .gemini:
            guard manager.geminiInstalled else { return ("NOT_FOUND", Theme.textMuted) }
            if isGeminiLimitReached { return ("RATE_LIMITED", Theme.error) }
            if (geminiMaxUsedPercent ?? 0) >= 90 { return ("HIGH_USAGE", Theme.warning) }
            return manager.geminiUsage != nil ? ("LIVE", Theme.success) : ("LOGS_ONLY", Theme.textSecondary)
        }
    }

    private func headlinePercent(for provider: Provider) -> Int? {
        switch provider {
        case .claude:
            return displaySessionPercent
        case .gemini:
            return geminiMaxUsedPercent.map { Int($0) }
        }
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

    private var weeklyAllPercent: Double {
        if let live = manager.accountUsage?.sevenDay {
            return min(live.utilizationPercent, 100.0)
        }
        return min(Double(manager.weeklyRequests) / Double(manager.weeklyLimit) * 100.0, 100.0)
    }

    private func sessionResetTimeString() -> String {
        if !hasMeaningfulSessionUsage && !isSessionLimitReached {
            return "Cuota completa"
        }
        guard let resetDate = manager.nextResetDate else {
            return "Cuota completa"
        }
        guard let countdown = countdownString(to: resetDate) else {
            return "Restablecido"
        }
        let labelPrefix = isSessionLimitReached ? "Límite: restablece en" : "Se restablece en"
        return "\(labelPrefix) \(countdown)"
    }

    private var claudeScopeComment: String {
        if hasLiveSessionWindow {
            return "dato real de tu cuenta · desktop + web + cli"
        }
        if let reason = manager.liveQuotaUnavailableReason {
            return "aproximación por logs del CLI · \(reason)"
        }
        return "aproximación por logs del CLI"
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

    // MARK: - Helpers Gemini

    private var geminiMaxUsedPercent: Double? {
        manager.geminiUsage?.models.map(\.usedPercent).max()
    }

    private var isGeminiLimitReached: Bool {
        (geminiMaxUsedPercent ?? 0) >= 99.0
    }

    private var geminiScopeComment: String {
        if let usage = manager.geminiUsage {
            let parts = ["cuota diaria real", usage.planName, usage.email].compactMap { $0 }
            return parts.joined(separator: " · ")
        }
        if let reason = manager.geminiUnavailableReason {
            return "sin dato en vivo · \(reason)"
        }
        return "cuota diaria por modelo"
    }

    private func geminiQuotaDetail(_ quota: GeminiModelQuota) -> String {
        var parts: [String] = []
        if let remaining = quota.remainingRequests, let limit = quota.limitRequests {
            parts.append("Quedan \(remaining) de \(limit)")
        }
        if let resetsAt = quota.resetsAt, let countdown = countdownString(to: resetsAt) {
            parts.append(parts.isEmpty ? "Se restablece en \(countdown)" : "reset en \(countdown)")
        }
        return parts.isEmpty ? "Cuota diaria" : parts.joined(separator: " · ")
    }

    // MARK: - Formato

    private func barColor(for percent: Double, base: Color) -> Color {
        if percent >= 90 { return Theme.error }
        if percent >= 70 { return Theme.warning }
        return base
    }

    // "Claude Opus" -> "CLAUDE_OPUS", "Gemini 2.5 Pro" -> "GEMINI_2.5_PRO"
    private func snakeCase(_ name: String) -> String {
        name.uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .joined(separator: "_")
    }

    private func countdownString(to date: Date) -> String? {
        let diff = date.timeIntervalSince(Date())
        guard diff > 0 else { return nil }

        let mins = Int(ceil(diff / 60.0))
        if mins >= 24 * 60 {
            let days = mins / (24 * 60)
            let hours = (mins % (24 * 60)) / 60
            return "\(days) d \(hours) h"
        }
        if mins >= 60 {
            return "\(mins / 60) h \(mins % 60) min"
        }
        return "\(mins) min"
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

// Barra de uso por segmentos, como un medidor de terminal.
struct SegmentedMeter: View {
    let percent: Double // 0.0 to 100.0
    let color: Color
    var segments: Int = 28

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { index in
                    Rectangle()
                        .fill(index < filledSegments ? color : Theme.border.opacity(0.5))
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
