import Foundation
import Combine

struct ModelRates {
    let name: String
    let inputRate: Double        // USD per Million tokens
    let outputRate: Double       // USD per Million tokens
    let cacheWriteRate: Double   // USD per Million tokens
    let cacheReadRate: Double    // USD per Million tokens
}

struct SessionTelemetry: Identifiable, Equatable {
    let id: String               // Session ID (filename without extension)
    let projectName: String      // Cleaned project name
    let timestamp: Date          // Date of the session
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var cost: Double
    var requestsCount: Int
    var model: String
}

struct ProjectTelemetry: Identifiable, Equatable {
    var id: String { name }      // Name is unique identifier here
    let name: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var cost: Double
    var requestsCount: Int
}

class TelemetryManager: ObservableObject {
    @Published var totalCost: Double = 0.0
    @Published var totalRequests: Int = 0
    @Published var totalInputTokens: Int = 0
    @Published var totalOutputTokens: Int = 0
    @Published var totalCacheReadTokens: Int = 0
    @Published var totalCacheWriteTokens: Int = 0
    
    @Published var recentSessions: [SessionTelemetry] = []
    @Published var projectBreakdown: [ProjectTelemetry] = []
    
    @Published var isDemoMode: Bool = false {
        didSet {
            refresh()
        }
    }
    
    @Published var lastRefreshed: Date = Date()
    @Published var isScanning: Bool = false
    
    // Cache to avoid re-parsing unchanged files
    private struct FileCacheInfo {
        let modificationDate: Date
        let size: Int
        let telemetry: SessionTelemetry
    }
    private var sessionCache: [String: FileCacheInfo] = [:]
    private let cacheLock = NSLock() // Thread-safe lock for sessionCache
    
    init() {
        refresh()
    }
    
    // Retrieves pricing rates for the given model
    func getRates(for model: String) -> ModelRates {
        let m = model.lowercased()
        if m.contains("fable") {
            // Claude Fable 5 (Reasoning and Autonomous work)
            return ModelRates(name: "Claude Fable 5", inputRate: 10.00, outputRate: 50.00, cacheWriteRate: 12.50, cacheReadRate: 1.00)
        } else if m.contains("sonnet-20241022") || m.contains("sonnet-latest") || (m.contains("sonnet") && m.contains("3-5")) {
            // Claude 3.5 Sonnet
            return ModelRates(name: "Claude 3.5 Sonnet", inputRate: 3.00, outputRate: 15.00, cacheWriteRate: 3.75, cacheReadRate: 0.30)
        } else if m.contains("haiku-20241022") || (m.contains("haiku") && m.contains("3-5")) {
            // Claude 3.5 Haiku
            return ModelRates(name: "Claude 3.5 Haiku", inputRate: 0.80, outputRate: 4.00, cacheWriteRate: 1.00, cacheReadRate: 0.08)
        } else if m.contains("opus") {
            // Claude 3 Opus
            return ModelRates(name: "Claude 3 Opus", inputRate: 15.00, outputRate: 75.00, cacheWriteRate: 18.75, cacheReadRate: 1.50)
        } else if m.contains("haiku") {
            // Claude 3 Haiku
            return ModelRates(name: "Claude 3 Haiku", inputRate: 0.25, outputRate: 1.25, cacheWriteRate: 0.3125, cacheReadRate: 0.03)
        } else if m.contains("sonnet") {
            // Claude 3 Sonnet
            return ModelRates(name: "Claude 3 Sonnet", inputRate: 3.00, outputRate: 15.00, cacheWriteRate: 3.75, cacheReadRate: 0.30)
        } else {
            // Default pricing (based on Sonnet 3.5)
            return ModelRates(name: model, inputRate: 3.00, outputRate: 15.00, cacheWriteRate: 3.75, cacheReadRate: 0.30)
        }
    }
    
