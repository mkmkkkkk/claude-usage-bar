import Cocoa
import Foundation
import Network

// ============================================================
// MARK: - Logger (rotating file log)
// ============================================================

class Log {
    static let shared = Log()
    private let logURL: URL
    private let maxSize = 512 * 1024  // 500KB
    private let queue = DispatchQueue(label: "com.tensor.usage-bar.log")
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logURL = home.appendingPathComponent("Library/Logs/ClaudeUsageBar.log")
    }

    func info(_ msg: String) { write("INFO", msg) }
    func warn(_ msg: String) { write("WARN", msg) }
    func error(_ msg: String) { write("ERR ", msg) }

    private func write(_ level: String, _ msg: String) {
        let line = "[\(fmt.string(from: Date()))] \(level) \(msg)\n"
        queue.async { [self] in
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = try? FileHandle(forWritingTo: logURL) {
                    h.seekToEndOfFile()
                    h.write(data)
                    h.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int, size > maxSize else { return }
        let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
    }
}

// ============================================================
// MARK: - Keychain (cached)
// ============================================================

struct Credentials {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date?
    var planName: String

    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return Date() >= exp.addingTimeInterval(-120)  // 2 min buffer
    }
}

private var _cachedCreds: Credentials?
private var _cachedCredsAt: Date?
private let credsCacheTTL: TimeInterval = 300  // 5 min
private let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let oauthTokenURL = "https://platform.claude.com/v1/oauth/token"

func readCredentials(forceRefresh: Bool = false) -> Credentials? {
    if !forceRefresh,
       let cached = _cachedCreds,
       let at = _cachedCredsAt,
       Date().timeIntervalSince(at) < credsCacheTTL,
       !cached.isExpired {
        return cached
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = [
        "find-generic-password",
        "-s", "Claude Code-credentials",
        "-a", NSUserName(),
        "-w"
    ]

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()

    do { try proc.run() } catch {
        Log.shared.error("Keychain process launch failed")
        return nil
    }
    proc.waitUntilExit()

    guard proc.terminationStatus == 0 else {
        Log.shared.warn("Keychain lookup failed (status \(proc.terminationStatus))")
        return nil
    }

    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let jsonStr = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let jsonData = jsonStr.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { return nil }

    let refresh = oauth["refreshToken"] as? String ?? ""
    var expiresAt: Date? = nil
    if let expMs = oauth["expiresAt"] as? NSNumber {
        expiresAt = Date(timeIntervalSince1970: expMs.doubleValue / 1000.0)
    }

    let subType = oauth["subscriptionType"] as? String ?? ""
    let plan: String
    switch subType.lowercased() {
    case let s where s.contains("20x"):      plan = "Claude Max 20x"
    case let s where s.contains("5x"):       plan = "Claude Max 5x"
    case let s where s.contains("max_200"):  plan = "Claude Max $200"
    case let s where s.contains("max_100"):  plan = "Claude Max $100"
    case let s where s.contains("max"):      plan = "Claude Max"
    case let s where s.contains("pro"):      plan = "Claude Pro"
    case let s where s.contains("team"):     plan = "Claude Team"
    case let s where s.contains("enterprise"): plan = "Claude Enterprise"
    case let s where s.contains("free"):     plan = "Claude Free"
    default: plan = subType.isEmpty ? "Unknown" : subType
    }

    let creds = Credentials(accessToken: token, refreshToken: refresh, expiresAt: expiresAt, planName: plan)
    _cachedCreds = creds
    _cachedCredsAt = Date()
    Log.shared.info("Credentials loaded (\(plan), expires \(expiresAt.map { "\($0)" } ?? "unknown"))")
    return creds
}

// MARK: - OAuth Token Refresh

func refreshAccessToken(using refreshToken: String) async -> Bool {
    guard !refreshToken.isEmpty else {
        Log.shared.warn("No refresh token available")
        return false
    }

    guard let url = URL(string: oauthTokenURL) else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(oauthClientId)"
    request.httpBody = body.data(using: .utf8)

    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await apiSession.data(for: request)
    } catch {
        Log.shared.error("Token refresh network error: \(error.localizedDescription)")
        return false
    }

    guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        Log.shared.error("Token refresh failed: HTTP \(code)")
        return false
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let newAccessToken = json["access_token"] as? String
    else {
        Log.shared.error("Token refresh: bad response format")
        return false
    }

    let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
    var newExpiresAt: Double? = nil
    if let expiresIn = json["expires_in"] as? NSNumber {
        newExpiresAt = Date().timeIntervalSince1970 * 1000.0 + expiresIn.doubleValue * 1000.0
    }

    // Update Keychain
    if updateKeychainToken(accessToken: newAccessToken, refreshToken: newRefreshToken, expiresAtMs: newExpiresAt) {
        _cachedCreds = nil
        _cachedCredsAt = nil
        Log.shared.info("Token refreshed successfully")
        return true
    }

    return false
}

