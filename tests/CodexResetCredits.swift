// Appended after tests/ClaudeRenewal.swift by test.sh (reuses its `check` and `now`); no network or credentials.
let isoNow = ISO8601DateFormatter()
func credit(_ expires: String?, status: String = "available", type: String = "codex_rate_limits",
            supported: Bool = true, started: Any = NSNull(), redeemed: Any = NSNull()) -> [String: Any] {
    var c: [String: Any] = ["status": status, "reset_type": type, "is_supported_by_plan": supported,
                            "redeem_started_at": started, "redeemed_at": redeemed]
    if let expires = expires { c["expires_at"] = expires }
    return c
}
func at(_ days: Double) -> String { isoNow.string(from: now.addingTimeInterval(days * 86400)) }

// The live response shape: six fractional digits, out of order, decoded the way the app decodes it.
let liveDetail = json(Data("""
{"available_count":3,"credits":[
 {"expires_at":"2027-01-20T20:34:23.802627Z","status":"available","reset_type":"codex_rate_limits","is_supported_by_plan":true,"redeem_started_at":null,"redeemed_at":null},
 {"expires_at":"2027-01-10T18:59:42.552828Z","status":"available","reset_type":"codex_rate_limits","is_supported_by_plan":true,"redeem_started_at":null,"redeemed_at":null},
 {"expires_at":"2027-01-30T23:29:12.593788Z","status":"available","reset_type":"codex_rate_limits","is_supported_by_plan":true,"redeem_started_at":null,"redeemed_at":null}
]}
""".utf8))!["credits"] as? [[String: Any]]
let liveNow = parseISO("2027-01-05T00:00:00Z")!
check(parseISO("2027-01-10T18:59:42.552828Z") != nil, "Six fractional digits must parse")
check(Codex.nextResetCreditExpiry(liveDetail, now: liveNow) == parseISO("2027-01-10T18:59:42.552828Z"),
      "Pick the earliest expiry regardless of response order")

// Time zone: the line uses the local zone, like Claude's.
let savedZone = NSTimeZone.default
NSTimeZone.default = TimeZone(identifier: "Europe/Madrid")!
let madrid = Codex.resetCreditSummary(count: 3, credits: [credit("2026-10-22T20:34:23.802627Z")],
                                      now: parseISO("2026-10-21T00:00:00Z")!)
check(madrid.hasPrefix("3 full-reset credits available · next expiry 22 ") && madrid.hasSuffix(" 22:34"),
      "Madrid shows 22:34 for 20:34Z: \(madrid)")
NSTimeZone.default = savedZone

// Singular vs plural wording.
check(Codex.resetCreditSummary(count: 1, credits: [credit(at(2))], now: now).contains(" available · expires "),
      "Singular uses expires")
check(Codex.resetCreditSummary(count: 2, credits: [credit(at(2))], now: now).contains(" available · next expiry "),
      "Plural uses next expiry")

// Only available, unredeemed, unexpired, supported full-reset credits count; stale statuses don't help.
let mixed = [
    credit(at(-1)),                                   // expired, though status still says available
    credit(at(1), status: "pending"),
    credit(at(1), status: "redeemed"),
    credit(at(1), redeemed: at(-1)),                  // redeemed despite a stale status
    credit(at(1), started: at(-0.01)),                // redemption in progress
    credit(at(1), supported: false),
    credit(at(1), type: "something_else"),
    credit(nil),                                      // no expiry: never invent one
    credit("not a date"),
    credit(at(5)),
    credit(at(3))
]
check(Codex.nextResetCreditExpiry(mixed, now: now) == parseISO(at(3)), "Filter ineligible credits")
check(Codex.nextResetCreditExpiry(Array(mixed[0..<9]), now: now) == nil, "No eligible credit means no expiry")
check(Codex.nextResetCreditExpiry([], now: now) == nil && Codex.nextResetCreditExpiry(nil, now: now) == nil,
      "Missing detail means no expiry")

// Missing or failed detail keeps the original line.
check(Codex.resetCreditSummary(count: 3, credits: nil, now: now) == "3 full-reset credits available",
      "Failed detail read keeps the count-only line")
check(Codex.resetCreditSummary(count: 1, credits: [["status": 5, "expires_at": 7]], now: now)
      == "1 full-reset credit available", "Malformed credits keep the count-only line")

// Cache: one read per 15 minutes, failures included; sign-in, account or count changes force a re-read.
Codex.resetCreditCache = nil
var reads = 0
func cached(_ token: String = "t", _ account: String = "a", _ count: Int = 3, at t: Date = now,
            result: [[String: Any]]? = [credit(at(2))]) -> [[String: Any]]? {
    Codex.resetCreditDetails(token: token, account: account, count: count, now: t) { reads += 1; return result }
}
_ = cached(); _ = cached(at: now.addingTimeInterval(14 * 60))
check(reads == 1, "Reuse the detail read within 15 minutes")
_ = cached(at: now.addingTimeInterval(15 * 60))
check(reads == 2, "Re-read after 15 minutes")
_ = cached("t2", at: now.addingTimeInterval(15 * 60)); check(reads == 3, "New token re-reads")
_ = cached("t2", "b", at: now.addingTimeInterval(15 * 60)); check(reads == 4, "New account re-reads")
_ = cached("t2", "b", 2, at: now.addingTimeInterval(15 * 60)); check(reads == 5, "New count re-reads")
Codex.resetCreditCache = nil; reads = 0
_ = cached(result: nil); _ = cached(at: now.addingTimeInterval(60), result: nil)
check(reads == 1, "Failures are cached too")
// Zero (or missing) count never reads and drops the cache, so 3 -> 0 -> 3 cannot revive old credits.
Codex.resetCreditCache = nil; reads = 0
_ = cached(); check(reads == 1, "Warm the cache")
check(cached("t", "a", 0, at: now.addingTimeInterval(60)) == nil
      && cached("t", "a", -1, at: now.addingTimeInterval(60)) == nil && reads == 1, "Non-positive count must not read")
check(Codex.resetCreditCache == nil, "Non-positive count clears the cache")
_ = cached(at: now.addingTimeInterval(120)); check(reads == 2, "Returning to a positive count reads afresh")
// A cached credit that lapses is re-evaluated at render time, so a past date never shows.
let soon = [credit(at(1)), credit(at(9))]
let early = Codex.resetCreditSummary(count: 2, credits: soon, now: now)
let later = Codex.resetCreditSummary(count: 2, credits: soon, now: now.addingTimeInterval(2 * 86400))
check(early != later && Codex.nextResetCreditExpiry(soon, now: now.addingTimeInterval(2 * 86400)) == parseISO(at(9)),
      "Cached credits are re-checked against the current time")
Codex.resetCreditCache = nil
print("Codex reset credit regression checks passed")
