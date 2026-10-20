// UsageBar — a macOS menu-bar tracker for Claude (Max/Pro) and ChatGPT (Plus/Pro, via Codex)
// subscription limits. One Swift file, no dependencies.
//
// Build: ./build.sh      Install + start at login: ./install.sh      Remove: ./uninstall.sh
// Self-test (prints the numbers, no UI): build/UsageBar.app/Contents/MacOS/UsageBar --once
//
// Data sources:
//   Claude   1) The Claude Code CLI's sign-in (macOS Keychain item "Claude Code-credentials") -> GET
//               api.anthropic.com/api/oauth/usage: exact numbers, reset times, per-model weekly windows.
//               Near expiry, UsageBar initializes the CLI protocol without sending a model prompt.
//               The CLI renews its own sign-in. UsageBar never writes the token — see README.
//            2) Fallback, no credentials needed: the Claude desktop app's own usage samples in
//               ~/Library/Application Support/Claude/plan-usage-history.json. Reset time is estimated.
//   ChatGPT  ~/.codex/auth.json (the Codex sign-in, read-only, never rewritten) -> GET
//               chatgpt.com/backend-api/wham/usage. These are the Codex limits included in the ChatGPT plan.
//               Codex keeps that token fresh itself.

import AppKit
import Foundation
import UserNotifications

// MARK: - Configuration

enum Config {
    static let pollInterval: TimeInterval = 3 * 60      // background refresh cadence
    static let staleAfter: TimeInterval = 60            // refresh when the menu opens if data is older than this
    static let staleData: TimeInterval = 30 * 60        // grey out the menu-bar figure when data is older than this
    static let warnAt: Double = 70                      // orange
    static let alertAt: Double = 90                     // red, plus "!" in the menu bar
    static let notifyAt: [Double] = [80, 95]            // macOS notification thresholds (once per window cycle)

    static let claudeGlyph = "✱"
    static let gptGlyph = "⬡"

    static let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let claudeResetURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static let claudeTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let claudeCLIService = "Claude Code-credentials"   // read-only
    /// Off: tried this (renew ahead of expiry, write back into the CLI's own Keychain item). The renewal call
    /// itself (POST grant_type=refresh_token to Config.claudeTokenURL) got a persistent 429 rate_limit_error
    /// in testing — unchanged across 80+ minutes and several approaches — while the real `claude` binary's own
    /// internal refresh worked fine in the same window. Never confirmed working for a non-CLI caller; see
    /// README ("About the Claude sign-in") before re-enabling.
    static let claudeSelfRefresh = false
    static let claudeUserAgentFallback = "claude-cli/2.1.291 (external, cli)"
    static let claudeAppHistory = ("~/Library/Application Support/Claude/plan-usage-history.json" as NSString).expandingTildeInPath
    static let claudeUsagePage = URL(string: "https://claude.ai/settings/usage")!

    static let codexAuthPath = ("~/.codex/auth.json" as NSString).expandingTildeInPath
    static let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let codexResetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let codexUserAgent = "codex_cli_rs"

    static let logDir = ("~/Library/Application Support/UsageBar" as NSString).expandingTildeInPath
}

// MARK: - Model

struct UsageWindow {
    let label: String        // "5-hour", "Weekly", "Weekly · Opus", ...
    let percent: Double      // 0–100
    let resetsAt: Date?
    let approx: Bool         // reset time is estimated, not reported
}

struct ProviderUsage {
    let name: String
    var plan: String
    var windows: [UsageWindow] = []
    var extras: [String] = []       // additional info lines
    var source: String = ""         // "API" or "Claude app"
    var dataAt: Date = Date()       // when the numbers were produced
    var error: String? = nil        // shown when no windows are available
    var note: String? = nil         // secondary hint shown under the numbers
    var lastKnown = false           // numbers are carried over from an earlier successful fetch
    var headline: Double? { (windows.first { $0.label == "Weekly" } ?? windows.first)?.percent }   // menu-bar figure
    var worst: Double { windows.map(\.percent).max() ?? 0 }
    var structure: String { windows.map(\.label).joined(separator: "|") + "#\(extras.count)#\(error != nil)#\(note != nil)#\(lastKnown)" }
}

// MARK: - Small helpers

func log(_ s: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8))
}

func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

/// Both source files are rewritten in place by their owners, so a torn read is retried once before giving up.
func readJSONFile(_ path: String) -> [String: Any]? {
    for attempt in 0..<2 {
        if let d = FileManager.default.contents(atPath: path), let j = json(d) { return j }
        if attempt == 0 { usleep(250_000) }
    }
    return nil
}

func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
}

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

func ago(_ d: Date) -> String {
    let s = Date().timeIntervalSince(d)
    if s < 90 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86400 { return "\(Int(s / 3600)) h ago" }
    return "\(Int(s / 86400)) d ago"
}