func updateKeychainToken(accessToken: String, refreshToken: String, expiresAtMs: Double?) -> Bool {
    // Read current Keychain data
    let readProc = Process()
    readProc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    readProc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"]
    let readPipe = Pipe()
    readProc.standardOutput = readPipe
    readProc.standardError = Pipe()
    do { try readProc.run() } catch { return false }
    readProc.waitUntilExit()
    guard readProc.terminationStatus == 0 else { return false }

    let raw = readPipe.fileHandleForReading.readDataToEndOfFile()
    guard let jsonStr = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let jsonData = jsonStr.data(using: .utf8),
          var json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          var oauth = json["claudeAiOauth"] as? [String: Any]
    else { return false }

    // Update tokens
    oauth["accessToken"] = accessToken
    oauth["refreshToken"] = refreshToken
    if let exp = expiresAtMs {
        oauth["expiresAt"] = exp
    }
    json["claudeAiOauth"] = oauth

    guard let updatedData = try? JSONSerialization.data(withJSONObject: json),
          let updatedStr = String(data: updatedData, encoding: .utf8)
    else { return false }

    // Delete old entry and add updated one
    let delProc = Process()
    delProc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    delProc.arguments = ["delete-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName()]
    delProc.standardOutput = Pipe()
    delProc.standardError = Pipe()
    do { try delProc.run() } catch { return false }
    delProc.waitUntilExit()

    let addProc = Process()
    addProc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    addProc.arguments = ["add-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w", updatedStr]
    addProc.standardOutput = Pipe()
    addProc.standardError = Pipe()
    do { try addProc.run() } catch { return false }
    addProc.waitUntilExit()

    return addProc.terminationStatus == 0
}

// ============================================================
// MARK: - API (async/await)
// ============================================================

struct UsageData: Equatable {
    var sessionPct: Double = 0
    var sessionResetAt: Date? = nil
    var weeklyPct: Double = 0
    var weeklyResetAt: Date? = nil
    var planName: String = ""
    var error: String? = nil
    var errorKind: ErrorKind = .none

    static func == (lhs: UsageData, rhs: UsageData) -> Bool {
        lhs.sessionPct == rhs.sessionPct &&
        lhs.weeklyPct == rhs.weeklyPct &&
        lhs.sessionResetAt == rhs.sessionResetAt &&
        lhs.weeklyResetAt == rhs.weeklyResetAt &&
        lhs.planName == rhs.planName &&
        lhs.error == rhs.error
    }
}

enum ErrorKind: Equatable {
    case none
    case noToken
    case networkOffline
    case networkTimeout
    case httpError(Int)
    case parseError
    case unknown

    var isTransient: Bool {
        switch self {
        case .networkOffline, .networkTimeout, .unknown:
            return true
        case .httpError(let code):
            return code == 429 || (500...599).contains(code)
        default:
            return false
        }
    }
}

private let apiSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 30
    config.waitsForConnectivity = false
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
}()

