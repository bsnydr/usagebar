// Appended to the app declarations by test.sh; all provider I/O is stubbed.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
func creds(_ seconds: Double) -> Claude.Creds {
    Claude.Creds(raw: ["claudeAiOauth": ["accessToken": "synthetic",
        "expiresAt": now.addingTimeInterval(seconds).timeIntervalSince1970 * 1000]])
}
let live = ProviderUsage(name: "Claude", plan: "", windows: [
    UsageWindow(label: "Weekly", percent: 42, resetsAt: nil, approx: false)
], source: "API")
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

let fallback = Claude.fetch(load: { creds(-100) }, renew: { nil }, readAPI: { _ in
    ProviderUsage(name: "Claude", plan: "", error: Claude.signInHint)
}, readApp: { _ in stale }, now: now)
check(fallback.dataAt == stale.dataAt && fallback.note == Claude.signInHint,
      "Failed renewal must preserve sample age and explain the failure")

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