func resetText(_ w: UsageWindow) -> String {
    guard let r = w.resetsAt else { return w.approx ? "reset time n/a" : "" }
    let secs = r.timeIntervalSinceNow
    let prefix = w.approx ? "resets ≈ " : "resets "
    if secs <= 0 { return "resetting…" }
    if secs < 24 * 3600 {
        let h = Int(secs / 3600), m = Int(secs.truncatingRemainder(dividingBy: 3600) / 60)
        return prefix + "in " + (h > 0 ? "\(h)h \(m)m" : "\(m)m")
    }
    let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
    return prefix + f.string(from: r)
}

/// Thresholds are applied to the rounded figure so the colour always agrees with the displayed percentage.
func color(for percent: Double) -> NSColor {
    percent.rounded() >= Config.alertAt ? .systemRed : percent.rounded() >= Config.warnAt ? .systemOrange : .systemGreen
}

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }
    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return Result(status: -1, out: "", err: "\(error)") }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: String(decoding: od, as: UTF8.self), err: String(decoding: ed, as: UTF8.self))
    }
}

enum HTTP {
    struct Response { let status: Int; let data: Data; let headers: [String: String] }
    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) -> Result<Response, Error> {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = body
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Response, Error> = .failure(NSError(domain: "UsageBar", code: -1, userInfo: [NSLocalizedDescriptionKey: "no response"]))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { result = .failure(err) }
            else {
                let http = resp as? HTTPURLResponse
                var hdrs: [String: String] = [:]
                http?.allHeaderFields.forEach { if let k = $0.key as? String, let v = $0.value as? String { hdrs[k.lowercased()] = v } }
                result = .success(Response(status: http?.statusCode ?? 0, data: data ?? Data(), headers: hdrs))
            }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}

// MARK: - Claude