    // Calculates total cost in USD for a usage object
    func calculateCost(for usage: ClaudeUsage, model: String) -> Double {
        let rates = getRates(for: model)
        let input = Double(usage.inputTokens ?? 0)
        let output = Double(usage.outputTokens ?? 0)
        let cacheWrite = Double(usage.cacheCreationInputTokens ?? 0)
        let cacheRead = Double(usage.cacheReadInputTokens ?? 0)
        
        let inputCost = (input / 1_000_000.0) * rates.inputRate
        let outputCost = (output / 1_000_000.0) * rates.outputRate
        let cacheWriteCost = (cacheWrite / 1_000_000.0) * rates.cacheWriteRate
        let cacheReadCost = (cacheRead / 1_000_000.0) * rates.cacheReadRate
        
        return inputCost + outputCost + cacheWriteCost + cacheReadCost
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
            
            var sessions: [SessionTelemetry] = []
            var projectsDict: [String: ProjectTelemetry] = [:]
            
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
                                        if let telemetry = self.parseSessionFile(at: filePath, projectName: projectName) {
                                            // Only register sessions with actual API requests to keep UI clean
                                            if telemetry.requestsCount > 0 {
                                                sessions.append(telemetry)
                                                
                                                // Aggregate project stats
                                                if var proj = projectsDict[projectName] {
                                                    proj.inputTokens += telemetry.inputTokens
                                                    proj.outputTokens += telemetry.outputTokens
                                                    proj.cacheReadTokens += telemetry.cacheReadTokens
                                                    proj.cacheWriteTokens += telemetry.cacheWriteTokens
                                                    proj.cost += telemetry.cost
                                                    proj.requestsCount += telemetry.requestsCount
                                                    projectsDict[projectName] = proj
                                                } else {
                                                    projectsDict[projectName] = ProjectTelemetry(
                                                        name: projectName,
                                                        inputTokens: telemetry.inputTokens,
                                                        outputTokens: telemetry.outputTokens,
                                                        cacheReadTokens: telemetry.cacheReadTokens,
                                                        cacheWriteTokens: telemetry.cacheWriteTokens,
                                                        cost: telemetry.cost,
                                                        requestsCount: telemetry.requestsCount
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Sort sessions by timestamp descending (most recent first)
            sessions.sort(by: { $0.timestamp > $1.timestamp })
            
            // Sort projects by cost descending
            let sortedProjects = projectsDict.values.sorted(by: { $0.cost > $1.cost })
            
            // Calculate totals
            var cost = 0.0
            var requests = 0
            var input = 0
            var output = 0
            var cRead = 0
            var cWrite = 0
            
            for session in sessions {
                cost += session.cost
                requests += session.requestsCount
                input += session.inputTokens
                output += session.outputTokens
                cRead += session.cacheReadTokens
                cWrite += session.cacheWriteTokens
            }
            
            DispatchQueue.main.async {
                self.totalCost = cost
                self.totalRequests = requests
                self.totalInputTokens = input
                self.totalOutputTokens = output
                self.totalCacheReadTokens = cRead
                self.totalCacheWriteTokens = cWrite
                
                self.recentSessions = Array(sessions.prefix(5))
                self.projectBreakdown = sortedProjects
                
                self.lastRefreshed = Date()
                self.isScanning = false
            }
        }
    }
    
    // Parse single JSONL session file
    private func parseSessionFile(at path: String, projectName: String) -> SessionTelemetry? {
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
            return cached.telemetry
        }
        
        // Read file contents
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        
        let lines = content.components(separatedBy: .newlines)
        let decoder = JSONDecoder()
        
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var cost = 0.0
        var requestsCount = 0
        var latestModel = "claude-3-5-sonnet"
        var earliestDate = modificationDate // Fallback date is modification date
        var hasDateSet = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            
            if let event = try? decoder.decode(ClaudeLogEvent.self, from: data) {
                // Parse timestamp if available
                if let tsStr = event.timestamp, let date = parseTimestamp(tsStr) {
                    if !hasDateSet {
                        earliestDate = date
                        hasDateSet = true
                    } else if date < earliestDate {
                        earliestDate = date
                    }
                }
                
                // Accumulate usage fields from assistant response
                if event.type == "assistant", let message = event.message, let usage = message.usage {
                    if let model = message.model {
                        latestModel = model
                    }
                    
                    let fileInput = usage.inputTokens ?? 0
                    let fileOutput = usage.outputTokens ?? 0
                    let fileCacheRead = usage.cacheReadInputTokens ?? 0
                    let fileCacheWrite = usage.cacheCreationInputTokens ?? 0
                    
                    inputTokens += fileInput
                    outputTokens += fileOutput
                    cacheReadTokens += fileCacheRead
                    cacheWriteTokens += fileCacheWrite
                    
                    requestsCount += 1
                    cost += calculateCost(for: usage, model: message.model ?? "claude-3-5-sonnet")
                }
            }
        }
        
        let sessionId = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        
        let telemetry = SessionTelemetry(
            id: sessionId,
            projectName: projectName,
            timestamp: earliestDate,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            cost: cost,
            requestsCount: requestsCount,
            model: latestModel
        )
        
        // Cache the parsed result
        cacheLock.lock()
        sessionCache[path] = FileCacheInfo(modificationDate: modificationDate, size: fileSize, telemetry: telemetry)
        cacheLock.unlock()
        
        return telemetry
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
    
    // Extracts and cleans the last folder name from project keys like:
    // "-Users-golfeno-Desarrollo-strata-database-engine-sql-query-parser"
    private func cleanProjectName(from folderName: String) -> String {
        let components = folderName.split(separator: "-").map(String.init)
        if let last = components.last, !last.isEmpty {
            return last
        }
        return folderName
    }
    
    // Loads beautiful mockup simulated telemetry data for demo purposes
    private func loadDemoData() {
        isScanning = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            
            let sessions = [
                SessionTelemetry(
                    id: "demo-session-1",
                    projectName: "sql-query-parser",
                    timestamp: now.addingTimeInterval(-600), // 10 mins ago
                    inputTokens: 15400,
                    outputTokens: 4200,
                    cacheReadTokens: 125000,
                    cacheWriteTokens: 18000,
                    cost: 0.1762,
                    requestsCount: 22,
                    model: "claude-3-5-sonnet"
                ),
                SessionTelemetry(
                    id: "demo-session-2",
                    projectName: "claude-menubar-telemetry",
                    timestamp: now.addingTimeInterval(-3600), // 1 hour ago
                    inputTokens: 45000,
                    outputTokens: 12500,
                    cacheReadTokens: 290000,
                    cacheWriteTokens: 48000,
                    cost: 0.5995,
                    requestsCount: 45,
                    model: "claude-fable-5"
                ),
                SessionTelemetry(
                    id: "demo-session-3",
                    projectName: "lock-manager-deadlock-detector",
                    timestamp: now.addingTimeInterval(-86400), // 1 day ago
                    inputTokens: 8500,
                    outputTokens: 2100,
                    cacheReadTokens: 45000,
                    cacheWriteTokens: 12000,
                    cost: 0.1158,
                    requestsCount: 12,
                    model: "claude-3-5-sonnet"
                ),
                SessionTelemetry(
                    id: "demo-session-4",
                    projectName: "beacon-search-engine-learning-to-rank",
                    timestamp: now.addingTimeInterval(-172800), // 2 days ago
                    inputTokens: 92000,
                    outputTokens: 28400,
                    cacheReadTokens: 890000,
                    cacheWriteTokens: 124000,
                    cost: 1.4342,
                    requestsCount: 94,
                    model: "claude-fable-5"
                )
            ]
            
            let projects = [
                ProjectTelemetry(name: "beacon-search-engine-learning-to-rank", inputTokens: 92000, outputTokens: 28400, cacheReadTokens: 890000, cacheWriteTokens: 124000, cost: 1.4342, requestsCount: 94),
                ProjectTelemetry(name: "claude-menubar-telemetry", inputTokens: 45000, outputTokens: 12500, cacheReadTokens: 290000, cacheWriteTokens: 48000, cost: 0.5995, requestsCount: 45),
                ProjectTelemetry(name: "sql-query-parser", inputTokens: 15400, outputTokens: 4200, cacheReadTokens: 125000, cacheWriteTokens: 18000, cost: 0.1762, requestsCount: 22),
                ProjectTelemetry(name: "lock-manager-deadlock-detector", inputTokens: 8500, outputTokens: 2100, cacheReadTokens: 45000, cacheWriteTokens: 12000, cost: 0.1158, requestsCount: 12)
            ]
            
            self.recentSessions = sessions
            self.projectBreakdown = projects
            
            self.totalCost = sessions.reduce(0.0, { $0 + $1.cost })
            self.totalRequests = sessions.reduce(0, { $0 + $1.requestsCount })
            self.totalInputTokens = sessions.reduce(0, { $0 + $1.inputTokens })
            self.totalOutputTokens = sessions.reduce(0, { $0 + $1.outputTokens })
            self.totalCacheReadTokens = sessions.reduce(0, { $0 + $1.cacheReadTokens })
            self.totalCacheWriteTokens = sessions.reduce(0, { $0 + $1.cacheWriteTokens })
            
            self.lastRefreshed = Date()
            self.isScanning = false
        }
    }
}

// Log line decode structs
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