func fetchUsage() async -> UsageData {
    return await fetchUsageInner(allowRefresh: true)
}

private func fetchUsageInner(allowRefresh: Bool) async -> UsageData {
    var result = UsageData()

    guard var creds = readCredentials() else {
        result.error = "No token"
        result.errorKind = .noToken
        return result
    }

    // Proactively refresh if token is expired/expiring
    if creds.isExpired && allowRefresh {
        Log.shared.info("Token expired/expiring, refreshing proactively...")
        if await refreshAccessToken(using: creds.refreshToken) {
            if let newCreds = readCredentials(forceRefresh: true) {
                creds = newCreds
            }
        }
    }

    result.planName = creds.planName

    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        result.error = "Bad URL"
        result.errorKind = .unknown
        return result
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("claude-code/2.1.38", forHTTPHeaderField: "User-Agent")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await apiSession.data(for: request)
    } catch {
        let nsErr = error as NSError
        switch nsErr.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            result.error = "Offline"
            result.errorKind = .networkOffline
        case NSURLErrorTimedOut:
            result.error = "Timeout"
            result.errorKind = .networkTimeout
        case NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            result.error = "DNS/Host"
            result.errorKind = .networkOffline
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected:
            result.error = "TLS error"
            result.errorKind = .networkTimeout
        default:
            result.error = error.localizedDescription
            result.errorKind = .unknown
        }
        Log.shared.error("Fetch failed: \(result.error ?? "?")")
        return result
    }

    if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
        let code = httpResp.statusCode

        // On 401, try to refresh token and retry once
        if code == 401 && allowRefresh {
            Log.shared.info("Got 401, attempting token refresh...")
            if await refreshAccessToken(using: creds.refreshToken) {
                return await fetchUsageInner(allowRefresh: false)
            }
        }

        switch code {
        case 401:
            result.error = "Auth expired"
            result.errorKind = .httpError(401)
        case 429:
            result.error = "Rate limited"
            result.errorKind = .httpError(429)
        case 500...599:
            result.error = "Server \(code)"
            result.errorKind = .httpError(code)
        default:
            result.error = "HTTP \(code)"
            result.errorKind = .httpError(code)
        }
        Log.shared.error("HTTP \(code)")
        return result
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        result.error = "Parse error"
        result.errorKind = .parseError
        return result
    }

    let fmtFrac = ISO8601DateFormatter()
    fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fmtPlain = ISO8601DateFormatter()
    fmtPlain.formatOptions = [.withInternetDateTime]

    func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return fmtFrac.date(from: s) ?? fmtPlain.date(from: s)
    }

    func parseUtil(_ val: Any?) -> Double {
        if let n = val as? NSNumber { return n.doubleValue }
        if let s = val as? String {
            return Double(s.replacingOccurrences(of: "%", with: "")) ?? 0
        }
        return 0
    }

    if let fiveHour = json["five_hour"] as? [String: Any] {
        result.sessionPct = parseUtil(fiveHour["utilization"])
        result.sessionResetAt = parseDate(fiveHour["resets_at"] as? String)
    }

    if let sevenDay = json["seven_day"] as? [String: Any] {
        result.weeklyPct = parseUtil(sevenDay["utilization"])
        result.weeklyResetAt = parseDate(sevenDay["resets_at"] as? String)
    }

    return result
}

// ============================================================
// MARK: - Sparkline History
// ============================================================

struct UsagePoint: Codable {
    let date: Date
    let sessionPct: Double
}

