import Foundation

// Resumen de lo que Gemini CLI ha grabado en este Mac. Es solo actividad del
// CLI en esta máquina: la cuota real de la cuenta la da GeminiUsageService.
struct GeminiLocalSummary: Equatable {
    var prompts24h: Int = 0
    var tokens24h: Int = 0
    var prompts7d: Int = 0
    var tokens7d: Int = 0
    var models7d: [ModelUsage] = []

    static let empty = GeminiLocalSummary()
}

// Lee las conversaciones que Gemini CLI graba en
// ~/.gemini/tmp/<hash del proyecto>/chats/.
//
// Hay dos formatos en circulación: el antiguo, un .json con todo el
// ConversationRecord ({ messages: [...] }), y el actual, un .jsonl de solo
// añadir donde cada mensaje se vuelve a escribir entero cada vez que cambia
// (al llegar los tokens, por ejemplo). En el .jsonl se queda la última versión
// de cada id. Los rebobinados ($rewindTo) se ignoran a propósito: lo que se
// rebobina ya se había consumido.
final class GeminiLogScanner {
    private struct Message {
        let id: String
        let timestamp: Date
        let isUserPrompt: Bool
        let model: String?
        let tokens: Int
    }

    private struct CachedFile {
        let modificationDate: Date
        let size: Int
        let messages: [Message]
    }

    private var cache: [String: CachedFile] = [:]
    private let lock = NSLock()

    func scan(now: Date = Date()) -> GeminiLocalSummary {
        let fileManager = FileManager.default
        let root = GeminiPaths.sessionsRoot
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var messages: [Message] = []
        for case let url as URL in enumerator {
            guard url.pathComponents.contains("chats"),
                  url.pathExtension == "json" || url.pathExtension == "jsonl" else { continue }
            messages.append(contentsOf: parseFile(url))
        }
        return summarize(messages, now: now)
    }

    private func summarize(_ messages: [Message], now: Date) -> GeminiLocalSummary {
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)

        var summary = GeminiLocalSummary()
        var byModel: [String: ModelUsage] = [:]

        for message in messages where message.timestamp >= weekAgo {
            let isRecent = message.timestamp >= dayAgo
            if message.isUserPrompt {
                summary.prompts7d += 1
                if isRecent { summary.prompts24h += 1 }
            } else {
                summary.tokens7d += message.tokens
                if isRecent { summary.tokens24h += message.tokens }
            }

            let name = GeminiModelNames.displayName(message.model ?? "Desconocido")
            var usage = byModel[name] ?? ModelUsage(
                modelName: name,
                requestsCount: 0,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0
            )
            if message.isUserPrompt {
                usage.requestsCount += 1
            } else {
                usage.inputTokens += message.tokens
            }
            byModel[name] = usage
        }

        summary.models7d = byModel.values.sorted {
            ($0.inputTokens + $0.outputTokens) > ($1.inputTokens + $1.outputTokens)
        }
        return summary
    }

    // MARK: - Ficheros

    private func parseFile(_ url: URL) -> [Message] {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return []
        }

        lock.lock()
        let cached = cache[path]
        lock.unlock()
        if let cached = cached, cached.size == size, cached.modificationDate == modificationDate {
            return cached.messages
        }

        guard let data = try? Data(contentsOf: url) else { return [] }
        let records = url.pathExtension == "jsonl" ? Self.jsonlRecords(data) : Self.jsonRecords(data)
        let messages = Self.messages(from: records, fallbackDate: modificationDate)

        lock.lock()
        cache[path] = CachedFile(modificationDate: modificationDate, size: size, messages: messages)
        lock.unlock()
        return messages
    }

    private static func jsonRecords(_ data: Data) -> [[String: Any]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            return []
        }
        return messages
    }

    private static func jsonlRecords(_ data: Data) -> [[String: Any]] {
        var records: [[String: Any]] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }
            if json["$patch"] != nil || json["$rewindTo"] != nil {
                continue
            }
            // Puntos de control heredados: el historial completo dentro de un $set.
            if let set = json["$set"] as? [String: Any] {
                if let messages = set["messages"] as? [[String: Any]] {
                    records.append(contentsOf: messages)
                }
                continue
            }
            records.append(json)
        }
        return records
    }

    private static func messages(from records: [[String: Any]], fallbackDate: Date) -> [Message] {
        // Último estado de cada mensaje, conservando el orden de aparición.
        var latest: [String: [String: Any]] = [:]
        var order: [String] = []
        for record in records {
            guard let id = record["id"] as? String, record["type"] is String else { continue }
            if latest[id] == nil { order.append(id) }
            latest[id] = record
        }

        // Los prompts del usuario no llevan modelo: se les asigna el de la
        // respuesta que los sigue, o el primero de la sesión si no hay ninguna.
        let sessionModel = order.lazy.compactMap { latest[$0]?["model"] as? String }.first

        var result: [Message] = []
        var pendingPromptIndexes: [Int] = []
        for id in order {
            guard let record = latest[id], let type = record["type"] as? String else { continue }
            let timestamp = (record["timestamp"] as? String).flatMap(GeminiDates.parse) ?? fallbackDate

            switch type {
            case "user":
                pendingPromptIndexes.append(result.count)
                result.append(Message(id: id, timestamp: timestamp, isUserPrompt: true,
                                      model: sessionModel, tokens: 0))
            case "gemini":
                let model = record["model"] as? String ?? sessionModel
                for index in pendingPromptIndexes {
                    let prompt = result[index]
                    result[index] = Message(id: prompt.id, timestamp: prompt.timestamp,
                                            isUserPrompt: true, model: model, tokens: 0)
                }
                pendingPromptIndexes.removeAll()
                result.append(Message(id: id, timestamp: timestamp, isUserPrompt: false,
                                      model: model, tokens: tokenCount(record["tokens"])))
            default:
                // info / error / warning: mensajes de la propia interfaz.
                continue
            }
        }
        return result
    }

    private static func tokenCount(_ value: Any?) -> Int {
        guard let tokens = value as? [String: Any] else { return 0 }
        func int(_ key: String) -> Int { (tokens[key] as? NSNumber)?.intValue ?? 0 }
        let total = int("total")
        if total > 0 { return total }
        return int("input") + int("output") + int("thoughts") + int("tool")
    }
}
