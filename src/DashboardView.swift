import SwiftUI

struct DashboardView: View {
    @ObservedObject var manager: TelemetryManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView
            
            Divider()
                .background(Theme.border)
            
            // Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // Main Grid Statistics
                    statsGridView
                    
                    // Cache Savings Indicator (ASCII Style)
                    cacheSavingsView
                    
                    // Projects Breakdown
                    projectsSectionView
                    
                    // Recent Sessions Section
                    sessionsSectionView
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
                // Total Cost Card
                statCard(
                    title: "TOTAL_COST",
                    value: String(format: "$%.4f", manager.totalCost),
                    subtitle: "USD accumulated",
                    valueColor: Theme.success
                )
                
                // Total Requests Card
                statCard(
                    title: "REQUESTS",
                    value: "\(manager.totalRequests)",
                    subtitle: "API interactions",
                    valueColor: Theme.accent
                )
            }
            
            HStack(spacing: 1) {
                // Input Tokens
                statCard(
                    title: "INPUT_TOKENS",
                    value: formatNumber(manager.totalInputTokens),
                    subtitle: "Prompt tokens sent",
                    valueColor: Theme.textPrimary
                )
                
                // Output Tokens
                statCard(
                    title: "OUTPUT_TOKENS",
                    value: formatNumber(manager.totalOutputTokens),
                    subtitle: "Completion tokens",
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
                .font(Theme.monospaced(20, weight: .bold))
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
    
    private var cacheSavingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROMPT_CACHE_EFFICIENCY")
                .font(Theme.monospaced(11, weight: .bold))
                .foregroundColor(Theme.textSecondary)
            
            VStack(alignment: .leading, spacing: 6) {
                let totalInput = manager.totalInputTokens + manager.totalCacheReadTokens + manager.totalCacheWriteTokens
                let cacheHitRatio = totalInput > 0 ? (Double(manager.totalCacheReadTokens) / Double(totalInput) * 100.0) : 0.0
                
                ConsoleProgressBar(value: cacheHitRatio)
                
                HStack {
                    Text("Read: \(formatNumber(manager.totalCacheReadTokens))")
                    Spacer()
                    Text("Write: \(formatNumber(manager.totalCacheWriteTokens))")
                }
                .font(Theme.monospaced(10))
                .foregroundColor(Theme.textMuted)
            }
            .padding(12)
            .background(Theme.cardBackground)
            .border(Theme.border, width: 1)
        }
    }
    
    private var projectsSectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROJECTS_BREAKDOWN")
                .font(Theme.monospaced(11, weight: .bold))
                .foregroundColor(Theme.textSecondary)
            
            if manager.projectBreakdown.isEmpty {
                emptyStateView(message: "No active projects logged.")
            } else {
                VStack(spacing: 0) {
                    // Table Header
                    HStack {
                        Text("PROJECT")
                            .frame(width: 140, alignment: .leading)
                        Spacer()
                        Text("REQS")
                            .frame(width: 50, alignment: .trailing)
                        Spacer()
                        Text("COST")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(Theme.monospaced(10, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.border.opacity(0.3))
                    
                    ForEach(manager.projectBreakdown) { proj in
                        Divider()
                            .background(Theme.border)
                        
                        HStack {
                            Text(proj.name)
                                .frame(width: 140, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(proj.requestsCount)")
                                .frame(width: 50, alignment: .trailing)
                            Spacer()
                            Text(String(format: "$%.4f", proj.cost))
                                .frame(width: 80, alignment: .trailing)
                                .foregroundColor(Theme.success)
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
    
    private var sessionsSectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT_SESSIONS")
                .font(Theme.monospaced(11, weight: .bold))
                .foregroundColor(Theme.textSecondary)
            
            if manager.recentSessions.isEmpty {
                emptyStateView(message: "No recent sessions parsed.")
            } else {
                VStack(spacing: 0) {
                    ForEach(manager.recentSessions) { session in
                        if session != manager.recentSessions.first {
                            Divider()
                                .background(Theme.border)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.projectName)
                                    .font(Theme.monospaced(11, weight: .bold))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Text(String(format: "$%.4f", session.cost))
                                    .font(Theme.monospaced(11, weight: .bold))
                                    .foregroundColor(Theme.success)
                            }
                            
                            HStack {
                                Text(session.model.replacingOccurrences(of: "claude-", with: ""))
                                    .lineLimit(1)
                                Spacer()
                                Text(relativeTime(from: session.timestamp))
                            }
                            .font(Theme.monospaced(9))
                            .foregroundColor(Theme.textMuted)
                        }
                        .padding(10)
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
    
    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// ASCII progress bar custom subview
struct ConsoleProgressBar: View {
    let value: Double // 0.0 to 100.0
    
    var body: some View {
        HStack(spacing: 2) {
            Text("[")
                .foregroundColor(Theme.textSecondary)
                .font(Theme.monospaced(11))
            
            let totalBlocks = 22
            let filledBlocks = min(max(Int((value / 100.0) * Double(totalBlocks)), 0), totalBlocks)
            
            Text(String(repeating: "#", count: filledBlocks))
                .foregroundColor(Theme.success)
                .font(Theme.monospaced(11))
            
            Text(String(repeating: "-", count: totalBlocks - filledBlocks))
                .foregroundColor(Theme.textMuted)
                .font(Theme.monospaced(11))
            
            Text("]")
                .foregroundColor(Theme.textSecondary)
                .font(Theme.monospaced(11))
            
            Spacer()
            
            Text(String(format: "%.1f%%", value))
                .foregroundColor(Theme.textPrimary)
                .font(Theme.monospaced(11, weight: .bold))
        }
    }
}