class UsageHistory {
    static let maxAge: TimeInterval = 5 * 3600  // 5h
    private(set) var points: [UsagePoint] = []
    private let fileURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Application Support/ClaudeUsageBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func record(_ usage: UsageData) {
        let pt = UsagePoint(date: Date(), sessionPct: usage.sessionPct)
        points.append(pt)
        prune()
        save()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        points.removeAll { $0.date < cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              var loaded = try? JSONDecoder().decode([UsagePoint].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        loaded.removeAll { $0.date < cutoff }
        points = loaded
        Log.shared.info("Loaded \(points.count) history points from disk")
    }
}

class SparklineView: NSView {
    var points: [UsagePoint] = []

    override var intrinsicContentSize: NSSize {
        NSSize(width: 230, height: 60)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let margin: CGFloat = 10
        let topPad: CGFloat = 14
        let botPad: CGFloat = 16
        let chartRect = NSRect(
            x: margin, y: botPad,
            width: bounds.width - margin * 2,
            height: bounds.height - topPad - botPad
        )

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        "Session Rate (5h)".draw(at: NSPoint(x: margin, y: bounds.height - topPad + 2), withAttributes: titleAttrs)

        guard points.count >= 3 else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let text = "Collecting data..."
            let size = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (chartRect.midY - size.height / 2)),
                withAttributes: attrs
            )
            return
        }

        // Compute rate: %/min between consecutive points, then smooth with 5min rolling average
        var rawRates: [Double] = []
        for i in 1..<points.count {
            let dt = points[i].date.timeIntervalSince(points[i-1].date)
            guard dt > 0 else { rawRates.append(0); continue }
            let delta = max(points[i].sessionPct - points[i-1].sessionPct, 0)
            rawRates.append(delta / (dt / 60.0))  // %/min
        }

        // Rolling average (window = 40 points ≈ 20min at 30s intervals)
        let window = 40
        var rates: [Double] = []
        for i in 0..<rawRates.count {
            let lo = max(0, i - window / 2)
            let hi = min(rawRates.count - 1, i + window / 2)
            let slice = rawRates[lo...hi]
            rates.append(slice.reduce(0, +) / Double(slice.count))
        }

        let maxRate = max(rates.max() ?? 1, 0.5)  // floor at 0.5%/min for scale

        // Grid line at 50% of max
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.3)
        let midY = chartRect.minY + chartRect.height * 0.5
        let gridLine = NSBezierPath()
        gridLine.move(to: NSPoint(x: chartRect.minX, y: midY))
        gridLine.line(to: NSPoint(x: chartRect.maxX, y: midY))
        gridLine.lineWidth = 0.5
        gridColor.setStroke()
        gridLine.stroke()

        // Draw rate sparkline (normalized to maxRate)
        let normalized = rates.map { $0 / maxRate * 100.0 }
        drawLine(normalized, in: chartRect,
                 color: NSColor.systemBlue, label: "", labelX: chartRect.maxX + 2)

        // Time labels
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let elapsed = points.last!.date.timeIntervalSince(points.first!.date)
        let agoLabel: String
        if elapsed >= 3600 {
            agoLabel = String(format: "%.0fh ago", elapsed / 3600)
        } else {
            agoLabel = String(format: "%.0fm ago", elapsed / 60)
        }
        agoLabel.draw(at: NSPoint(x: margin, y: 2), withAttributes: timeAttrs)

        let nowSize = "now".size(withAttributes: timeAttrs)
        "now".draw(at: NSPoint(x: chartRect.maxX - nowSize.width, y: 2), withAttributes: timeAttrs)
    }

    private func drawLine(_ values: [Double], in rect: NSRect, color: NSColor,
                          label: String, labelX: CGFloat) {
        guard values.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let step = rect.width / CGFloat(values.count - 1)

        for (i, val) in values.enumerated() {
            let x = rect.minX + CGFloat(i) * step
            let y = rect.minY + rect.height * CGFloat(min(val, 100.0) / 100.0)
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)) }
        }

        color.setStroke()
        path.stroke()

        // Fill under curve
        let fillPath = path.copy() as! NSBezierPath
        fillPath.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        fillPath.line(to: NSPoint(x: rect.minX, y: rect.minY))
        fillPath.close()
        color.withAlphaComponent(0.08).setFill()
        fillPath.fill()
    }
}

// ============================================================
// MARK: - Drawing: two thin bars as NSImage
// ============================================================