enum Claude {
    struct Creds {
        var raw: [String: Any]
        var oauth: [String: Any] { raw["claudeAiOauth"] as? [String: Any] ?? [:] }
        var accessToken: String? { oauth["accessToken"] as? String }
        var refreshToken: String? { oauth["refreshToken"] as? String }
        var expiresAt: Date? { num(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } }
        var refreshExpiresAt: Date? { num(oauth["refreshTokenExpiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } }
        var tier: String { oauth["rateLimitTier"] as? String ?? "" }
        var subscription: String { oauth["subscriptionType"] as? String ?? "" }
        var scopes: [String] { oauth["scopes"] as? [String] ?? [] }
    }

    static var blockedUntil: Date = .distantPast       // after a 429
    static var lastRefreshFailure: Date = .distantPast
    static var refreshed: Creds?                        // self-refresh only: in-memory copy in case the Keychain write fails
    static var lastCLIRenewal: Date = .distantPast
    static var lastResetCheck: Date = .distantPast
    static var resetGrants: [String: Any]?
    static var resetGrantsToken: String?               // memory only; discard cached grants when the login changes
    static let signInHint = "exact reset times need a signed-in `claude` CLI — see README"

    static let cliPath = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", ("~/.local/bin/claude" as NSString).expandingTildeInPath]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// The API rate-limits generic clients harshly; identify as the CLI whose credential this is.
    static let userAgent: String = {
        if let path = cliPath, let v = Shell.run(path, ["--version"]).out.split(whereSeparator: { $0 == " " || $0 == "\n" }).first,
           v.filter({ $0 == "." }).count == 2 {
            return "claude-cli/\(v) (external, cli)"
        }
        return Config.claudeUserAgentFallback
    }()

    static func planLabel(_ c: Creds?) -> String {
        guard let c = c else { return "" }
        if c.tier.contains("max_20x") { return "Max 20x" }
        if c.tier.contains("max_5x") { return "Max 5x" }
        if !c.subscription.isEmpty { return c.subscription.prefix(1).uppercased() + c.subscription.dropFirst() }
        return ""
    }

    static func readKeychain(_ service: String) -> Creds? {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard r.status == 0,
              let d = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let j = json(d), j["claudeAiOauth"] != nil else { return nil }
        return Creds(raw: j)
    }

    /// Writes the renewed pair back into the CLI's own Keychain item — the one shared copy — so `claude` and
    /// UsageBar are always looking at the same sign-in instead of two that can drift apart.
    static func writeSharedKeychain(_ c: Creds) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": c.oauth]), let s = String(data: d, encoding: .utf8) else { return false }
        return Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-s", Config.claudeCLIService, "-a", NSUserName(), "-w", s]).status == 0
    }

    /// The newest sign-in wins: the shared Keychain item, or the in-memory copy if a just-written Keychain
    /// update hasn't round-tripped back through a read yet.
    static func loadCreds() -> Creds? {
        [readKeychain(Config.claudeCLIService), refreshed].compactMap { $0 }.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    static func refresh(_ c: Creds) -> Creds? {
        guard Config.claudeSelfRefresh, let rt = c.refreshToken, Date().timeIntervalSince(lastRefreshFailure) > 30 * 60 else { return nil }
        if let re = c.refreshExpiresAt, re < Date() { return nil }
        let body = try? JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "refresh_token": rt,
                                                                 "client_id": Config.claudeClientID, "scope": c.scopes.joined(separator: " ")])
        guard case .success(let resp) = HTTP.request(Config.claudeTokenURL, method: "POST", headers: ["Content-Type": "application/json", "Accept": "application/json"], body: body),
              resp.status == 200, let j = json(resp.data), let at = j["access_token"] as? String else {
            lastRefreshFailure = Date(); return nil
        }
        var oauth = c.oauth
        oauth["accessToken"] = at
        if let nrt = j["refresh_token"] as? String { oauth["refreshToken"] = nrt }
        if let exp = num(j["expires_in"]) { oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + exp) * 1000) }
        if let rexp = num(j["refresh_token_expires_in"]) { oauth["refreshTokenExpiresAt"] = Int((Date().timeIntervalSince1970 + rexp) * 1000) }
        return Creds(raw: ["claudeAiOauth": oauth])
    }

    /// Exact numbers via the API. Returns nil when there is no stored sign-in at all.
    static func fromAPI(_ stored: Creds?) -> ProviderUsage? {
        guard var creds = stored, creds.accessToken != nil else { return nil }
        var u = ProviderUsage(name: "Claude", plan: planLabel(creds))
        if Date() < blockedUntil { u.error = "Claude API is rate-limiting; retrying later"; return u }
        if (creds.expiresAt ?? .distantPast) <= Date() {
            guard let fresh = refresh(creds) else { u.error = signInHint; return u }
            creds = fresh
            refreshed = fresh
            if !writeSharedKeychain(fresh) { log("could not store the renewed Claude sign-in in the Keychain; keeping it in memory") }
        }
        guard let token = creds.accessToken else { return nil }
        let r = HTTP.request(Config.claudeUsageURL, headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20",
                                                              "Accept": "application/json", "User-Agent": userAgent])
        switch r {
        case .failure(let e):
            u.error = "Claude: \(e.localizedDescription)"
        case .success(let resp):
            guard resp.status == 200, let j = json(resp.data) else {
                switch resp.status {
                case 401: u.error = signInHint
                case 403: u.error = "Claude sign-in lacks the usage permission — run `claude auth login` again"
                case 429:
                    let retry = num(resp.headers["retry-after"]) ?? 0
                    blockedUntil = Date().addingTimeInterval(max(retry, 10 * 60))
                    u.error = "Claude API is rate-limiting; retrying later"
                default: u.error = "Claude API error \(resp.status)"
                }
                log("claude api: \(u.error ?? "")")
                return u
            }
            for (key, label) in [("five_hour", "5-hour"), ("seven_day", "Weekly")] {
                guard let w = j[key] as? [String: Any], let p = num(w["utilization"]) else { continue }
                let reset = parseISO(w["resets_at"] as? String)
                u.windows.append(UsageWindow(label: label, percent: p, resetsAt: reset, approx: false))
            }
            var scoped: [UsageWindow] = []   // per-model weekly windows, newer shape first
            for entry in (j["limits"] as? [[String: Any]]) ?? [] {
                guard (entry["kind"] as? String) == "weekly_scoped", (entry["is_active"] as? Bool) != false, let p = num(entry["percent"]) else { continue }
                let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String ?? "model"
                scoped.append(UsageWindow(label: "Weekly · \(model)", percent: p, resetsAt: parseISO(entry["resets_at"] as? String), approx: false))
            }
            if scoped.isEmpty {
                for (key, label) in [("seven_day_opus", "Weekly · Opus"), ("seven_day_sonnet", "Weekly · Sonnet")] {
                    guard let w = j[key] as? [String: Any], let p = num(w["utilization"]) else { continue }
                    scoped.append(UsageWindow(label: label, percent: p, resetsAt: parseISO(w["resets_at"] as? String), approx: false))
                }
            }
            u.windows += scoped
            if let x = j["extra_usage"] as? [String: Any], (x["is_enabled"] as? Bool) == true {
                if let used = num(x["used_credits"]), let limit = num(x["monthly_limit"]), limit > 0 {
                    u.extras.append(String(format: "Extra usage: $%.2f of $%.0f this month", used / 100, limit / 100))
                } else if let p = num(x["utilization"]) { u.extras.append("Extra usage: \(pct(p)) of monthly cap") }
            }
            if u.windows.isEmpty { u.error = "Claude API returned no usage windows" }
            if !u.windows.isEmpty { u.extras.append(resetAvailability(token: token)) }
            u.source = "API"
        }
        return u
    }

    /// Grant checks are separate from ordinary usage and limited to hourly: this variant is rate-limited
    /// more heavily. It only reads availability; UsageBar never redeems a reset.
    static func resetAvailability(token: String) -> String {
        if resetGrantsToken != token || Date().timeIntervalSince(lastResetCheck) >= 3600 {
            lastResetCheck = Date()
            resetGrantsToken = token
            resetGrants = nil
            if case .success(let response) = HTTP.request(Config.claudeResetURL, headers: [
                "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json", "User-Agent": userAgent
            ]), response.status == 200 {
                resetGrants = json(response.data)?["cedar_ember"] as? [String: Any]
            } else {
                log("claude reset availability unavailable; retrying in an hour")
            }
        }
        return resetGrantSummary(resetGrants)
    }

    static func resetGrantSummary(_ block: [String: Any]?, now: Date = Date()) -> String {
        guard let block = block, let grants = block["grants"] as? [[String: Any]],
              (block["eligible"] as? Bool) == true else {
            return "Reset availability unavailable — check Claude usage page"
        }
        let available = grants.filter {
            guard let count = num($0["resets_left"]), count > 0 else { return false }
            if let start = parseISO($0["starts_at"] as? String), start > now { return false }
            if let end = parseISO($0["ends_at"] as? String), end <= now { return false }
            return true
        }
        let count = available.reduce(0) { $0 + Int(num($1["resets_left"]) ?? 0) }
        guard count > 0 else { return "No usage-limit resets available" }
        var text = "\(count) usage-limit reset\(count == 1 ? "" : "s") available"
        if let end = available.compactMap({ parseISO($0["ends_at"] as? String) }).min() {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM HH:mm"
            text += " · \(count == 1 ? "expires" : "next expiry") \(formatter.string(from: end))"
        }
        if available.allSatisfy({ ($0["paused"] as? Bool) == true || ($0["usable_now"] as? Bool) == false }) {
            text += " · not usable yet"
        }
        return text
    }

    /// Fallback: the Claude desktop app's own usage samples (fh = five-hour %, sd = seven-day %, xu = extra usage).
    static func fromApp(plan: String) -> ProviderUsage? {
        guard let j = readJSONFile(Config.claudeAppHistory),
              let samples = j["samples"] as? [[String: Any]], let last = samples.last,
              let t = num(last["t"]), let usage = last["u"] as? [String: Any] else { return nil }
        var u = ProviderUsage(name: "Claude", plan: plan)
        u.dataAt = Date(timeIntervalSince1970: t / 1000)
        if let fh = num(usage["fh"]) { u.windows.append(UsageWindow(label: "5-hour", percent: fh, resetsAt: estimateFiveHourReset(samples), approx: true)) }
        if let sd = num(usage["sd"]) { u.windows.append(UsageWindow(label: "Weekly", percent: sd, resetsAt: nil, approx: true)) }
        guard !u.windows.isEmpty else { return nil }
        if let xu = num(usage["xu"]), xu > 0 { u.extras.append("Extra usage: \(pct(xu)) of monthly cap") }
        u.source = "Claude app"
        return u
    }

    /// The 5-hour window starts at the first message after a reset: find the latest 0 -> >0 transition in the samples.
    static func estimateFiveHourReset(_ samples: [[String: Any]]) -> Date? {
        func fh(_ s: [String: Any]) -> Double? { num((s["u"] as? [String: Any])?["fh"]) }
        var i = samples.count - 1
        guard i >= 1, let last = fh(samples[i]), last > 0 else { return nil }
        while i >= 1 {
            let prev = samples[i - 1], cur = samples[i]
            if let pf = fh(prev), pf == 0 {
                guard let pt = num(prev["t"]), let ct = num(cur["t"]), ct - pt <= 30 * 60 * 1000 else { return nil }
                let reset = Date(timeIntervalSince1970: (pt + ct) / 2000 + 5 * 3600)
                return reset > Date() ? reset : nil
            }
            i -= 1
        }
        return nil
    }

    // Only a protocol control message: no user message, model request, or new usage window.
    static let renewalArguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                   "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
                                   "--setting-sources", "project", "--no-session-persistence"]
    static let renewalInput = Data(("{\"type\":\"control_request\",\"request_id\":\"usagebar-auth\",\"request\":{\"subtype\":\"initialize\"}}\n").utf8)

    /// CLI initialization renews its own sign-in without inference (verified with Claude Code 2.1.291).
    /// No desktop activity gate is needed. Failed attempts are limited to once per 30 minutes.
    static func renewViaCLI() -> Creds? {
        guard let path = cliPath, Date().timeIntervalSince(lastCLIRenewal) > 30 * 60 else { return nil }
        lastCLIRenewal = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = renewalArguments
        // A minimal environment: an ANTHROPIC_API_KEY inherited from a shell would make the CLI bill that key instead.
        p.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())   // no project CLAUDE.md or settings
        let input = Pipe()
        p.standardInput = input; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("claude CLI initialization could not start: \(error)"); return nil }
        try? input.fileHandleForWriting.write(contentsOf: renewalInput)
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { usleep(200_000) }
        let timedOut = p.isRunning
        if timedOut { p.terminate() }
        guard let c = readKeychain(Config.claudeCLIService), let exp = c.expiresAt, exp > Date() else {
            log("claude CLI initialization did not renew the sign-in (\(timedOut ? "timed out" : "exit \(p.terminationStatus)")) — try `claude auth login`")
            return nil
        }
        log("claude CLI initialization: sign-in valid until \(ISO8601DateFormatter().string(from: exp))")
        return c
    }

    static func fetch(load: () -> Creds? = loadCreds, renew: () -> Creds? = renewViaCLI,
                      readAPI: (Creds?) -> ProviderUsage? = fromAPI,
                      readApp: (String) -> ProviderUsage? = { fromApp(plan: $0) }, now: Date = Date()) -> ProviderUsage {
        var stored = load()
        if let c = stored, (c.expiresAt ?? .distantPast) <= now.addingTimeInterval(5 * 60), let renewed = renew() { stored = renewed }
        let api = readAPI(stored)
        if let a = api, !a.windows.isEmpty { return a }
        if var app = readApp(planLabel(stored)) {
            app.note = api?.error ?? signInHint
            return app
        }
        var none = api ?? ProviderUsage(name: "Claude", plan: planLabel(stored))
        none.error = "Claude: no data — open the Claude app, or run `claude auth login`"
        return none
    }
}

