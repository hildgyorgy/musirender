import Foundation

public struct DiagnosticEntry: Identifiable, Sendable, Equatable {
    public enum Level: String, Sendable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: Level,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public final class DiagnosticLog: @unchecked Sendable {
    public typealias Observer = @Sendable ([DiagnosticEntry]) -> Void

    private let lock = NSLock()
    private let limit: Int
    private var entries: [DiagnosticEntry] = []
    private var observers: [UUID: Observer] = [:]

    public init(limit: Int = 250) {
        self.limit = max(1, limit)
    }

    public func record(_ message: String, level: DiagnosticEntry.Level = .info) {
        let entry = DiagnosticEntry(level: level, message: Redactor.redact(message))
        let snapshot: [DiagnosticEntry]
        let callbacks: [Observer]

        lock.lock()
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        snapshot = entries
        callbacks = Array(observers.values)
        lock.unlock()

        callbacks.forEach { $0(snapshot) }
    }

    public func snapshot() -> [DiagnosticEntry] {
        lock.withLock { entries }
    }

    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        let snapshot: [DiagnosticEntry]
        lock.lock()
        observers[id] = observer
        snapshot = entries
        lock.unlock()
        observer(snapshot)
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.withLock { observers[id] = nil }
    }
}

public enum Redactor {
    private static let sensitiveNames: Set<String> = [
        "u", "p", "t", "s", "token", "apikey", "api_key", "password", "secret"
    ]

    public static func redact(_ text: String) -> String {
        guard let questionMark = text.firstIndex(of: "?") else { return text }
        let prefix = String(text[...questionMark])
        let query = String(text[text.index(after: questionMark)...])
        let suffixStart = query.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\r" })
        let rawQuery = suffixStart.map { String(query[..<$0]) } ?? query
        let suffix = suffixStart.map { String(query[$0...]) } ?? ""

        let sanitized = rawQuery.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { return String(pair) }
            let decoded = String(name).removingPercentEncoding?.lowercased() ?? String(name).lowercased()
            guard sensitiveNames.contains(decoded), parts.count == 2 else { return String(pair) }
            return "\(name)=<redacted>"
        }.joined(separator: "&")

        return prefix + sanitized + suffix
    }
}
