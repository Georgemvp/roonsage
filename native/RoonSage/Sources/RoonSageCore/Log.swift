import Foundation
import os

// Gedeelde logger voor de macOS- én iOS-app. Twee doelen tegelijk:
//
//   1. `os.Logger` (unified logging) — zichtbaar in Console.app en de Xcode-
//      debugconsole, met subsystem/category-filtering.
//   2. Een platte-tekst bestand-sink — één doorlopend logbestand dat je in zijn
//      geheel kunt kopiëren of delen (zie `LogConsoleView`) om met Claude te
//      delen. Dát is de hele reden dat dit naast os.Logger bestaat: Console-logs
//      zijn lastig integraal te exporteren, een bestand niet.
//
// Gebruik:
//
//   Log.info("Verbonden met core", category: .roon)
//   Log.warning("Sync traag (\(ms) ms)", category: .sync)
//   Log.error("Decode faalde: \(error)", category: .audio)
//
// De bestand-sink schrijft asynchroon op een eigen seriële queue, dus loggen
// blokkeert de aanroeper niet. Het bestand roteert bij ~5 MB (huidig + 1 oud),
// zodat het nooit ongelimiteerd groeit.

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, notice, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .notice:  return "NOTICE"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    var osType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .notice:  return .default
        case .warning: return .default   // os.log kent geen 'warning'; .default + WARN-label volstaat
        case .error:   return .error
        }
    }
}

/// Vaste categorieën zodat het bestand consistent gefilterd kan worden.
/// Voeg gerust toe — het is een gewone string-enum.
public enum LogCategory: String, Sendable {
    case app, roon, sync, audio, network, db, ui, llm, scrobble
}

public enum Log {
    /// Niveaus onder deze drempel worden genegeerd (zowel os.log als bestand).
    /// Standaard `.debug` in DEBUG-builds, anders `.info`.
    public static var minimumLevel: LogLevel = {
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()

    public static func debug(_ message: @autoclosure () -> String,
                             category: LogCategory = .app,
                             file: String = #fileID, line: Int = #line) {
        log(.debug, message(), category, file, line)
    }

    public static func info(_ message: @autoclosure () -> String,
                            category: LogCategory = .app,
                            file: String = #fileID, line: Int = #line) {
        log(.info, message(), category, file, line)
    }

    public static func notice(_ message: @autoclosure () -> String,
                              category: LogCategory = .app,
                              file: String = #fileID, line: Int = #line) {
        log(.notice, message(), category, file, line)
    }

    public static func warning(_ message: @autoclosure () -> String,
                               category: LogCategory = .app,
                               file: String = #fileID, line: Int = #line) {
        log(.warning, message(), category, file, line)
    }

    public static func error(_ message: @autoclosure () -> String,
                             category: LogCategory = .app,
                             file: String = #fileID, line: Int = #line) {
        log(.error, message(), category, file, line)
    }

    // MARK: - Kern

    private static func log(_ level: LogLevel,
                            _ message: String,
                            _ category: LogCategory,
                            _ file: String,
                            _ line: Int) {
        guard level >= minimumLevel else { return }
        // os.log: zichtbaar in Console.app / Xcode, privacy: .public zodat de
        // boodschap niet als <private> wordt geredacteerd in de eigen app.
        LogStore.shared.osLogger(category).log(level: level.osType, "\(message, privacy: .public)")
        // Bestand-sink (asynchroon).
        LogStore.shared.append(level: level, category: category, message: message, file: file, line: line)
    }

    // MARK: - Export / beheer

    /// URL van het huidige logbestand.
    public static var fileURL: URL { LogStore.shared.currentFileURL }

    /// De volledige logtekst (oud + huidig bestand samengevoegd, oudste eerst).
    /// Dit is wat je kopieert of deelt met Claude.
    public static func fullText() -> String { LogStore.shared.fullText() }

    /// Schrijft een momentopname van de volledige log naar een tijdelijk
    /// `.txt`-bestand en geeft de URL terug — geschikt voor `ShareLink`
    /// (delen/Bewaar-in-Bestanden op iOS, deel-sheet op macOS).
    public static func exportSnapshot() -> URL { LogStore.shared.exportSnapshot() }

    /// Wist alle logbestanden en begint opnieuw.
    public static func clear() { LogStore.shared.clear() }

    /// Map waarin de logbestanden staan (handig voor "Toon in Finder" op macOS).
    public static var directory: URL { LogStore.shared.directory }
}

// MARK: - Bestand-sink

/// Beheert de fysieke logbestanden op een seriële queue. Niet bedoeld voor
/// direct gebruik buiten `Log`.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let queue = DispatchQueue(label: "com.roonsage.log", qos: .utility)
    private let fileManager = FileManager.default
    private let maxBytes = 5 * 1024 * 1024          // roteer bij ~5 MB
    private let subsystem = Bundle.main.bundleIdentifier ?? "com.roonsage"

