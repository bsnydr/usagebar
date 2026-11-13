// Appended to the app declarations by test.sh; all provider I/O is stubbed.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
func creds(_ seconds: Double) -> Claude.Creds {
    Claude.Creds(raw: ["claudeAiOauth": ["accessToken": "synthetic",
        "expiresAt": now.addingTimeInterval(seconds).timeIntervalSince1970 * 1000]])
}
// State files (cooldown, last good reading) go to a temp dir, never the user's real one.
let stateTmp = NSTemporaryDirectory() + "usagebar-test-\(getpid())"
Claude.stateDir = stateTmp
func resetState() { try? FileManager.default.removeItem(atPath: stateTmp) }
resetState()
let live = ProviderUsage(name: "Claude", plan: "", windows: [
    UsageWindow(label: "Weekly", percent: 42, resetsAt: nil, approx: false)
], source: "API", dataAt: now)
let stale = ProviderUsage(name: "Claude", plan: "", windows: [
    UsageWindow(label: "Weekly", percent: 31, resetsAt: nil, approx: true)
], source: "Claude app", dataAt: now.addingTimeInterval(-4 * 86400))

// The reported failure: expired sign-in plus four-day-old desktop samples must recover.
var renewals = 0
var appReads = 0
let recovered = Claude.fetch(load: { creds(-86400) }, renew: {
    renewals += 1; return creds(8 * 3600)
}, readAPI: { c in
    check(c!.expiresAt! > now, "API must receive renewed credentials")
    return live
}, readApp: { _ in appReads += 1; return stale }, now: now)
check(renewals == 1 && appReads == 0 && recovered.source == "API", "Recovery must not depend on desktop samples")

// No desktop installation is needed, including when a token is about to expire.
_ = Claude.fetch(load: { creds(240) }, renew: {
    renewals += 1; return creds(8 * 3600)
}, readAPI: { _ in live }, readApp: { _ in nil }, now: now)
check(renewals == 2, "Renew near expiry")

_ = Claude.fetch(load: { creds(3600) }, renew: {
    fatalError("A valid sign-in must not launch the CLI")
}, readAPI: { _ in live }, readApp: { _ in nil }, now: now)
_ = Claude.fetch(load: { nil }, renew: {
    fatalError("A missing sign-in must not launch login")
}, readAPI: { _ in nil }, readApp: { _ in nil }, now: now)

resetState()
let fallback = Claude.fetch(load: { creds(-100) }, renew: { nil }, readAPI: { _ in
    ProviderUsage(name: "Claude", plan: "", error: Claude.signInHint)
}, readApp: { _ in stale }, now: now)
check(fallback.dataAt == stale.dataAt && fallback.note == Claude.signInHint,
      "Failed renewal must preserve sample age and explain the failure")

// Stale-usage regression: a failing API must not let an older desktop sample replace the last good reading.
resetState()
_ = Claude.fetch(load: { creds(3600) }, renew: { nil }, readAPI: { _ in live }, readApp: { _ in nil }, now: now)
let failing: (Claude.Creds?) -> ProviderUsage? = { _ in ProviderUsage(name: "Claude", plan: "", error: "Claude API is rate-limiting") }
let kept = Claude.fetch(load: { creds(3600) }, renew: { nil }, readAPI: failing, readApp: { _ in stale }, now: now)
check(kept.lastKnown && kept.windows.first?.percent == 42 && kept.dataAt == live.dataAt && kept.note == "Claude API is rate-limiting",
      "Older desktop sample must not replace the last good API reading; flag it as last known with the reason")
// ...but a genuinely newer desktop sample is used.
var newer = stale
newer.dataAt = now.addingTimeInterval(600)
let usedApp = Claude.fetch(load: { creds(3600) }, renew: { nil }, readAPI: failing, readApp: { _ in newer }, now: now)
check(usedApp.source == "Claude app" && !usedApp.lastKnown && usedApp.note != nil, "Newer desktop sample wins and keeps the failure note")
// Account safety: another login (different token) must never be shown the previous account's reading.
let otherLogin = Claude.Creds(raw: ["claudeAiOauth": ["accessToken": "other-synthetic",
    "expiresAt": now.addingTimeInterval(3600).timeIntervalSince1970 * 1000]])
let other = Claude.fetch(load: { otherLogin }, renew: { nil }, readAPI: failing, readApp: { _ in nil }, now: now)
check(other.windows.isEmpty && !other.lastKnown, "A different login must not see the previous login's numbers")
// ...and the cache is not on disk: nothing identifying or reading-shaped is persisted.
check(!FileManager.default.fileExists(atPath: stateTmp + "/claude-last-good.json"), "Last good reading is memory only")