// MARK: - ChatGPT (Codex limits)

enum Codex {
    static let signInHint = "ChatGPT sign-in expired — open Codex once to refresh it"

    static func readAuth() -> [String: Any]? { readJSONFile(Config.codexAuthPath) }

    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let j = json(d), let exp = num(j["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func window(_ v: Any?) -> UsageWindow? {
        guard let w = v as? [String: Any], let p = num(w["used_percent"]) else { return nil }
        let secs = num(w["limit_window_seconds"]) ?? 0
        let label = secs >= 6 * 86400 ? "Weekly" : secs >= 3600 ? "\(Int((secs / 3600).rounded()))-hour" : "\(Int(secs / 60))-min"
        return UsageWindow(label: label, percent: p, resetsAt: num(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }, approx: false)
    }

    /// The usage response only carries the count of banked full-reset credits; their expiry dates come from a
    /// separate read-only endpoint. That read is optional, so it is cached (failures included) and a failure
    /// just leaves the date off. UsageBar never redeems a credit.
    struct ResetCreditCache {
        let key: String
        let fetchedAt: Date
        let credits: [[String: Any]]?       // nil: the read failed or was malformed
    }
    static var resetCreditCache: ResetCreditCache?
    static let resetCreditTTL: TimeInterval = 15 * 60

    /// Cached for 15 minutes; a different sign-in, account or available count forces a new read, and a count of
    /// zero clears the cache without reading. Raw credits are
    /// cached, not the rendered date, so expiry is re-checked against the current time on every poll.
    static func resetCreditDetails(token: String, account: String, count: Int, now: Date = Date(),
                                   read: () -> [[String: Any]]?) -> [[String: Any]]? {
        guard count > 0 else { resetCreditCache = nil; return nil }
        let key = "\(token)|\(account)|\(count)"
        if let c = resetCreditCache, c.key == key, now.timeIntervalSince(c.fetchedAt) >= 0,
           now.timeIntervalSince(c.fetchedAt) < resetCreditTTL { return c.credits }
        let credits = read()
        resetCreditCache = ResetCreditCache(key: key, fetchedAt: now, credits: credits)
        return credits
    }

    static func readResetCredits(token: String, account: String) -> [[String: Any]]? {
        if case .success(let resp) = HTTP.request(Config.codexResetCreditsURL, headers: [
            "Authorization": "Bearer \(token)", "ChatGPT-Account-Id": account,
            "Accept": "application/json", "User-Agent": Config.codexUserAgent
        ]), resp.status == 200, let credits = json(resp.data)?["credits"] as? [[String: Any]] {
            return credits
        }
        log("chatgpt reset credit expiry unavailable; retrying in \(Int(resetCreditTTL / 60)) min")
        return nil
    }

    /// Earliest expiry among credits that are still available: not pending, not redeemed, not expired,
    /// full-reset type and supported by the plan. Anything else is ignored rather than guessed at.
    static func nextResetCreditExpiry(_ credits: [[String: Any]]?, now: Date = Date()) -> Date? {
        func absent(_ v: Any?) -> Bool { v == nil || v is NSNull }
        return (credits ?? []).compactMap { c -> Date? in
            guard (c["status"] as? String) == "available", (c["reset_type"] as? String) == "codex_rate_limits",
                  (c["is_supported_by_plan"] as? Bool) == true,
                  absent(c["redeem_started_at"]), absent(c["redeemed_at"]),
                  let end = parseISO(c["expires_at"] as? String), end > now else { return nil }
            return end
        }.min()
    }

    static func resetCreditSummary(count: Int, credits: [[String: Any]]?, now: Date = Date()) -> String {
        var text = "\(count) full-reset credit\(count == 1 ? "" : "s") available"
        if let end = nextResetCreditExpiry(credits, now: now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM HH:mm"
            text += " · \(count == 1 ? "expires" : "next expiry") \(formatter.string(from: end))"
        }
        return text
    }

    static func fetch() -> ProviderUsage {
        var u = ProviderUsage(name: "ChatGPT", plan: "")
        guard FileManager.default.fileExists(atPath: Config.codexAuthPath) else { u.error = "ChatGPT: not signed in — open Codex and sign in"; return u }
        // Codex rewrites auth.json in place (not atomically); a momentary partial read is not an error worth showing.
        guard let auth = readAuth(), let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String else {
            u.error = "ChatGPT: sign-in file unreadable right now"; return u
        }
        if let exp = jwtExpiry(token), exp < Date() { u.error = signInHint; return u }
        let account = tokens["account_id"] as? String ?? ""
        let r = HTTP.request(Config.codexUsageURL, headers: ["Authorization": "Bearer \(token)", "ChatGPT-Account-Id": account,
                                                             "Accept": "application/json", "User-Agent": Config.codexUserAgent])
        switch r {
        case .failure(let e):
            u.error = "ChatGPT: \(e.localizedDescription)"
        case .success(let resp):
            guard resp.status == 200, let j = json(resp.data) else {
                u.error = resp.status == 401 ? signInHint : "ChatGPT API error \(resp.status)"
                log("chatgpt api: \(u.error ?? "")")
                return u
            }
            if let p = j["plan_type"] as? String { u.plan = p.capitalized }
            if let rl = j["rate_limit"] as? [String: Any] {
                if let w = window(rl["primary_window"]) { u.windows.append(w) }
                if let w = window(rl["secondary_window"]) { u.windows.append(w) }
                if (rl["limit_reached"] as? Bool) == true { u.extras.append("Limit reached") }
            }
            let exhausted = u.worst >= 99
            for extra in (j["additional_rate_limits"] as? [[String: Any]]) ?? [] {
                guard let name = extra["limit_name"] as? String, let rl = extra["rate_limit"] as? [String: Any],
                      let w = window(rl["primary_window"]), w.percent > 0 || exhausted else { continue }
                let label = name == "gpt-reserve" ? "Reserve" : name
                u.windows.append(UsageWindow(label: "\(w.label) · \(label)", percent: w.percent, resetsAt: w.resetsAt, approx: false))
            }
            if let rc = j["rate_limit_reset_credits"] as? [String: Any], let n = num(rc["available_count"]), n > 0 {
                let credits = resetCreditDetails(token: token, account: account, count: Int(n)) {
                    readResetCredits(token: token, account: account)
                }
                u.extras.append(resetCreditSummary(count: Int(n), credits: credits))
            } else {
                resetCreditCache = nil      // zero or missing count: never revive credits from an earlier count
            }
            if let c = j["credits"] as? [String: Any], (c["has_credits"] as? Bool) == true, let bal = c["balance"] as? String {
                u.extras.append("Credits balance: \(bal)")
            }
            if u.windows.isEmpty { u.error = "ChatGPT API returned no usage windows" }
            u.source = "API"
        }
        return u
    }
}

// MARK: - History log (one line per poll, for later charts)

enum History {
    static func append(_ providers: [ProviderUsage]) {
        var rec: [String: Any] = ["t": Int(Date().timeIntervalSince1970)]
        // Only fresh readings: a desktop-app sample that has not changed for hours must not look like new usage.
        for p in providers where !p.windows.isEmpty && !p.lastKnown && Date().timeIntervalSince(p.dataAt) <= Config.staleData {
            var d: [String: Any] = ["at": Int(p.dataAt.timeIntervalSince1970)]
            for w in p.windows { d[w.label] = w.percent }
            rec[p.name.lowercased()] = d
        }
        guard rec.count > 1, let data = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Config.logDir, withIntermediateDirectories: true)
        let path = Config.logDir + "/history.jsonl"
        let line = data + Data("\n".utf8)
        if let h = FileHandle(forWritingAtPath: path) { _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close() }
        else { fm.createFile(atPath: path, contents: line) }
    }
}

