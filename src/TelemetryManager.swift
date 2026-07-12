import Foundation
import Combine

struct ClaudeRequestEvent: Equatable {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let projectName: String
}

struct ModelUsage: Identifiable, Equatable {
    var id: String { modelName }
    let modelName: String
    var requestsCount: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
}

struct QuotaReset: Identifiable, Equatable {
    var id: String { "\(timestamp.timeIntervalSince1970)-\(projectName)-\(requestsCount)" }
    let timestamp: Date          // The exact date when the quota returns (request date + 5 hours)
    let projectName: String
    let requestsCount: Int
    let tokensReturned: Int
}

class TelemetryManager: ObservableObject {
    // 5-Hour Rolling Window Metrics
    @Published var fiveHourRequests: Int = 0
    @Published var fiveHourInputTokens: Int = 0
    @Published var fiveHourOutputTokens: Int = 0
    
    // Weekly (7-Day) Metrics
    @Published var weeklyRequests: Int = 0
    @Published var weeklyInputTokens: Int = 0
    @Published var weeklyOutputTokens: Int = 0
    
    // Claude Fable 5 Specific Metrics
    @Published var fableRequests: Int = 0
    @Published var fableInputTokens: Int = 0
    @Published var fableOutputTokens: Int = 0
    @Published var fableCacheReadTokens: Int = 0
    @Published var fableCacheWriteTokens: Int = 0
    
    // Quota Resets & Model Usage Breakdown
    @Published var upcomingResets: [QuotaReset] = []
    @Published var modelUsageBreakdown: [ModelUsage] = []
    @Published var nextResetDate: Date? = nil
    
    // Configurable User Limits (persisted in UserDefaults)
    @Published var fiveHourLimit: Int {
        didSet {
            UserDefaults.standard.set(fiveHourLimit, forKey: "fiveHourLimit")
            aggregateAndPublish(lastScannedRequests)
        }
    }
    @Published var weeklyLimit: Int {
        didSet {
            UserDefaults.standard.set(weeklyLimit, forKey: "weeklyLimit")
            aggregateAndPublish(lastScannedRequests)
        }
    }
    @Published var weeklyFableLimit: Int {
        didSet {
            UserDefaults.standard.set(weeklyFableLimit, forKey: "weeklyFableLimit")
            aggregateAndPublish(lastScannedRequests)
        }
    }
    
    @Published var isDemoMode: Bool = false {
        didSet {
            refresh()
        }
    }
    
    @Published var lastRefreshed: Date = Date()
    @Published var isScanning: Bool = false
    
    // Keep requests in memory to support instant updates on limit settings modifications
    private var lastScannedRequests: [ClaudeRequestEvent] = []
    
    // Cache to avoid re-parsing unchanged files
    private struct FileCacheInfo {
        let modificationDate: Date
        let size: Int
        let requests: [ClaudeRequestEvent]
    }
    private var sessionCache: [String: FileCacheInfo] = [:]
    private let cacheLock = NSLock()
    
    init() {
        // Load persisted limits or default values
        let fLimit = UserDefaults.standard.integer(forKey: "fiveHourLimit")
        self.fiveHourLimit = fLimit == 0 ? 45 : fLimit
        
        let wLimit = UserDefaults.standard.integer(forKey: "weeklyLimit")
        self.weeklyLimit = wLimit == 0 ? 1000 : wLimit
        
        let wfLimit = UserDefaults.standard.integer(forKey: "weeklyFableLimit")
        self.weeklyFableLimit = wfLimit == 0 ? 200 : wfLimit
        
        refresh()
    }
    
    // Normalize model name for display
    func cleanModelName(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("fable") {
            return "Claude Fable 5"
        } else if m.contains("sonnet-20241022") || m.contains("sonnet-latest") || (m.contains("sonnet") && m.contains("3-5")) {
            return "Claude 3.5 Sonnet"
        } else if m.contains("haiku-20241022") || (m.contains("haiku") && m.contains("3-5")) {
            return "Claude 3.5 Haiku"
        } else if m.contains("opus") {
            return "Claude 3 Opus"
        } else if m.contains("haiku") {
            return "Claude 3 Haiku"
        } else if m.contains("sonnet") {
            return "Claude 3 Sonnet"
        } else {
            return model // Return raw model identifier
        }
    }
    
