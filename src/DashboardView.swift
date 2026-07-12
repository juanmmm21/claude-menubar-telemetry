import SwiftUI

struct DashboardView: View {
    @ObservedObject var manager: TelemetryManager
    
    // Live timer to refresh countdowns every second without scanning logs
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    // State to trigger UI redraw on timer tick
    @State private var tick: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView
            
            Divider()
                .background(Theme.border)
            
            // Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // Main Grid Statistics (Subscription Windows)
                    statsGridView
                    
                    // Model Usage Breakdown Table
                    modelBreakdownSectionView
                    
                    // Upcoming Quota Resets (ASCII Timeline)
                    resetsSectionView
                }
                .padding(16)
            }
            .background(Theme.background)
            
            Divider()
                .background(Theme.border)
            
            // Footer Control Bar
            footerView
        }
        .frame(width: 380, height: 500)
        .foregroundColor(Theme.textPrimary)
        .onReceive(timer) { _ in
            tick.toggle() // Forces redraw of countdown strings
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
                    .fill(manager.isDemoMode ? Theme.warning : Theme.success)
                    .frame(width: 7, height: 7)
                Text(manager.isDemoMode ? "DEMO_MODE" : "LOGS_ACTIVE")
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(manager.isDemoMode ? Theme.warning : Theme.success)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(manager.isDemoMode ? Theme.warning.opacity(0.4) : Theme.success.opacity(0.4), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.cardBackground)
    }
    
    private var statsGridView: some View {
        VStack(spacing: 1) { // 1px borders via spacing
            HStack(spacing: 1) {
                // 5-Hour rolling usage
                statCard(
                    title: "5H_ROLLING_USE",
                    value: "\(manager.fiveHourRequests) reqs",
                    subtitle: "Tokens: \(formatNumber(manager.fiveHourInputTokens + manager.fiveHourOutputTokens))",
                    valueColor: Theme.success
                )
                
                // Next reset countdown
                statCard(
                    title: "NEXT_RESET_IN",
                    value: nextResetCountdownString(),
                    subtitle: "Oldest request expiry",
                    valueColor: manager.upcomingResets.isEmpty ? Theme.textSecondary : Theme.warning
                )
            }
            
            HStack(spacing: 1) {
                // Weekly usage
                statCard(
                    title: "WEEKLY_USE_7D",
                    value: "\(manager.weeklyRequests) reqs",
                    subtitle: "Tokens: \(formatNumber(manager.weeklyInputTokens + manager.weeklyOutputTokens))",
                    valueColor: Theme.accent
                )
                
                // Claude Fable usage
                statCard(
                    title: "CLAUDE_FABLE_USE",
                    value: "\(manager.fableRequests) reqs",
                    subtitle: "Tokens: \(formatNumber(manager.fableInputTokens + manager.fableOutputTokens))",
                    valueColor: Theme.textPrimary
                )
            }
        }
        .background(Theme.border)
        .border(Theme.border, width: 1)
    }
    
    private func statCard(title: String, value: String, subtitle: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.monospaced(10, weight: .bold))
                .foregroundColor(Theme.textSecondary)
            
            Text(value)
                .font(Theme.monospaced(18, weight: .bold))
                .foregroundColor(valueColor)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            
            Text(subtitle)
                .font(Theme.monospaced(9))
                .foregroundColor(Theme.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground)
    }
    
    private var modelBreakdownSectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MODEL_USAGE_SUMMARY")
                .font(Theme.monospaced(11, weight: .bold))
                .foregroundColor(Theme.textSecondary)
            
            if manager.modelUsageBreakdown.isEmpty {
                emptyStateView(message: "No model usage events found.")
            } else {
                VStack(spacing: 0) {
                    // Table Header
                    HStack {
                        Text("MODEL")
                            .frame(width: 140, alignment: .leading)
                        Spacer()
                        Text("REQS")
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
                                .frame(width: 140, alignment: .leading)
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
    
    private var resetsSectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UPCOMING_QUOTA_RESETS (5H ROLL)")
                .font(Theme.monospaced(11, weight: .bold))
                .foregroundColor(Theme.textSecondary)
            
            if manager.upcomingResets.isEmpty {
                emptyStateView(message: "No resets pending. Active quota is full.")
            } else {
                VStack(spacing: 0) {
                    // Show next 4 resets
                    ForEach(manager.upcomingResets.prefix(4)) { reset in
                        if reset != manager.upcomingResets.first {
                            Divider()
                                .background(Theme.border)
                        }
                        
                        HStack(spacing: 0) {
                            // Countdown Tag
                            Text("[ \(formatCountdown(to: reset.timestamp)) ]")
                                .font(Theme.monospaced(10, weight: .bold))
                                .foregroundColor(Theme.warning)
                                .frame(width: 110, alignment: .leading)
                            
                            // Arrow
                            Text("-> ")
                                .font(Theme.monospaced(10))
                                .foregroundColor(Theme.textMuted)
                            
                            // Return Info
                            Text("+\(reset.requestsCount) req (\(reset.projectName))")
                                .font(Theme.monospaced(10))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            // Tokens that expire
                            Text("-\(formatNumber(reset.tokensReturned)) t")
                                .font(Theme.monospaced(10))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(10)
                    }
                    
                    if manager.upcomingResets.count > 4 {
                        Divider()
                            .background(Theme.border)
                        HStack {
                            Spacer()
                            Text("... and \(manager.upcomingResets.count - 4) more reset events")
                                .font(Theme.monospaced(9))
                                .foregroundColor(Theme.textMuted)
                                .padding(.vertical, 4)
                            Spacer()
                        }
                        .background(Theme.border.opacity(0.1))
                    }
                }
                .background(Theme.cardBackground)
                .border(Theme.border, width: 1)
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
            // Mode switch toggle
            Toggle(isOn: $manager.isDemoMode) {
                Text("DEMO")
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            
            Spacer()
            
            // Last Refresh info / scan state
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
            
            // Quit Button
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
    
    private func formatCountdown(to date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        if diff <= 0 {
            return "00h 00m 00s"
        }
        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        let seconds = Int(diff) % 60
        return String(format: "%02dh %02dm %02ds", hours, minutes, seconds)
    }
    
    private func nextResetCountdownString() -> String {
        guard let firstReset = manager.upcomingResets.first else {
            return "FULL_QUOTA"
        }
        let diff = firstReset.timestamp.timeIntervalSince(Date())
        if diff <= 0 {
            return "00h 00m 00s"
        }
        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        let seconds = Int(diff) % 60
        
        if hours > 0 {
            return String(format: "%02dh %02dm %02ds", hours, minutes, seconds)
        } else {
            return String(format: "%02dm %02ds", minutes, seconds)
        }
    }
}