func makeBarImage(topFrac: Double, botFrac: Double) -> NSImage {
    let w: CGFloat = 28
    let h: CGFloat = 18
    let barH: CGFloat = 3.5
    let gap: CGFloat = 2.5
    let totalBarsH = barH * 2 + gap
    let startY = (h - totalBarsH) / 2

    let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fgColor = isDark ? NSColor.white : NSColor.black
        let bgColor = fgColor.withAlphaComponent(0.18)

        // Bottom bar (weekly)
        let botY = startY
        let botBg = NSRect(x: 0, y: botY, width: w, height: barH)
        NSBezierPath(roundedRect: botBg, xRadius: 1.5, yRadius: 1.5).fill(using: bgColor)
        let botFw = w * CGFloat(min(max(botFrac, 0), 1.0))
        if botFw > 0.5 {
            let botFill = NSRect(x: 0, y: botY, width: botFw, height: barH)
            NSBezierPath(roundedRect: botFill, xRadius: 1.5, yRadius: 1.5)
                .fill(using: fgColor.withAlphaComponent(0.55))
        }

        // Top bar (session)
        let topY = botY + barH + gap
        let topBg = NSRect(x: 0, y: topY, width: w, height: barH)
        NSBezierPath(roundedRect: topBg, xRadius: 1.5, yRadius: 1.5).fill(using: bgColor)
        let topFw = w * CGFloat(min(max(topFrac, 0), 1.0))
        if topFw > 0.5 {
            let topFill = NSRect(x: 0, y: topY, width: topFw, height: barH)
            NSBezierPath(roundedRect: topFill, xRadius: 1.5, yRadius: 1.5)
                .fill(using: fgColor.withAlphaComponent(0.75))
        }

        return true
    }

    image.isTemplate = false
    return image
}

extension NSBezierPath {
    func fill(using color: NSColor) {
        color.setFill()
        self.fill()
    }
}

// ============================================================
// MARK: - Helpers
// ============================================================

func formatCountdown(to resetDate: Date?) -> String {
    guard let resetDate = resetDate else { return "" }
    let remaining = resetDate.timeIntervalSince(Date())
    if remaining <= 0 { return "now" }

    let totalMin = Int(ceil(remaining / 60))
    let hrs = totalMin / 60
    let mins = totalMin % 60
    let days = hrs / 24
    let remHrs = hrs % 24

    if days > 0 {
        return "\(days)d\(String(format: "%02d", remHrs))h"
    }
    if hrs > 0 {
        return "\(hrs)h\(String(format: "%02d", mins))m"
    }
    return "\(mins)m"
}

func formatTime(_ date: Date?) -> String {
    guard let date = date else { return "-" }
    let fmt = DateFormatter()
    fmt.dateFormat = "M/d h:mm a"
    fmt.timeZone = .current
    return fmt.string(from: date)
}