// Backoff: Retry-After honoured and bounded, exponential without it, persisted, cleared on success.
check(Claude.retryDelay(retryAfter: "900", failures: 1, now: now) == 900, "Honour Retry-After seconds")
check(Claude.retryDelay(retryAfter: "5", failures: 1, now: now) == 60, "Floor Retry-After at a minute")
check(Claude.retryDelay(retryAfter: "86400", failures: 1, now: now) == 86400, "A long server Retry-After is never shortened")
check(Claude.retryDelay(retryAfter: "999999", failures: 1, now: now) == 999999, "A very long Retry-After is still honoured")
let httpDate = DateFormatter()
httpDate.locale = Locale(identifier: "en_US_POSIX"); httpDate.timeZone = TimeZone(identifier: "GMT")
httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
check(Claude.retryDelay(retryAfter: httpDate.string(from: now.addingTimeInterval(1200)), failures: 1, now: now) == 1200, "Honour Retry-After HTTP date")
check(Claude.retryDelay(retryAfter: nil, failures: 1, now: now) == 600, "Default first backoff is 10 minutes")
check(Claude.retryDelay(retryAfter: nil, failures: 2, now: now) == 1200, "Backoff doubles")
check(Claude.retryDelay(retryAfter: nil, failures: 20, now: now) == Claude.backoffCap, "Backoff is bounded")
resetState()
let until = Claude.noteFailure(retryAfter: "1800", now: now)
check(until == now.addingTimeInterval(1800) && Claude.loadBackoff().until == until, "Cooldown persists across restarts")
_ = Claude.noteFailure(retryAfter: nil, now: now)
check(Claude.loadBackoff().failures == 2, "Consecutive failures accumulate")
Claude.noteSuccess()
check(Claude.loadBackoff().failures == 0 && Claude.blockedUntil < now, "Success clears the cooldown")
// A reset-metadata failure uses its own cooldown and must not pause usage polling.
Claude.noteResetFailure(retryAfter: "86400", now: now)
check(Claude.resetNextCheck == now.addingTimeInterval(86400), "Long reset Retry-After honoured")
check(Claude.blockedUntil < now && Claude.loadBackoff().failures == 0, "Reset failure must not start the usage cooldown")
Claude.noteResetFailure(retryAfter: nil, now: now)
check(Claude.resetNextCheck == now.addingTimeInterval(Claude.resetCheckInterval), "Reset failure waits at least the normal interval")
resetState()

let request = json(Claude.renewalInput)!
check(request["type"] as? String == "control_request", "Renewal must never send a user prompt")
check((request["request"] as? [String: Any])?["subtype"] as? String == "initialize", "Only initialize the protocol")
check(Claude.renewalArguments.contains("--no-session-persistence"), "Do not save a chat")
check(!Claude.renewalArguments.contains("--model"), "Renewal must not request a model")
print("Claude renewal regression checks passed")

let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(86400))
let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86400))
let grants: [String: Any] = ["eligible": true, "grants": [
    ["resets_left": 1, "ends_at": future, "usable_now": true],
    ["resets_left": 2, "ends_at": past],
    ["resets_left": 1, "starts_at": future],
    ["resets_left": 0, "ends_at": future]
]]
let resetLine = Claude.resetGrantSummary(grants, now: now)
check(resetLine.hasPrefix("1 usage-limit reset available · expires"), "Count only remaining, started, unexpired resets")
check(Claude.resetGrantSummary(["eligible": true, "grants": [["resets_left": 2]]], now: now)
      == "2 usage-limit resets available", "Grants without expiry still count")
check(Claude.resetGrantSummary(["eligible": true, "grants": []], now: now)
      == "No usage-limit resets available", "Known empty grants are zero")
check(Claude.resetGrantSummary(nil, now: now).hasPrefix("Reset availability unavailable"), "Missing grants are unknown, not zero")
check(Claude.resetGrantSummary(["eligible": false, "grants": []], now: now)
      .hasPrefix("Reset availability unavailable"), "Surface rejection must not imply zero resets")
check(Claude.resetGrantSummary(["eligible": true, "grants": [["resets_left": 1, "usable_now": false]]], now: now)
      .hasSuffix("not usable yet"), "Distinguish banked resets from immediately usable ones")
print("Claude reset availability regression checks passed")