    // Trigger telemetry refresh
    func refresh() {
        if isDemoMode {
            loadDemoData()
            return
        }
        
        // Ensure parsing calls originate sequentially on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
            return
        }
        
        guard !isScanning else { return }
        isScanning = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let claudePath = homeDir.appendingPathComponent(".claude/projects").path
            
            var allRequests: [ClaudeRequestEvent] = []
            let fileManager = FileManager.default
            
            if fileManager.fileExists(atPath: claudePath) {
                if let projectDirs = try? fileManager.contentsOfDirectory(atPath: claudePath) {
                    for projectDir in projectDirs {
                        let projectPath = (claudePath as NSString).appendingPathComponent(projectDir)
                        var isDir: ObjCBool = false
                        if fileManager.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue {
                            
                            let projectName = self.cleanProjectName(from: projectDir)
                            
                            if let sessionFiles = try? fileManager.contentsOfDirectory(atPath: projectPath) {
                                for sessionFile in sessionFiles {
                                    if sessionFile.hasSuffix(".jsonl") {
                                        let filePath = (projectPath as NSString).appendingPathComponent(sessionFile)
                                        if let fileRequests = self.parseSessionFile(at: filePath, projectName: projectName) {
                                            allRequests.append(contentsOf: fileRequests)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Cache requests list to memory
            self.lastScannedRequests = allRequests
            self.aggregateAndPublish(allRequests)
        }
    }
    
    // Aggregates raw request events and publishes to main thread properties
    private func aggregateAndPublish(_ requests: [ClaudeRequestEvent]) {
        let now = Date()
        let calendar = Calendar.current
        
        // 1. Filter Time Windows
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)
        
        let fiveHourRequestsList = requests.filter { $0.timestamp >= fiveHoursAgo }
        let weeklyRequestsList = requests.filter { $0.timestamp >= sevenDaysAgo }
        
        // 2. Aggregate 5H metrics
        let f5RequestsCount = fiveHourRequestsList.count
        let f5Input = fiveHourRequestsList.reduce(0, { $0 + $1.inputTokens })
        let f5Output = fiveHourRequestsList.reduce(0, { $0 + $1.outputTokens })
        
        // 3. Aggregate Weekly metrics
        let wRequestsCount = weeklyRequestsList.count
        let wInput = weeklyRequestsList.reduce(0, { $0 + $1.inputTokens })
        let wOutput = weeklyRequestsList.reduce(0, { $0 + $1.outputTokens })
        
        // 4. Aggregate Fable metrics (weekly window)
        let weeklyFableRequestsList = weeklyRequestsList.filter { $0.model.lowercased().contains("fable") }
        let fabRequestsCount = weeklyFableRequestsList.count
        let fabInput = weeklyFableRequestsList.reduce(0, { $0 + $1.inputTokens })
        let fabOutput = weeklyFableRequestsList.reduce(0, { $0 + $1.outputTokens })
        let fabRead = weeklyFableRequestsList.reduce(0, { $0 + $1.cacheReadTokens })
        let fabWrite = weeklyFableRequestsList.reduce(0, { $0 + $1.cacheWriteTokens })
        
        // 5. Build Model Usage Table
        var modelDict: [String: ModelUsage] = [:]
        for req in requests {
            let cleanName = self.cleanModelName(req.model)
            var usage = modelDict[cleanName] ?? ModelUsage(
                modelName: cleanName,
                requestsCount: 0,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0
            )
            usage.requestsCount += 1
            usage.inputTokens += req.inputTokens
            usage.outputTokens += req.outputTokens
            usage.cacheReadTokens += req.cacheReadTokens
            usage.cacheWriteTokens += req.cacheWriteTokens
            modelDict[cleanName] = usage
        }
        let sortedModelUsage = modelDict.values.sorted(by: { $0.requestsCount > $1.requestsCount })
        
        // 6. Group upcoming resets by minute and project (for 5H list)
        var groupedResets: [Date: [String: (requests: Int, tokens: Int)]] = [:]
        
        for req in fiveHourRequestsList {
            let resetDate = req.timestamp.addingTimeInterval(5 * 3600)
            
            // Truncate to the nearest minute to group nearby requests
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resetDate)
            let minuteDate = calendar.date(from: components) ?? resetDate
            
            if groupedResets[minuteDate] == nil {
                groupedResets[minuteDate] = [:]
            }
            
            let current = groupedResets[minuteDate]?[req.projectName] ?? (requests: 0, tokens: 0)
            groupedResets[minuteDate]?[req.projectName] = (
                requests: current.requests + 1,
                tokens: current.tokens + req.inputTokens + req.outputTokens
            )
        }
        
        var resets: [QuotaReset] = []
        for (date, projectMap) in groupedResets {
            if date > now { // Future resets only
                for (project, info) in projectMap {
                    resets.append(QuotaReset(
                        timestamp: date,
                        projectName: project,
                        requestsCount: info.requests,
                        tokensReturned: info.tokens
                    ))
                }
            }
        }
        
        // Sort chronologically (next reset first)
        resets.sort(by: { $0.timestamp < $1.timestamp })
        
        // 7. Quota-Aware Block-Free Reset Date Calculation
        var resolvedNextResetDate: Date? = nil
        if f5RequestsCount > 0 {
            // Sort requests by timestamp ascending (oldest first)
            let sorted5H = fiveHourRequestsList.sorted(by: { $0.timestamp < $1.timestamp })
            
            if f5RequestsCount < self.fiveHourLimit {
                // Under limit: oldest request expiration increases quota
                resolvedNextResetDate = sorted5H.first?.timestamp.addingTimeInterval(5 * 3600)
            } else {
                // Over limit: must wait until enough requests expire to fall below limit
                let indexNeeded = f5RequestsCount - self.fiveHourLimit
                if indexNeeded < sorted5H.count {
                    resolvedNextResetDate = sorted5H[indexNeeded].timestamp.addingTimeInterval(5 * 3600)
                } else {
                    resolvedNextResetDate = sorted5H.last?.timestamp.addingTimeInterval(5 * 3600)
                }
            }
        }
        
        // Publish to main thread
        DispatchQueue.main.async {
            self.fiveHourRequests = f5RequestsCount
            self.fiveHourInputTokens = f5Input
            self.fiveHourOutputTokens = f5Output
            
            self.weeklyRequests = wRequestsCount
            self.weeklyInputTokens = wInput
            self.weeklyOutputTokens = wOutput
            
            self.fableRequests = fabRequestsCount
            self.fableInputTokens = fabInput
            self.fableOutputTokens = fabOutput
            self.fableCacheReadTokens = fabRead
            self.fableCacheWriteTokens = fabWrite
            
            self.modelUsageBreakdown = sortedModelUsage
            self.upcomingResets = resets
            self.nextResetDate = resolvedNextResetDate
            
            self.lastRefreshed = Date()
            self.isScanning = false
        }
    }
    
    // Parse single JSONL session file and extract all request-level events
    private func parseSessionFile(at path: String, projectName: String) -> [ClaudeRequestEvent]? {
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = fileAttributes[.size] as? Int,
              let modificationDate = fileAttributes[.modificationDate] as? Date else {
            return nil
        }
        
        // Fast path: Check Cache
        cacheLock.lock()
        let cached = sessionCache[path]
        cacheLock.unlock()
        
        if let cached = cached,
           cached.size == fileSize,
           cached.modificationDate == modificationDate {
            return cached.requests
        }
        
        // Read file contents
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        
        let lines = content.components(separatedBy: .newlines)
        let decoder = JSONDecoder()
        var requests: [ClaudeRequestEvent] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            
            if let event = try? decoder.decode(ClaudeLogEvent.self, from: data) {
                // Parse timestamp
                let eventDate = event.timestamp.flatMap(parseTimestamp) ?? modificationDate
                
                // If it is an assistant message containing usage, it's a request
                if event.type == "assistant", let message = event.message, let usage = message.usage {
                    let model = message.model ?? "claude-3-5-sonnet"
                    
                    let req = ClaudeRequestEvent(
                        timestamp: eventDate,
                        model: model,
                        inputTokens: usage.inputTokens ?? 0,
                        outputTokens: usage.outputTokens ?? 0,
                        cacheReadTokens: usage.cacheReadInputTokens ?? 0,
                        cacheWriteTokens: usage.cacheCreationInputTokens ?? 0,
                        projectName: projectName
                    )
                    requests.append(req)
                }
            }
        }
        
        // Cache the parsed result
        cacheLock.lock()
        sessionCache[path] = FileCacheInfo(modificationDate: modificationDate, size: fileSize, requests: requests)
        cacheLock.unlock()
        
        return requests
    }
    
    // Parse ISO8601 strings with or without fractional seconds
    private func parseTimestamp(_ tsStr: String) -> Date? {
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: tsStr) {
            return date
        }
        
        let formatterWithoutFractional = ISO8601DateFormatter()
        formatterWithoutFractional.formatOptions = [.withInternetDateTime]
        return formatterWithoutFractional.date(from: tsStr)
    }
    
    // Clean project folder name key
    private func cleanProjectName(from folderName: String) -> String {
        let components = folderName.split(separator: "-").map(String.init)
        if let last = components.last, !last.isEmpty {
            return last
        }
        return folderName
    }
    
    // Loads beautiful subscription-focused simulated telemetry data
    private func loadDemoData() {
        isScanning = true
        
        DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            
            // Build mock requests spread across different times
            let mockRequests = [
                // Last 5 Hours requests
                ClaudeRequestEvent(
                    timestamp: now.addingTimeInterval(-15 * 60), // 15 mins ago
                    model: "claude-fable-5",
                    inputTokens: 12000,
                    outputTokens: 4500,
                    cacheReadTokens: 450000,
                    cacheWriteTokens: 15000,
                    projectName: "sql-query-parser"
                ),
                ClaudeRequestEvent(
                    timestamp: now.addingTimeInterval(-45 * 60), // 45 mins ago
                    model: "claude-3-5-sonnet",
                    inputTokens: 4500,
                    outputTokens: 1800,
                    cacheReadTokens: 120000,
                    cacheWriteTokens: 8000,
                    projectName: "claude-menubar-telemetry"
                ),
                ClaudeRequestEvent(
                    timestamp: now.addingTimeInterval(-2 * 3600), // 2 hours ago
                    model: "claude-fable-5",
                    inputTokens: 25000,
                    outputTokens: 9200,
                    cacheReadTokens: 780000,
                    cacheWriteTokens: 32000,
                    projectName: "sql-query-parser"
                ),
                ClaudeRequestEvent(
                    timestamp: now.addingTimeInterval(-4 * 3600), // 4 hours ago
                    model: "claude-3-5-sonnet",
                    inputTokens: 8000,
                    outputTokens: 3100,
                    cacheReadTokens: 220000,
                    cacheWriteTokens: 12000,
                    projectName: "lock-manager"
                ),
                
                // Weekly requests (older than 5 hours)
                ClaudeRequestEvent(
                    timestamp: now.addingTimeInterval(-12 * 3600), // 12 hours ago
                    model: "claude-fable-5",
                    inputTokens: 35000,
                    outputTokens: 15400,
                    cacheReadTokens: 950000,
                    cacheWriteTokens: 52000,
                    projectName: "claude-menubar-telemetry"
                ),
                ClaudeRequestEvent(
                    timestamp: now.addingTimeInterval(-36 * 3600), // 1.5 days ago
                    model: "claude-3-5-sonnet",
                    inputTokens: 15000,
                    outputTokens: 6200,
                    cacheReadTokens: 310000,
                    cacheWriteTokens: 18000,
                    projectName: "lock-manager"
                ),
                ClaudeRequestEvent(
                    timestamp: now.addingTimeInterval(-5 * 24 * 3600), // 5 days ago
                    model: "claude-3-5-haiku",
                    inputTokens: 1200,
                    outputTokens: 650,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    projectName: "sql-query-parser"
                )
            ]
            
            self.lastScannedRequests = mockRequests
            self.aggregateAndPublish(mockRequests)
        }
    }
}

// MARK: - JSON Decodable Log Structs
struct ClaudeLogEvent: Decodable {
    let type: String
    let timestamp: String?
    let message: ClaudeMessage?
}

struct ClaudeMessage: Decodable {
    let model: String?
    let usage: ClaudeUsage?
}

struct ClaudeUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}