// ============================================================
// MARK: - App Delegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var watchdogTimer: Timer?
    var lastUsage = UsageData()
    var lastSuccessfulUsage: UsageData?
    var lastSuccessfulFetch: Date?
    var consecutiveFailures = 0
    var networkMonitor: NWPathMonitor?
    private var _isNetworkAvailable = true
    var isNetworkAvailable: Bool { _isNetworkAvailable }
    var isRefreshing = false
    var pendingRetryWork: DispatchWorkItem?

    // Sparkline
    let usageHistory = UsageHistory()
    var sparklineView: SparklineView!

    // Persistent menu items (differential update)
    var headerItem: NSMenuItem!
    var sessionItem: NSMenuItem!
    var weeklyItem: NSMenuItem!
    var staleNoteItem: NSMenuItem!
    var errorItem: NSMenuItem!
    var hintItem: NSMenuItem!
    var sparklineSepItem: NSMenuItem!
    var sparklineItem: NSMenuItem!

    static let backoffDelays: [TimeInterval] = [5, 15, 30, 60, 120]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.info("App launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = " C:..."
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        }

        buildMenu()
        startNetworkMonitor()
        refreshAsync()
        startRefreshTimer()

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.ensureTimerAlive()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    // MARK: - Menu (built once, updated differentially)

    func buildMenu() {
        let menu = NSMenu()

        headerItem = NSMenuItem(title: "Claude Usage", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        sessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sessionItem.isEnabled = false
        menu.addItem(sessionItem)

        weeklyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        weeklyItem.isEnabled = false
        menu.addItem(weeklyItem)

        staleNoteItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        staleNoteItem.isEnabled = false
        staleNoteItem.isHidden = true
        menu.addItem(staleNoteItem)

        errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)

        hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        hintItem.isHidden = true
        menu.addItem(hintItem)

        sparklineSepItem = NSMenuItem.separator()
        menu.addItem(sparklineSepItem)

        sparklineView = SparklineView(frame: NSRect(x: 0, y: 0, width: 230, height: 60))
        sparklineItem = NSMenuItem()
        sparklineItem.view = sparklineView
        menu.addItem(sparklineItem)

        menu.addItem(NSMenuItem.separator())

        let ref = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        ref.target = self
        menu.addItem(ref)

        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Network Monitoring

    func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let wasOffline = !self._isNetworkAvailable
                self._isNetworkAvailable = (path.status == .satisfied)

                if wasOffline && path.status == .satisfied {
                    Log.shared.info("Network restored")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.consecutiveFailures = 0
                        self?.refreshAsync()
                    }
                } else if !wasOffline && path.status != .satisfied {
                    Log.shared.warn("Network lost")
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        networkMonitor = monitor
    }

    // MARK: - Timer management

    func startRefreshTimer() {
        timer?.invalidate()
        // Align to next :00 or :30 second mark so countdown syncs with system clock
        let now = Date()
        let sec = Calendar.current.component(.second, from: now)
        let secsToNext = sec < 30 ? (30 - sec) : (60 - sec)
        let firstFire = now.addingTimeInterval(Double(secsToNext))
        timer = Timer(fire: firstFire, interval: 30, repeats: true) { [weak self] _ in
            self?.refreshAsync()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func ensureTimerAlive() {
        if timer == nil || !(timer?.isValid ?? false) {
            Log.shared.warn("Timer was dead, restarting")
            startRefreshTimer()
        }
    }

    @objc func onWake() {
        Log.shared.info("Wake from sleep")
        _cachedCredsAt = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.consecutiveFailures = 0
            self?.refreshAsync()
        }
    }

    // MARK: - Fetch (async/await)

    func refreshAsync() {
        guard !isRefreshing else { return }
        isRefreshing = true
        pendingRetryWork?.cancel()
        pendingRetryWork = nil

        Task {
            let usage = await fetchUsage()

            // Back to main thread for UI
            await MainActor.run {
                self.isRefreshing = false
                self.lastUsage = usage

                if usage.error != nil {
                    self.consecutiveFailures += 1
                    if case .httpError(401) = usage.errorKind {
                        _cachedCredsAt = nil
                    }
                    self.scheduleRetry()
                } else {
                    if self.consecutiveFailures > 0 {
                        Log.shared.info("Recovered after \(self.consecutiveFailures) failures")
                    }
                    self.consecutiveFailures = 0
                    self.lastSuccessfulUsage = usage
                    self.lastSuccessfulFetch = Date()
                    self.usageHistory.record(usage)
                    Log.shared.info("S:\(String(format: "%.0f", usage.sessionPct))% W:\(String(format: "%.0f", usage.weeklyPct))%")
                }

                self.updateDisplay()
            }
        }
    }

    func scheduleRetry() {
        if case .noToken = lastUsage.errorKind { return }
        if case .httpError(401) = lastUsage.errorKind { return }
        if !isNetworkAvailable { return }

        let idx = min(consecutiveFailures - 1, Self.backoffDelays.count - 1)
        let delay = Self.backoffDelays[max(idx, 0)]
        Log.shared.info("Retry #\(consecutiveFailures) in \(Int(delay))s")

        let work = DispatchWorkItem { [weak self] in
            self?.refreshAsync()
        }
        pendingRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - UI (differential update)

    func updateDisplay() {
        let usage = lastUsage
        let hasError = usage.error != nil

        // Always show last successful data during any error (not just transient)
        let displayUsage: UsageData
        if hasError, let stale = lastSuccessfulUsage {
            displayUsage = stale
        } else {
            displayUsage = usage
        }

        let topFrac = displayUsage.sessionPct / 100.0
        let botFrac = displayUsage.weeklyPct / 100.0
        let countdown = formatCountdown(to: displayUsage.sessionResetAt)

        // -- Status bar button --
        if let btn = statusItem.button {
            if hasError && lastSuccessfulFetch == nil {
                // Error with no prior data at all
                btn.image = nil
                btn.title = " C:\(usage.error!)"
            } else {
                // Normal or stale — bars + countdown, tiny dot if error
                btn.image = makeBarImage(topFrac: topFrac, botFrac: botFrac)
                btn.imagePosition = .imageLeft
                let suffix = hasError ? "·" : ""
                btn.title = countdown.isEmpty ? suffix : " \(countdown)\(suffix)"
            }
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        }

        // -- Menu items (update titles, toggle visibility) --
        let planName = displayUsage.planName.isEmpty ? usage.planName : displayUsage.planName
        headerItem.title = planName.isEmpty ? "Claude Usage" : "Claude Usage  ·  \(planName)"

        // Session & Weekly
        let showUsageRows = !hasError || lastSuccessfulFetch != nil

        if showUsageRows {
            sessionItem.isHidden = false
            weeklyItem.isHidden = false

            let sCountdown = formatCountdown(to: displayUsage.sessionResetAt)
            let sPct = String(format: "%.0f%%", displayUsage.sessionPct)
            sessionItem.title = "Session: \(sPct) · reset \(sCountdown.isEmpty ? "-" : sCountdown)"

            let wCountdown = formatCountdown(to: displayUsage.weeklyResetAt)
            let wTime = formatTime(displayUsage.weeklyResetAt)
            let wPct = String(format: "%.0f%%", displayUsage.weeklyPct)
            weeklyItem.title = "Weekly: \(wPct) · reset \(wCountdown.isEmpty ? "-" : wCountdown) (\(wTime))"
        } else {
            sessionItem.isHidden = true
            weeklyItem.isHidden = true
        }

        // Stale note
        if hasError && lastSuccessfulFetch != nil {
            staleNoteItem.isHidden = false
            staleNoteItem.title = "Last updated: \(formatTime(lastSuccessfulFetch))"
        } else {
            staleNoteItem.isHidden = true
        }

        // Error + hint
        if let err = usage.error {
            errorItem.isHidden = false
            errorItem.title = "Error: \(err)"

            hintItem.isHidden = false
            switch usage.errorKind {
            case .noToken:
                hintItem.title = "Keychain access needed - relaunch & click Allow"
            case .httpError(401):
                hintItem.title = "Token expired - re-login to claude.ai"
            case .httpError(429):
                hintItem.title = "Rate limited - will retry automatically"
            case .networkOffline:
                hintItem.title = "No internet - will refresh when online"
            case .networkTimeout:
                hintItem.title = "Request timed out - retrying..."
            default:
                if consecutiveFailures > 0 {
                    hintItem.title = "Retrying... (\(consecutiveFailures) failures)"
                } else {
                    hintItem.isHidden = true
                }
            }
        } else {
            errorItem.isHidden = true
            hintItem.isHidden = true
        }

        // Sparkline
        sparklineView.points = usageHistory.points
        sparklineView.needsDisplay = true
    }

    @objc func refreshClicked() {
        statusItem.menu?.cancelTracking()
        consecutiveFailures = 0
        refreshAsync()
    }

    @objc func quitClicked() { NSApplication.shared.terminate(nil) }
}

// ============================================================
// MARK: - Main
// ============================================================

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
