import Foundation
import LocalAuthentication
import Security
import SQLite3

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var userAgent: String { "Uso/\(current)" }
}
enum JSON {
    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func value(_ any: Any?, key: String) -> Any? {
        (any as? [String: Any])?[key]
    }

    static func dictionary(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(_ any: Any?) -> [Any] {
        any as? [Any] ?? []
    }

    static func string(_ any: Any?) -> String? {
        if let string = any as? String { return string }
        if let number = any as? NSNumber { return number.stringValue }
        return nil
    }

    static func double(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let string = any as? String { return Double(string) }
        return nil
    }

    static func int64(_ any: Any?) -> Int64? {
        if let number = any as? NSNumber { return number.int64Value }
        if let string = any as? String, let value = Int64(string) { return value }
        return nil
    }

    static func bool(_ any: Any?) -> Bool? {
        if let number = any as? NSNumber { return number.boolValue }
        if let string = any as? String { return (string as NSString).boolValue }
        return nil
    }
}

enum Clock {
    static func date(from any: Any?) -> Date? {
        if let string = JSON.string(any) {
            if let parsed = iso(string) { return parsed }
            if let number = Double(string) { return unix(number) }
        }
        if let number = JSON.double(any) { return unix(number) }
        return nil
    }

    static func unix(_ value: Double) -> Date {
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    static func iso(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum Format {
    static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 999)
        if clamped >= 10 || abs(clamped.rounded() - clamped) < 0.05 {
            return "\(Int(clamped.rounded()))%"
        }
        return String(format: "%.1f%%", clamped)
    }

    static func money(cents: Double) -> String {
        let dollars = cents / 100
        if abs(dollars.rounded() - dollars) < 0.005 {
            return String(format: "$%.0f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }

    static func count(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        let scaled: (Double, String) = {
            if magnitude >= 1_000_000_000 { return (magnitude / 1_000_000_000, "B") }
            if magnitude >= 1_000_000 { return (magnitude / 1_000_000, "M") }
            if magnitude >= 1_000 { return (magnitude / 1_000, "K") }
            return (magnitude, "")
        }()
        if scaled.1.isEmpty {
            return sign + String(format: "%.0f", scaled.0)
        }
        let digits = scaled.0 >= 100 ? 0 : 1
        return sign + String(format: "%.\(digits)f%@", scaled.0, scaled.1)
    }

    static func reset(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "just reset" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(max(minutes, 1)) min" }
        let hours = minutes / 60
        if hours < 48 { return "in \(hours) h" }
        return "in \(hours / 24) d"
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "ultra": return "Ultra"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default:
            guard let first = raw.first else { return raw }
            return first.uppercased() + raw.dropFirst()
        }
    }

    static func claudePlan(subscription: String, tier: String?) -> String {
        guard !subscription.isEmpty else { return "Claude" }
        let name = planName(subscription)
        guard subscription.lowercased() == "max", let tier else { return name }
        if tier == "default_claude_max_20x" { return "\(name) (20×)" }
        if tier == "default_claude_max_5x" { return "\(name) (5×)" }
        return name
    }

    static func modelName(_ raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let object = JSON.object(from: data),
           let id = JSON.string(JSON.value(object, key: "id")) {
            return modelName(id)
        }
        var parts = raw.split(separator: "-").map(String.init)
        let noise: Set<String> = [
            "cursor", "claude", "thinking", "xhigh", "high", "medium", "low", "fast", "max", "default",
            "free", "contributor", "flash",
        ]
        parts.removeAll { noise.contains($0) }
        var folded: [String] = []
        var index = 0
        while index < parts.count {
            let part = parts[index]
            if index + 1 < parts.count, Int(part) != nil, Int(parts[index + 1]) != nil, !part.contains(".") {
                folded.append("\(part).\(parts[index + 1])")
                index += 2
                continue
            }
            folded.append(part)
            index += 1
        }
        var titled = folded.map { piece -> String in
            if piece.first?.isNumber == true { return piece }
            return piece.prefix(1).uppercased() + piece.dropFirst()
        }
        if titled.count > 1, titled[0].first?.isNumber == true {
            let version = titled.removeFirst()
            titled.append(version)
        }
        let name = titled.joined(separator: " ")
        return name.isEmpty ? raw : name
    }
}

enum HTTP {
    struct Response: Sendable {
        var status: Int
        var data: Data
        var retryAfter: String? = nil
    }

    final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    static let blocker = RedirectBlocker()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration, delegate: blocker, delegateQueue: nil)
    }()

    static func send(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async -> (Int, Data)? {
        guard let response = await sendResponse(url, method: method, headers: headers, body: body) else { return nil }
        return (response.status, response.data)
    }

    static func sendResponse(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async -> Response? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return Response(status: http?.statusCode ?? 0, data: data, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return nil
        }
    }

    static func message(status: Int, data: Data) -> String {
        if let object = JSON.object(from: data) {
            if let error = JSON.dictionary(JSON.value(object, key: "error")),
               let message = JSON.string(JSON.value(error, key: "message")),
               !message.isEmpty {
                return message
            }
            if let message = JSON.string(JSON.value(object, key: "message")), !message.isEmpty {
                return message
            }
        }
        if status == 401 || status == 403 { return "The session expired." }
        if status == 429 { return "The service asked to wait." }
        return "Bad response (\(status))."
    }
}

enum KeychainRead: Sendable {
    case data(Data)
    case needsPermission
    case missing
    case unavailable
}

enum Keychain {
    static func password(service: String, account: String? = nil, prompt: Bool) -> KeychainRead {
        CredentialReadDeadline.shared.read(
            id: "\(service)|\(account ?? "")|\(prompt)", timeout: prompt ? 30 : 3
        ) {
            unboundedPassword(service: service, account: account, prompt: prompt)
        }
    }

    private static func unboundedPassword(service: String, account: String?, prompt: Bool) -> KeychainRead {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if !prompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, !data.isEmpty {
            return .data(data)
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            return .needsPermission
        }
        return .missing
    }

    /// Reads a generic password through `/usr/bin/security`, the same path CodexBar
    /// and OpenClaw use. That binary is already allowed to read Claude Code's item,
    /// so a background refresh does not open a password dialog.
    static func passwordViaSecurity(service: String) -> KeychainRead {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .missing
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .needsPermission
        }
        guard process.terminationStatus == 0 else { return .needsPermission }
        var data = output.fileHandleForReading.readDataToEndOfFile()
        if data.last == 0x0A { data.removeLast() }
        guard !data.isEmpty else { return .missing }
        return .data(data)
    }
}

enum SQLite {
    static func query(path: String, sql: String, binds: [Int64] = []) -> [[String: String]]? {
        var database: OpaquePointer?
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:\(escaped)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in binds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), value)
        }
        var rows: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            let columns = sqlite3_column_count(statement)
            for column in 0..<columns {
                guard let namePointer = sqlite3_column_name(statement, column) else { continue }
                let name = String(cString: namePointer)
                if let text = sqlite3_column_text(statement, column) {
                    row[name] = String(cString: text)
                } else {
                    row[name] = ""
                }
            }
            rows.append(row)
        }
        return rows
    }
}

enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func file(_ components: String...) -> URL {
        components.reduce(home) { $0.appendingPathComponent($1) }
    }
}
