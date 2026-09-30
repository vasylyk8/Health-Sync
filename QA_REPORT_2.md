# KROK: QA round 2 (overnight, 30 Sep 2026)

Branch `claude/sharp-brown-bw9xic`. Scope: improvements only, no new features, no data-format changes.

## How it was tested
| Surface | Method |
|---|---|
| Server | Lint, typecheck, unit tests (102 pass + 2 known expected-fail), emulator tests in CI; ~15 live calls of every MCP tool against the owner's real data (read-only): edge dates, bad windows, limits, workouts with and without GPS, swim/strength/run |
| Website | Local Chromium at 375 px light and 1100 px dark on all four pages, horizontal scroll check, console/CSP check |
| iOS | Code review of every view and the sync path; build, unit tests, UI tests, accessibility audit, small-phone and dark-mode runs via GitHub Actions (`ios-ci`, `qa-ios`) |
| Carried over | Open items of `QA_REPORT.md` |

## Findings and status
| ID | Sev | Finding | Status |
|---|---|---|---|
| N-1 | High | `get_workouts` with `limit` smaller than the number of matches returned an error instead of the first N workouts | Fixed: returns the first N, `truncated: true` and a hint on where to continue |
| N-2 | High | An invalid record rejected a whole batch of up to 5,000 records, after the phone had already moved on (H3.2) | Fixed: the bad record is skipped and logged, the rest is stored; a batch with no valid record is still rejected |
| N-3 | Med | Daily metrics came back with float noise (`26388.047698444407` steps), wasting AI tokens and reading badly | Fixed: sensible rounding in `get_daily_context` and `get_workout` |
| N-4 | Med | Weather humidity read `"8100 %"` (Apple stores it x100) | Fixed: `"81 %"` |
| N-5 | Med | Swim workouts showed `HKSwimmingLocationType: true` | Fixed: `pool` / `open water` / `unknown` |
| N-6 | Med | `get_workout` event list carried 7-18 overlapping auto "segment" events per workout | Fixed: omitted from the list (count kept in `counts`) |
| N-7 | Low | `get_workout_series` with start after end silently returned nothing | Fixed: clear `bad_request` |
| N-8 | Low | Activity filter treated `%` and `_` as wildcards | Fixed |
| N-9 | Med | "No readable Health data found" could never appear (M4) | Fixed: checked before the "Synced" line |
| N-10 | Low | Setup sheet used raw grey/green/orange that fail contrast in places; no feedback when the assistant connected | Fixed: shared readable colours, success haptic |
| N-11 | Med | Website had no CSP or Permissions-Policy; privacy page used an inline style; no skip link; large headings on small phones | Fixed |
| M2 | Med | First sync slow (38 min for 30 days) | Open (needs device profiling) |
| M9, M10, H4 | Med | Correlation anchoring, long-range query speed, deleted-hour totals | Open: need storage-format changes, out of scope tonight |
| M7 | Med | Link tokens in request logs | Open: project setting, see `docs/LOG_HYGIENE.md` |
| M11 | Low | Home status text clipping at largest text sizes | Open: cannot be verified without a device; audit exemption kept |

## Not testable here
Physical device behaviour, background delivery over days, VoiceOver by hand, real Claude/ChatGPT connector screens.
