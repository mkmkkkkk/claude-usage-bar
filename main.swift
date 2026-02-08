import Cocoa
import Foundation

// ============================================================
// MARK: - Keychain: Read Claude Code credentials
// ============================================================

struct Credentials {
    var accessToken: String
    var planName: String
}

func readCredentials() -> Credentials? {
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

    do { try proc.run() } catch { return nil }
    proc.waitUntilExit()

    guard proc.terminationStatus == 0 else { return nil }

    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let jsonStr = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let jsonData = jsonStr.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { return nil }

    // Parse plan name from subscriptionType
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

    return Credentials(accessToken: token, planName: plan)
}

// ============================================================
// MARK: - API: Fetch Usage
// ============================================================

struct UsageData {
    var sessionPct: Double = 0
    var sessionResetAt: Date? = nil
    var weeklyPct: Double = 0
    var weeklyResetAt: Date? = nil
    var planName: String = ""
    var error: String? = nil
}

func fetchUsage() -> UsageData {
    var result = UsageData()

    guard let creds = readCredentials() else {
        result.error = "No token"
        return result
    }

    result.planName = creds.planName

    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        result.error = "Bad URL"
        return result
    }

    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "GET"
    request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseError: Error?

    URLSession.shared.dataTask(with: request) { data, _, error in
        responseData = data
        responseError = error
        semaphore.signal()
    }.resume()

    semaphore.wait()

    if let err = responseError {
        result.error = err.localizedDescription
        return result
    }

    guard let data = responseData,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        result.error = "Parse error"
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
    var lastUsage = UsageData()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let btn = statusItem.button {
            btn.title = " C:..."
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        }

        refreshAsync()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshAsync()
        }

        // Refresh on wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc func onWake() {
        // Small delay for network to reconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshAsync()
        }
    }

    func refreshAsync(retryCount: Int = 0) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = fetchUsage()
            DispatchQueue.main.async {
                self?.lastUsage = usage
                self?.updateDisplay()

                // Auto-retry on failure (up to 3 times, every 5s)
                if usage.error != nil && retryCount < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self?.refreshAsync(retryCount: retryCount + 1)
                    }
                }
            }
        }
    }

    func updateDisplay() {
        let usage = lastUsage

        let topFrac = usage.sessionPct / 100.0
        let botFrac = usage.weeklyPct / 100.0
        let countdown = formatCountdown(to: usage.sessionResetAt)

        if let btn = statusItem.button {
            btn.image = makeBarImage(topFrac: topFrac, botFrac: botFrac)
            btn.imagePosition = .imageLeft
            btn.title = countdown.isEmpty ? "" : " \(countdown)"
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
}

        let menu = NSMenu()

        // Header with plan name
        let planLabel = usage.planName.isEmpty ? "Claude Usage" : "Claude Usage  ·  \(usage.planName)"
        let hdr = NSMenuItem(title: planLabel, action: nil, keyEquivalent: "")
        hdr.isEnabled = false
        menu.addItem(hdr)
        menu.addItem(NSMenuItem.separator())

        if let err = usage.error {
            if let btn = statusItem.button {
                btn.image = nil
                btn.title = " C:err"
            }
            let errItem = NSMenuItem(title: "Error: \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)

            if err == "No token" {
                let hint = NSMenuItem(
                    title: "Keychain access needed - relaunch & click Allow",
                    action: nil, keyEquivalent: ""
                )
                hint.isEnabled = false
                menu.addItem(hint)
            }
        } else {
            let sCountdown = formatCountdown(to: usage.sessionResetAt)
            let sPct = String(format: "%.0f%%", usage.sessionPct)
            let sItem = NSMenuItem(
                title: "Session: \(sPct) · reset \(sCountdown.isEmpty ? "-" : sCountdown)",
                action: nil, keyEquivalent: ""
            )
            sItem.isEnabled = false
            menu.addItem(sItem)

            let wCountdown = formatCountdown(to: usage.weeklyResetAt)
            let wTime = formatTime(usage.weeklyResetAt)
            let wPct = String(format: "%.0f%%", usage.weeklyPct)
            let wItem = NSMenuItem(
                title: "Weekly: \(wPct) · reset \(wCountdown.isEmpty ? "-" : wCountdown) (\(wTime))",
                action: nil, keyEquivalent: ""
            )
            wItem.isEnabled = false
            menu.addItem(wItem)
        }

        menu.addItem(NSMenuItem.separator())

        let ref = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        ref.target = self
        menu.addItem(ref)

        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc func refreshClicked() {
        statusItem.menu?.cancelTracking()
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