// MARK: - UI

final class BarView: NSView {
    var title = "", detail = "", percent = 0.0
    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 14
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let detailAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        (title as NSString).draw(at: NSPoint(x: inset, y: 16), withAttributes: titleAttrs)
        let ds = detail as NSString
        let dw = ds.size(withAttributes: detailAttrs).width
        ds.draw(at: NSPoint(x: bounds.width - inset - dw, y: 17), withAttributes: detailAttrs)
        let track = NSRect(x: inset, y: 6, width: bounds.width - 2 * inset, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let clamped = min(max(percent, 0), 100)
        let w = max(track.width * CGFloat(clamped / 100), clamped > 0 ? 6 : 0)
        color(for: percent).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: w, height: track.height), xRadius: 3, yRadius: 3).fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var providers: [ProviderUsage] = []
    var lastFetch: Date = .distantPast
    var fetching = false
    var timer: Timer?
    // Threshold notifications already sent, kept across restarts so a reinstall does not repeat them.
    var notified: [String: Double] = UserDefaults.standard.dictionary(forKey: "notified") as? [String: Double] ?? [:]
    // Replacing item views on an OPEN menu flickers on macOS 26, so while the menu is open existing rows are
    // updated in place; the menu is rebuilt in menuWillOpen (not yet on screen) and whenever it is closed.
    var menuOpen = false
    var barViews: [String: BarView] = [:]
    var textItems: [String: NSMenuItem] = [:]
    var refreshItem: NSMenuItem?
    var builtStructure = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "UsageBar"
        statusItem.button?.title = "\(Config.claudeGlyph) …  \(Config.gptGlyph) …"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let t = Timer(timeInterval: Config.pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self?.refresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let b = self?.statusItem.button else { return }
            if b.window == nil || b.frame.width == 0 {
                log("menu bar item is not being shown — check System Settings › Menu Bar › Allow in the Menu Bar")
            } else {
                log("menu bar item shown, width \(Int(b.frame.width))pt, user agent \(Claude.userAgent)")
            }
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if Date().timeIntervalSince(lastFetch) > Config.staleAfter { refresh() }
        rebuildMenu()   // not on screen yet, so rebuilding here is fine
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc func refresh() {
        guard !fetching else { return }
        fetching = true
        refreshItem?.title = "Refreshing…"
        refreshItem?.isEnabled = false
        DispatchQueue.global(qos: .utility).async {
            let results = [Claude.fetch(), Codex.fetch()]
            DispatchQueue.main.async {
                self.providers = results.map { self.carryForward($0) }
                self.lastFetch = Date()
                self.fetching = false
                self.refreshItem?.title = "Refresh now"
                self.refreshItem?.isEnabled = true
                self.updateTitle()
                // An open menu with data rows is updated in place (stale rows are fixed at the next open);
                // an open menu that only says "Loading…" is worth one rebuild despite the flicker.
                if !self.menuOpen || self.barViews.isEmpty { self.rebuildMenu() } else { _ = self.updateMenuInPlace() }
                self.maybeNotify()
                History.append(self.providers)
            }
        }
    }

    /// Never blank a reading: if a fetch fails, keep the previous numbers and show the problem underneath.
    func carryForward(_ new: ProviderUsage) -> ProviderUsage {
        guard new.windows.isEmpty, let prev = providers.first(where: { $0.name == new.name }), !prev.windows.isEmpty else { return new }
        var kept = prev
        kept.lastKnown = true
        kept.note = new.error ?? new.note
        return kept
    }

    func isStale(_ p: ProviderUsage) -> Bool { p.lastKnown || Date().timeIntervalSince(p.dataAt) > Config.staleData }

    func updateTitle() {
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        for (i, p) in providers.enumerated() {
            let glyph = p.name == "Claude" ? Config.claudeGlyph : Config.gptGlyph
            var value = p.headline.map(pct) ?? "–"
            let worst = p.worst.rounded()
            if !p.windows.isEmpty && worst >= Config.alertAt { value += "!" }
            let c: NSColor = p.windows.isEmpty || isStale(p) ? .secondaryLabelColor
                : (worst >= Config.alertAt ? .systemRed : worst >= Config.warnAt ? .systemOrange : .labelColor)
            title.append(NSAttributedString(string: (i > 0 ? "  " : "") + glyph + " " + value, attributes: [.font: font, .foregroundColor: c]))
        }
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = providers.map { p in
            "\(p.name): " + (p.windows.isEmpty ? (p.error ?? "no data") : p.windows.map { "\($0.label) \(pct($0.percent))" }.joined(separator: ", "))
                + (isStale(p) ? " (old data, \(ago(p.dataAt)))" : "")
        }.joined(separator: "\n")
    }

    func sourceLine(_ p: ProviderUsage) -> NSAttributedString {
        let text = p.lastKnown ? "last known numbers · \(ago(p.dataAt))"
            : p.source == "API" ? "live · updated \(ago(p.dataAt))" : "from the Claude app · sampled \(ago(p.dataAt))"
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                              .foregroundColor: isStale(p) ? NSColor.systemOrange : NSColor.secondaryLabelColor])
    }

    func detail(_ w: UsageWindow) -> String {
        let reset = resetText(w)
        return reset.isEmpty ? pct(w.percent) : "\(pct(w.percent)) · \(reset)"
    }

    func headerTitle(_ p: ProviderUsage) -> String { p.plan.isEmpty ? p.name : "\(p.name) · \(p.plan)" }
    func noteColor(_ p: ProviderUsage) -> NSColor { p.lastKnown ? .systemOrange : .secondaryLabelColor }

    func rebuildMenu() {
        menu.removeAllItems()
        barViews = [:]; textItems = [:]
        if providers.isEmpty { menu.addItem(disabled("Loading…")) }
        for p in providers {
            let header = NSMenuItem.sectionHeader(title: headerTitle(p))
            menu.addItem(header)
            textItems["\(p.name)/header"] = header
            if let e = p.error, p.windows.isEmpty {
                let item = disabled(e, size: 12, color: .systemOrange)
                menu.addItem(item)
                textItems["\(p.name)/error"] = item
            }
            for w in p.windows {
                let item = NSMenuItem()
                let v = BarView(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
                v.title = w.label
                v.percent = w.percent
                v.detail = detail(w)
                item.view = v
                item.isEnabled = false
                menu.addItem(item)
                barViews["\(p.name)/\(w.label)"] = v
            }
            for (i, x) in p.extras.enumerated() {
                let item = disabled(x, size: 12)
                menu.addItem(item)
                textItems["\(p.name)/extra\(i)"] = item
            }
            if let n = p.note {
                let item = disabled(n, size: 11, color: noteColor(p))
                menu.addItem(item)
                textItems["\(p.name)/note"] = item
            }
            if !p.windows.isEmpty {
                let item = NSMenuItem()
                item.attributedTitle = sourceLine(p)
                item.isEnabled = false
                menu.addItem(item)
                textItems["\(p.name)/source"] = item
            }
            menu.addItem(.separator())
        }
        let r = NSMenuItem(title: fetching ? "Refreshing…" : "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        r.isEnabled = !fetching
        menu.addItem(r)
        refreshItem = r
        let page = NSMenuItem(title: "Open Claude usage page", action: #selector(openClaudePage), keyEquivalent: "")
        page.target = self
        menu.addItem(page)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        builtStructure = providers.map(\.structure).joined(separator: "//")
    }

    /// Update the open menu's rows without replacing them. Returns false if the row structure changed.
    func updateMenuInPlace() -> Bool {
        guard providers.map(\.structure).joined(separator: "//") == builtStructure else { return false }
        for p in providers {
            textItems["\(p.name)/header"]?.title = headerTitle(p)
            if let e = p.error, p.windows.isEmpty { textItems["\(p.name)/error"]?.attributedTitle = attr(e, size: 12, color: .systemOrange) }
            for w in p.windows {
                guard let v = barViews["\(p.name)/\(w.label)"] else { return false }
                v.percent = w.percent
                v.detail = detail(w)
                v.needsDisplay = true
            }
            for (i, x) in p.extras.enumerated() { textItems["\(p.name)/extra\(i)"]?.attributedTitle = attr(x, size: 12, color: .secondaryLabelColor) }
            if let n = p.note { textItems["\(p.name)/note"]?.attributedTitle = attr(n, size: 11, color: noteColor(p)) }
            textItems["\(p.name)/source"]?.attributedTitle = sourceLine(p)
        }
        return true
    }

    func attr(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }

    func disabled(_ text: String, size: CGFloat = 13, color: NSColor = .secondaryLabelColor) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = attr(text, size: size, color: color)
        item.isEnabled = false
        return item
    }

    @objc func openClaudePage() { NSWorkspace.shared.open(Config.claudeUsagePage) }

    func maybeNotify() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        for p in providers where !p.lastKnown {
            for w in p.windows {
                let key = "\(p.name)/\(w.label)"
                let crossed = Config.notifyAt.filter { w.percent >= $0 }.max()
                let prev = notified[key] ?? 0
                if let c = crossed, c > prev {
                    notified[key] = c
                    let content = UNMutableNotificationContent()
                    content.title = "\(p.name) \(w.label.lowercased()) limit at \(pct(w.percent))"
                    let reset = resetText(w)
                    content.body = reset.isEmpty ? "Consider pacing your usage." : reset.prefix(1).uppercased() + reset.dropFirst()
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key + "-\(Int(c))", content: content, trigger: nil))
                } else if crossed == nil {
                    notified[key] = 0   // window reset: re-arm
                }
            }
        }
        UserDefaults.standard.set(notified, forKey: "notified")
    }
}

// MARK: - Entry point

func summary(_ p: ProviderUsage) -> String {
    var lines = [p.name + (p.plan.isEmpty ? "" : " · \(p.plan)") + (p.source.isEmpty ? "" : "  [\(p.source), \(ago(p.dataAt))]")]
    if let e = p.error, p.windows.isEmpty { lines.append("  ! \(e)") }
    for w in p.windows {
        lines.append("  " + w.label.padding(toLength: 18, withPad: " ", startingAt: 0) + pct(w.percent).padding(toLength: 6, withPad: " ", startingAt: 0) + resetText(w))
    }
    for x in p.extras { lines.append("  \(x)") }
    if let n = p.note { lines.append("  note: \(n)") }
    return lines.joined(separator: "\n")
}

if CommandLine.arguments.contains("--once") {
    print(summary(Claude.fetch()))
    print(summary(Codex.fetch()))
    print("(Claude API user agent: \(Claude.userAgent))")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
