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
                    
                    // Warning Banner if Claude Code session is active blocked
                    if manager.isCurrentlyBlocked {
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
                    .fill(manager.isDemoMode ? Theme.warning : (manager.isCurrentlyBlocked ? Theme.error : Theme.success))
                    .frame(width: 7, height: 7)
                Text(manager.isDemoMode ? "DEMO_MODE" : (manager.isCurrentlyBlocked ? "RATE_LIMITED" : "LOGS_ACTIVE"))
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(manager.isDemoMode ? Theme.warning : (manager.isCurrentlyBlocked ? Theme.error : Theme.success))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(manager.isDemoMode ? Theme.warning.opacity(0.4) : (manager.isCurrentlyBlocked ? Theme.error.opacity(0.4) : Theme.success.opacity(0.4)), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.cardBackground)
    }
    
    // 1. Uso de cuenta (dato real si hay sesión de Claude Code; si no, aproximación por logs del CLI)
    private var proLimitsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.liveQuota != nil ? "Uso de tu cuenta Claude" : "Uso de Claude Code (CLI)")
                    .font(Theme.monospaced(12, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                Text(proScopeCaption)
                    .font(Theme.monospaced(8))
                    .foregroundColor(Theme.textMuted)
            }

            let pct: Double = {
                if let live = manager.liveQuota {
                    return min(live.fiveHourUtilization * 100.0, 100.0)
                }
                return min(Double(manager.fiveHourRequests) / Double(manager.fiveHourLimit) * 100.0, 100.0)
            }()
            let barColor = (pct >= 90 || manager.isCurrentlyBlocked) ? Theme.error : (pct >= 70 ? Theme.warning : Theme.accent)
            
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
                CustomProgressBar(value: manager.isCurrentlyBlocked ? 100.0 : pct, color: barColor)
                    .frame(height: 6)
                
                // Percentage Text (Right)
                Text(manager.isCurrentlyBlocked ? "100% usado" : "\(Int(pct))% usado")
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 75, alignment: .trailing)
            }
            .padding(10)
            .background(Theme.cardBackground)
            .border(Theme.border, width: 1)
        }
    }
    
    // 2. Límites semanales (dato real para "Todos los modelos" si hay sesión; Fable siempre es aproximación local)
    private var weeklyLimitsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Límites semanales")
                    .font(Theme.monospaced(12, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                Text("Fable siempre es aproximación por logs del CLI")
                    .font(Theme.monospaced(8))
                    .foregroundColor(Theme.textMuted)
            }

            VStack(spacing: 0) {
                // Row 1: Todos los modelos
                let pctAll: Double = {
                    if let live = manager.liveQuota {
                        return min(live.sevenDayUtilization * 100.0, 100.0)
                    }
                    return min(Double(manager.weeklyRequests) / Double(manager.weeklyLimit) * 100.0, 100.0)
                }()
                let colorAll = pctAll >= 90 ? Theme.error : (pctAll >= 70 ? Theme.warning : Theme.accent)
                let weeklyResetLabel = manager.liveQuota.map { formatWeeklyReset($0.sevenDayReset) } ?? "Se restablece dom, 8:00"

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Todos los modelos")
                            .font(Theme.monospaced(11, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                        Text(weeklyResetLabel)
                            .font(Theme.monospaced(9))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(width: 135, alignment: .leading)
                    
                    CustomProgressBar(value: pctAll, color: colorAll)
                        .frame(height: 6)
                    
                    Text("\(Int(pctAll))% usado")
                        .font(Theme.monospaced(10, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 75, alignment: .trailing)
                }
                .padding(10)
                
                Divider()
                    .background(Theme.border)

                // Row 2: Fable. Anthropic no expone una cuota separada por modelo
                // (las cabeceras en vivo solo dan la utilización total de la
                // cuenta), así que aquí no se finge un %: es un contador simple.
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fable")
                            .font(Theme.monospaced(11, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                        Text("No hay cuota separada por modelo")
                            .font(Theme.monospaced(9))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(width: 135, alignment: .leading)

                    Spacer()

                    Text("\(manager.fableRequests) prompts · \(formatNumber(manager.fableInputTokens + manager.fableOutputTokens)) tok")
                        .font(Theme.monospaced(10, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                }
                .padding(10)
            }
            .background(Theme.cardBackground)
            .border(Theme.border, width: 1)
        }
    }
    
    // 3. Model Breakdown Table
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
    
    // 4. Config Drawer at bottom
    private var settingsDrawerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSettings.toggle()
                }
            }) {
                HStack {
                    Text(showSettings ? "[-] OCULTAR CONFIGURACIÓN" : "[+] AJUSTAR LÍMITES DE SUSCRIPCIÓN")
                        .font(Theme.monospaced(10, weight: .bold))
                        .foregroundColor(Theme.accent)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            
            if showSettings {
                VStack(spacing: 10) {
                    Text("Solo se usan cuando no hay dato en vivo de la cuenta disponible")
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
                .padding(.vertical, 16)
            Spacer()
        }
        .background(Theme.cardBackground)
        .border(Theme.border, width: 1)
    }
    
    private var footerView: some View {
        HStack {
            Toggle(isOn: $manager.isDemoMode) {
                Text("DEMO")
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            
            Spacer()
            
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
    
    private func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000.0)
        } else if num >= 1_000 {
            return String(format: "%.1fK", Double(num) / 1_000.0)
        }
        return "\(num)"
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    private func sessionResetTimeString() -> String {
        guard let resetDate = manager.nextResetDate else {
            return "Cuota completa"
        }
        let diff = resetDate.timeIntervalSince(Date())
        if diff <= 0 {
            return "Restablecido"
        }
        
        let mins = Int(ceil(diff / 60.0))
        let labelPrefix = manager.isCurrentlyBlocked ? "Límite: restablece en" : "Se restablece en"
        
        if mins >= 60 {
            let hours = mins / 60
            let remainingMins = mins % 60
            return "\(labelPrefix) \(hours) h \(remainingMins) min"
        } else {
            return "\(labelPrefix) \(mins) min"
        }
    }

    private var proScopeCaption: String {
        if manager.liveQuota != nil {
            return "Dato real de tu cuenta (Desktop + web + CLI)"
        }
        if let reason = manager.liveQuotaUnavailableReason {
            return "Aproximación por logs del CLI · \(reason)"
        }
        return "Solo terminal · no incluye Desktop, web ni móvil"
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
