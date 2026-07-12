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
    let isUserPrompt: Bool // True if it's a manual prompt typed by the user
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
    
    // Server Rate Limit Block State (Parsed from timeline.jsonl, o del dato en vivo si está disponible)
    @Published var isCurrentlyBlocked: Bool = false
    @Published var blockMessage: String? = nil

    // Cuota real de la cuenta (Desktop + web + CLI), obtenida vía AccountUsageService.
    // nil mientras no haya dato en vivo disponible: la UI debe caer de vuelta al
    // cálculo local basado en logs (ver DashboardView).
    @Published var liveQuota: UnifiedQuota? = nil
    @Published var liveQuotaUnavailableReason: String? = nil
    private let accountUsageService = AccountUsageService()
    private var lastLiveQuotaAttempt: Date = .distantPast

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
            // El dato en vivo es real de la cuenta; no tiene sentido mezclarlo con
            // datos simulados de demo, así que se limpia al entrar/salir de demo.
            liveQuota = nil
            liveQuotaUnavailableReason = nil
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
        if m == "unknown" {
            return "Desconocido"
        } else if m == "<synthetic>" {
            return "Interno (síntesis)"
        } else if m.contains("fable") {
            return "Claude Fable 5"
        } else if m.contains("opus") {
            let version = extractVersion(from: m, family: "opus")
            return version.map { "Claude Opus \($0)" } ?? "Claude Opus"
        } else if m.contains("haiku") {
            let version = extractVersion(from: m, family: "haiku")
            return version.map { "Claude Haiku \($0)" } ?? "Claude Haiku"
        } else if m.contains("sonnet") {
            let version = extractVersion(from: m, family: "sonnet")
            return version.map { "Claude Sonnet \($0)" } ?? "Claude Sonnet"
        } else {
            return model // Return raw model identifier
        }
    }

    // Extrae el número de versión adyacente al nombre de familia (p.ej. "5" en
    // "claude-sonnet-5", "4.5" en "claude-haiku-4-5-20251001"). Soporta tanto el
    // esquema actual "familia-version" como el legado "version-familia"
    // (claude-3-5-sonnet-20241022), y descarta sufijos de fecha (8 dígitos) para
    // no confundirlos con la versión. Los ids de modelo cambian con cada
    // generación (Claude 3 -> 3.5 -> 5), así que hacer esto genérico evita tener
    // que volver a tocar este fichero cada vez que sale un modelo nuevo.
    private func extractVersion(from model: String, family: String) -> String? {
        let parts = model.split(separator: "-").map(String.init)
        guard let familyIndex = parts.firstIndex(where: { $0.contains(family) }) else { return nil }

        func isVersionComponent(_ s: String) -> Bool {
            !s.isEmpty && s.count < 8 && s.allSatisfy { $0.isNumber }
        }

        var trailing: [String] = []
        var idx = familyIndex + 1
        while idx < parts.count, isVersionComponent(parts[idx]) {
            trailing.append(parts[idx])
            idx += 1
        }
        if !trailing.isEmpty {
            return trailing.joined(separator: ".")
        }

        var leading: [String] = []
        idx = familyIndex - 1
        while idx >= 0, isVersionComponent(parts[idx]) {
            leading.insert(parts[idx], at: 0)
            idx -= 1
        }
        return leading.isEmpty ? nil : leading.joined(separator: ".")
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
        refreshLiveQuotaIfDue()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let claudePath = homeDir.appendingPathComponent(".claude/projects").path
            
            var allRequests: [ClaudeRequestEvent] = []
            let fileManager = FileManager.default
            
            if fileManager.fileExists(atPath: claudePath) {
                let url = URL(fileURLWithPath: claudePath)
                let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: nil)
                
                if let enumerator = enumerator {
                    for case let fileURL as URL in enumerator {
                        if fileURL.pathExtension == "jsonl" {
                            // Extract project name from the path component right below ~/.claude/projects/
                            let pathComponents = fileURL.pathComponents
                            var projectName = "unknown"
                            if let idx = pathComponents.firstIndex(of: "projects"), idx + 1 < pathComponents.count {
                                projectName = self.cleanProjectName(from: pathComponents[idx + 1])
                            }
                            
                            if let fileRequests = self.parseSessionFile(at: fileURL.path, projectName: projectName) {
                                allRequests.append(contentsOf: fileRequests)
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

    // Pide el dato real de cuota a AccountUsageService, con un intervalo mínimo
    // entre intentos: cada llamada usa una petición real a la API (coste de
    // cuota despreciable pero no nulo), así que no tiene sentido dispararla en
    // cada refresh() si el usuario abre y cierra el popover repetidamente.
    private let minimumLiveQuotaInterval: TimeInterval = 60

    private func refreshLiveQuotaIfDue() {
        guard Date().timeIntervalSince(lastLiveQuotaAttempt) >= minimumLiveQuotaInterval else { return }
        lastLiveQuotaAttempt = Date()

        accountUsageService.fetchLiveQuota { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let quota):
                    self.liveQuota = quota
                    self.liveQuotaUnavailableReason = nil
                    self.isCurrentlyBlocked = quota.isRateLimited
                    self.nextResetDate = quota.fiveHourReset
                case .failure(let error):
                    self.liveQuota = nil
                    switch error {
                    case .notLoggedIn:
                        self.liveQuotaUnavailableReason = "Sin sesión de Claude Code en este Mac"
                    case .keychainAccessDenied:
                        self.liveQuotaUnavailableReason = "Permiso de Keychain denegado — autorízalo en el aviso del sistema"
                    case .sessionExpired:
                        self.liveQuotaUnavailableReason = "Sesión de Claude Code caducada — ábrelo para refrescarla"
                    case .network:
                        self.liveQuotaUnavailableReason = "Sin conexión con Anthropic"
                    case .unavailable:
                        self.liveQuotaUnavailableReason = "Dato en vivo no disponible ahora mismo"
                    }
                }
            }
        }
    }

    // Checks if the user is currently blocked by parsing timeline.jsonl files
    private func checkBlockStateFromTimeline() -> (isBlocked: Bool, resetDate: Date?, message: String?) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let jobsPath = homeDir.appendingPathComponent(".claude/jobs").path
        let fileManager = FileManager.default
        
        var latestTimelineURL: URL? = nil
        var latestModDate: Date = .distantPast
        
        if fileManager.fileExists(atPath: jobsPath) {
            let url = URL(fileURLWithPath: jobsPath)
            if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [], errorHandler: nil) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent == "timeline.jsonl" {
                        if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                           let modDate = attrs[FileAttributeKey.modificationDate] as? Date {
                            if modDate > latestModDate {
                                latestModDate = modDate
                                latestTimelineURL = fileURL
                            }
                        }
                    }
                }
            }
        }
        
        guard let timelineURL = latestTimelineURL,
              let content = try? String(contentsOfFile: timelineURL.path, encoding: .utf8) else {
            return (false, nil, nil)
        }
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = json["state"] as? String {
                
                if state == "blocked" {
                    let detail = json["detail"] as? String ?? ""
                    let atStr = json["at"] as? String
                    let blockTime = atStr.flatMap(parseTimestamp) ?? latestModDate
                    
                    if let resetDate = parseResetDateFromDetail(detail, blockTime: blockTime) {
                        if resetDate > Date() {
                            return (true, resetDate, detail)
                        }
                    }
                } else if state == "done" || state == "running" || state == "idle" {
                    return (false, nil, nil)
                }
            }
        }
        
        return (false, nil, nil)
    }
    
    // Parse time strings in format "resets 3:40pm" or "15:40"
    private func parseResetDateFromDetail(_ detail: String, blockTime: Date) -> Date? {
        guard let resetsRange = detail.range(of: "resets ") else { return nil }
        let timePart = detail[resetsRange.upperBound...]
        let components = timePart.split(separator: " ")
        guard let timeStrComponent = components.first else { return nil }
        let timeStr = String(timeStrComponent)
        
        let calendar = Calendar.current
        var targetHour = 0
        var targetMinute = 0
        
        if timeStr.lowercased().contains("pm") || timeStr.lowercased().contains("am") {
            let cleaned = timeStr.lowercased().replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "")
            let parts = cleaned.split(separator: ":")
            guard parts.count >= 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]) else { return nil }
            
            targetHour = hour
            targetMinute = minute
            
            if timeStr.lowercased().contains("pm") && hour < 12 {
                targetHour += 12
            } else if timeStr.lowercased().contains("am") && hour == 12 {
                targetHour = 0
            }
        } else {
            let parts = timeStr.split(separator: ":")
            guard parts.count >= 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]) else { return nil }
            targetHour = hour
            targetMinute = minute
        }
        
        var resetComponents = calendar.dateComponents([.year, .month, .day], from: blockTime)
        resetComponents.hour = targetHour
        resetComponents.minute = targetMinute
        resetComponents.second = 0
        
        if let candidateDate = calendar.date(from: resetComponents) {
            if candidateDate < blockTime {
                return calendar.date(byAdding: .day, value: 1, to: candidateDate)
            }
            return candidateDate
        }
        return nil
    }
    
    // Updates block status and triggers UI redraw if needed
    func updateBlockStateIfNeeded() {
        if isDemoMode { return }
        // Con dato en vivo, el estado de bloqueo ya lo marca refreshLiveQuotaIfDue()
        // con la señal real de la cuenta; no lo pisamos con el parseo de timeline.jsonl.
        if liveQuota != nil { return }

        let blockState = checkBlockStateFromTimeline()
        
        if blockState.isBlocked != self.isCurrentlyBlocked || blockState.resetDate != self.nextResetDate {
            DispatchQueue.main.async {
                self.isCurrentlyBlocked = blockState.isBlocked
                self.blockMessage = blockState.message
                if blockState.isBlocked, let rDate = blockState.resetDate {
                    self.fiveHourRequests = self.fiveHourLimit
                    self.nextResetDate = rDate
                } else {
                    self.refresh() // Restore standard aggregates
                }
            }
        }
    }
    
    // Aggregates raw request events and publishes to main thread properties
    private func aggregateAndPublish(_ requests: [ClaudeRequestEvent]) {
        let now = Date()
        let calendar = Calendar.current
        
        // 1. Split user prompts vs assistant usage logs
        let prompts = requests.filter { $0.isUserPrompt }
        let usages = requests.filter { !$0.isUserPrompt }
        
        // 2. Filter Time Windows
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)
        
        let fiveHourPrompts = prompts.filter { $0.timestamp >= fiveHoursAgo }
        let fiveHourUsages = usages.filter { $0.timestamp >= fiveHoursAgo }
        
        let weeklyPrompts = prompts.filter { $0.timestamp >= sevenDaysAgo }
        let weeklyUsages = usages.filter { $0.timestamp >= sevenDaysAgo }
        
        // 3. Aggregate 5H metrics (messages count based on prompts, tokens on usages)
        let f5RequestsCount = fiveHourPrompts.count
        let f5Input = fiveHourUsages.reduce(0, { $0 + $1.inputTokens })
        let f5Output = fiveHourUsages.reduce(0, { $0 + $1.outputTokens })
        
        // 4. Aggregate Weekly metrics
        let wRequestsCount = weeklyPrompts.count
        let wInput = weeklyUsages.reduce(0, { $0 + $1.inputTokens })
        let wOutput = weeklyUsages.reduce(0, { $0 + $1.outputTokens })
        
        // 5. Aggregate Fable metrics (weekly window)
        let weeklyFablePrompts = weeklyPrompts.filter { $0.model.lowercased().contains("fable") }
        let weeklyFableUsages = weeklyUsages.filter { $0.model.lowercased().contains("fable") }
        
        let fabRequestsCount = weeklyFablePrompts.count
        let fabInput = weeklyFableUsages.reduce(0, { $0 + $1.inputTokens })
        let fabOutput = weeklyFableUsages.reduce(0, { $0 + $1.outputTokens })
        let fabRead = weeklyFableUsages.reduce(0, { $0 + $1.cacheReadTokens })
        let fabWrite = weeklyFableUsages.reduce(0, { $0 + $1.cacheWriteTokens })
        
        // 6. Build Model Usage Table
        var modelDict: [String: ModelUsage] = [:]
        for p in prompts {
            let cleanName = self.cleanModelName(p.model)
            var usage = modelDict[cleanName] ?? ModelUsage(
                modelName: cleanName,
                requestsCount: 0,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0
            )
            usage.requestsCount += 1
            modelDict[cleanName] = usage
        }
        for u in usages {
            let cleanName = self.cleanModelName(u.model)
            var usage = modelDict[cleanName] ?? ModelUsage(
                modelName: cleanName,
                requestsCount: 0,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0
            )
            usage.inputTokens += u.inputTokens
            usage.outputTokens += u.outputTokens
            usage.cacheReadTokens += u.cacheReadTokens
            usage.cacheWriteTokens += u.cacheWriteTokens
            modelDict[cleanName] = usage
        }
        let sortedModelUsage = modelDict.values.sorted(by: { $0.requestsCount > $1.requestsCount })
        
        // 7. Group upcoming resets by minute and project (for 5H list based on prompts)
        var groupedResets: [Date: [String: (requests: Int, tokens: Int)]] = [:]
        
        for req in fiveHourPrompts {
            let resetDate = req.timestamp.addingTimeInterval(5 * 3600)
            
            // Truncate to the nearest minute to group nearby requests
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resetDate)
            let minuteDate = calendar.date(from: components) ?? resetDate
            
            if groupedResets[minuteDate] == nil {
                groupedResets[minuteDate] = [:]
            }
            
            // Find tokens close to this prompt time to estimate tokens freed up
            let promptRangeStart = req.timestamp.addingTimeInterval(-30)
            let promptRangeEnd = req.timestamp.addingTimeInterval(30)
            let associatedTokens = fiveHourUsages.filter { 
                $0.timestamp >= promptRangeStart && $0.timestamp <= promptRangeEnd 
            }.reduce(0, { $0 + $1.inputTokens + $1.outputTokens })
            
            let current = groupedResets[minuteDate]?[req.projectName] ?? (requests: 0, tokens: 0)
            groupedResets[minuteDate]?[req.projectName] = (
                requests: current.requests + 1,
                tokens: current.tokens + associatedTokens
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
        
        // 8. Quota-Aware Block-Free Reset Date Calculation based on user prompts
        var resolvedNextResetDate: Date? = nil
        if f5RequestsCount > 0 {
            let sorted5H = fiveHourPrompts.sorted(by: { $0.timestamp < $1.timestamp })
            
            if f5RequestsCount < self.fiveHourLimit {
                resolvedNextResetDate = sorted5H.first?.timestamp.addingTimeInterval(5 * 3600)
            } else {
                let indexNeeded = f5RequestsCount - self.fiveHourLimit
                if indexNeeded < sorted5H.count {
                    resolvedNextResetDate = sorted5H[indexNeeded].timestamp.addingTimeInterval(5 * 3600)
                } else {
                    resolvedNextResetDate = sorted5H.last?.timestamp.addingTimeInterval(5 * 3600)
                }
            }
        }
        
        // 9. Check real-time rate limit timeline block
        let blockState = checkBlockStateFromTimeline()
        
        // Publish to main thread
        DispatchQueue.main.async {
            // Si ya hay dato en vivo de la cuenta, es más fiable que este parseo
            // local de timeline.jsonl: no lo pisamos con la estimación local.
            if self.liveQuota == nil {
                self.isCurrentlyBlocked = blockState.isBlocked
                self.blockMessage = blockState.message

                if blockState.isBlocked, let rDate = blockState.resetDate {
                    self.fiveHourRequests = self.fiveHourLimit
                    self.nextResetDate = rDate
                } else {
                    self.fiveHourRequests = f5RequestsCount
                    self.nextResetDate = resolvedNextResetDate
                }
            } else {
                self.fiveHourRequests = f5RequestsCount
            }

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
            
            self.lastRefreshed = Date()
            self.isScanning = false
        }
    }
    
    // Parse single JSONL session file using native JSONSerialization for absolute robustness
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
        var requests: [ClaudeRequestEvent] = []
        
        // Pass 1: Find model used in this session file
        // "unknown" en vez de un id de modelo real fijo: si no se detecta ninguno,
        // cleanModelName lo etiqueta explícitamente como "Desconocido" en vez de
        // mezclarlo silenciosamente con las cifras de un modelo real.
        var detectedModel = "unknown"
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String, type == "assistant",
               let message = json["message"] as? [String: Any],
               let model = message["model"] as? String {
                detectedModel = model
                break
            }
        }
        
        // Pass 2: Extract prompts and token usages
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String {
                
                let tsStr = json["timestamp"] as? String
                let eventDate = tsStr.flatMap(parseTimestamp) ?? modificationDate
                
                if type == "user",
                   let message = json["message"] as? [String: Any],
                   let content = message["content"] {

                    // Content is String both for prompts realmente escritos por el usuario y para
                    // eventos inyectados por el sistema (task-notifications de jobs en background,
                    // resúmenes de auto-compact, reinyecciones "isMeta"). Solo "origin.kind == human"
                    // distingue de forma fiable un prompt humano real; sin este filtro el contador
                    // semanal llegó a inflarse ~30% con eventos que no consume el propio usuario.
                    let origin = json["origin"] as? [String: Any]
                    let isHumanPrompt = (origin?["kind"] as? String) == "human"

                    if content is String, isHumanPrompt {
                        let req = ClaudeRequestEvent(
                            timestamp: eventDate,
                            model: detectedModel,
                            inputTokens: 0,
                            outputTokens: 0,
                            cacheReadTokens: 0,
                            cacheWriteTokens: 0,
                            projectName: projectName,
                            isUserPrompt: true
                        )
                        requests.append(req)
                    }
                } else if type == "assistant",
                          let message = json["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any] {
                    
                    let model = message["model"] as? String ?? detectedModel
                    let input = usage["input_tokens"] as? Int ?? 0
                    let output = usage["output_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                    
                    let req = ClaudeRequestEvent(
                        timestamp: eventDate,
                        model: model,
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: cacheRead,
                        cacheWriteTokens: cacheWrite,
                        projectName: projectName,
                        isUserPrompt: false
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
            
            // Build mock requests: prompts (prompts count) and usages (tokens)
            let mockRequests = [
                // Session Prompts (Last 5 Hours)
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-15 * 60), model: "claude-fable-5", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, projectName: "sql-query-parser", isUserPrompt: true),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-45 * 60), model: "claude-3-5-sonnet", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, projectName: "claude-menubar-telemetry", isUserPrompt: true),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-2 * 3600), model: "claude-fable-5", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, projectName: "sql-query-parser", isUserPrompt: true),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-4 * 3600), model: "claude-3-5-sonnet", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, projectName: "lock-manager", isUserPrompt: true),
                
                // Session Tokens (Last 5 Hours)
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-14 * 60), model: "claude-fable-5", inputTokens: 12000, outputTokens: 4500, cacheReadTokens: 450000, cacheWriteTokens: 15000, projectName: "sql-query-parser", isUserPrompt: false),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-44 * 60), model: "claude-3-5-sonnet", inputTokens: 4500, outputTokens: 1800, cacheReadTokens: 120000, cacheWriteTokens: 8000, projectName: "claude-menubar-telemetry", isUserPrompt: false),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-1 * 3600 - 59 * 60), model: "claude-fable-5", inputTokens: 25000, outputTokens: 9200, cacheReadTokens: 780000, cacheWriteTokens: 32000, projectName: "sql-query-parser", isUserPrompt: false),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-3 * 3600 - 59 * 60), model: "claude-3-5-sonnet", inputTokens: 8000, outputTokens: 3100, cacheReadTokens: 220000, cacheWriteTokens: 12000, projectName: "lock-manager", isUserPrompt: false),
                
                // Weekly Prompts
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-12 * 3600), model: "claude-fable-5", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, projectName: "claude-menubar-telemetry", isUserPrompt: true),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-36 * 3600), model: "claude-3-5-sonnet", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, projectName: "lock-manager", isUserPrompt: true),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-5 * 24 * 3600), model: "claude-3-5-haiku", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, projectName: "sql-query-parser", isUserPrompt: true),
                
                // Weekly Tokens
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-11 * 3600), model: "claude-fable-5", inputTokens: 35000, outputTokens: 15400, cacheReadTokens: 950000, cacheWriteTokens: 52000, projectName: "claude-menubar-telemetry", isUserPrompt: false),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-35 * 3600), model: "claude-3-5-sonnet", inputTokens: 15000, outputTokens: 6200, cacheReadTokens: 310000, cacheWriteTokens: 18000, projectName: "lock-manager", isUserPrompt: false),
                ClaudeRequestEvent(timestamp: now.addingTimeInterval(-5 * 24 * 3600 + 60), model: "claude-3-5-haiku", inputTokens: 1200, outputTokens: 650, cacheReadTokens: 0, cacheWriteTokens: 0, projectName: "sql-query-parser", isUserPrompt: false)
            ]
            
            self.lastScannedRequests = mockRequests
            self.aggregateAndPublish(mockRequests)
        }
    }
}