    private var handle: FileHandle?
    private var loggers: [LogCategory: Logger] = [:]

    let directory: URL
    let currentFileURL: URL
    private let rotatedFileURL: URL

    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        // Zelfde conventie als RoonClient.databaseURL: Application Support/RoonSage/.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = appSupport.appendingPathComponent("RoonSage/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        currentFileURL = directory.appendingPathComponent("roonsage.log")
        rotatedFileURL = directory.appendingPathComponent("roonsage.log.1")
        writeHeader()
    }

    func osLogger(_ category: LogCategory) -> Logger {
        // os.Logger is goedkoop maar we cachen per categorie. Toegang is alleen
        // vanaf de aanroeper-thread; race is onschadelijk (idempotente init).
        if let l = loggers[category] { return l }
        let l = Logger(subsystem: subsystem, category: category.rawValue)
        loggers[category] = l
        return l
    }

    func append(level: LogLevel, category: LogCategory, message: String, file: String, line: Int) {
        queue.async {
            let line = "\(self.stamp.string(from: Date())) [\(level.label)] [\(category.rawValue)] \(message)  (\(file):\(line))\n"
            self.write(line)
        }
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let fh = openHandle()
        fh?.write(data)
        rotateIfNeeded(fh)
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        if !fileManager.fileExists(atPath: currentFileURL.path) {
            fileManager.createFile(atPath: currentFileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: currentFileURL)
        try? handle?.seekToEnd()
        return handle
    }

    private func rotateIfNeeded(_ fh: FileHandle?) {
        guard let size = try? fh?.offset(), size > UInt64(maxBytes) else { return }
        try? handle?.close()
        handle = nil
        try? fileManager.removeItem(at: rotatedFileURL)
        try? fileManager.moveItem(at: currentFileURL, to: rotatedFileURL)
        writeHeader()
    }

    /// Eén kopregel per (her)start zodat sessies in het bestand herkenbaar zijn.
    private func writeHeader() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        #if os(macOS)
        let platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let platform = "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        queue.async {
            let header = """
            ──────────────────────────────────────────────
            RoonSage v\(v) (build \(b)) · \(platform)
            sessie gestart \(self.stamp.string(from: Date()))
            ──────────────────────────────────────────────

            """
            self.write(header)
        }
    }

    // MARK: - Export

    func fullText() -> String {
        queue.sync {
            try? handle?.synchronize()
            let old = (try? String(contentsOf: rotatedFileURL, encoding: .utf8)) ?? ""
            let cur = (try? String(contentsOf: currentFileURL, encoding: .utf8)) ?? ""
            return old + cur
        }
    }

    func exportSnapshot() -> URL {
        let text = fullText()
        let url = fileManager.temporaryDirectory.appendingPathComponent("roonsage-log.txt")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    func clear() {
        queue.sync {
            try? handle?.close()
            handle = nil
            try? fileManager.removeItem(at: currentFileURL)
            try? fileManager.removeItem(at: rotatedFileURL)
        }
        writeHeader()
    }
}
