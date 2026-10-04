# Race readiness (`assess_race_readiness`)

Read-only MCP tool that answers "am I in 3:45 shape for Chicago?" with a **likelihood score 0-10** of finishing a marathon at or under the runner's own goal time, a **predicted finish time with an 80% range**, and a separate **data-confidence %**. v1 is marathon only; other distances return `unsupported_distance`.

It is a model estimate from population formulas and heuristics, not measured physiology: not a guarantee, medical assessment or training prescription. When the race is more than 6 weeks away it describes current fitness, not race-day fitness.

## How it works

Code: `firebase/functions/src/readiness/`. The computation (`compute.ts`) is pure; `extract.ts` is the only part that touches storage.

| Step | File | What |
|---|---|---|
| Extraction | `extract.ts` | Run summaries for 36 months + the prior block (duplicates from two sources removed); raw streams (splits, best efforts, HR drift) only for a shortlist, within a 28 s soft time budget. Reuses `loadType`, `findWorkout`-style loading, `loadStream`, `distanceOf`, and the pure functions of `query/calc.ts`; no MCP tool calls. |
| Estimators | `estimators.ts` | E1 race conversion (`T x (42195/D)^R`, R = log2(2.19) adjusted for volume, or a personal exponent; 10K/5K sources are first converted to a half-marathon equivalent with a milder exponent of 1.06, so short races do not over-penalise); only a tagged race, or an untagged run of race distance (not a segment inside a longer run) at race heart rate, qualifies as a source; E1b the best effort inside a training run, used only as an upper bound on the central estimate when E1 or E2 exist, and as a (sigma 12%) estimator only when neither does; E2 prior-marathon repeat adjusted by speed at 75% HRmax; E3 Tanda & Knechtle (2013). |
| Durability | `modifiers.ts` | Four heuristic checks adding up to +5% to the predicted time. |
| Context | `adjust.ts` | Optional course profile, expected race-day temperature and a super-shoes what-if. Small heuristic percentages that also widen sigma. |
| Combination | `combine.ts` | Inverse-variance mean, correlation floor (0.85 x best sigma), race-day term, normal CDF -> score. |
| Confidence | `confidence.ts` | Nine components out of 100. Reported separately; never changes the score. |
| Output | `schema.ts` | Zod schema = the MCP `outputSchema`. |
| Tool | `assess.ts` | Argument handling, race selection, status codes. |

Every tunable number lives in `config.ts` (`READINESS_CONFIG`). Modifier sizes, sigmas and confidence weights are heuristics ("weak" evidence) until calibrated by backtest.

## Behaviour worth knowing

- `as_of_date` bounds every read: nothing after that local date is used (tested). It defaults to today.
- Inputs: `race_workout_ids` (user-tagged tune-up races, the strongest input), `max_hr` (a measured value beats an observed one, which beats an age formula, which beats a flat 190 bpm; defaults are disclosed and lower confidence), `goal_time` (what-if), `prior_marathon_workout_id` (`"none"` disables).
- Profile (age, sex) and nutrition events are read only if the category is on in the app **and** the connection holds `health:profile:read` / `health:events:read`; otherwise they are listed as gaps. Unlogged nutrition lowers confidence only, it is never treated as zero fueling.
- Durability checks are compared with the prior marathon block when that marathon carries weight: the prior time already contains that block's durability, so against that share only a shortfall counts (`relativeModifiers`); the share on E1/E3 stays absolute. Checks that cannot be evaluated for the prior block stay absolute.
- `block_comparison.volume_based_repeat` scales the prior marathon by the change in Tanda training indices. It is a cross-check only (never averaged in, to avoid counting fitness twice); a caveat is added when it differs from E2 by more than 3%.
- E1s (earlier race): a race older than the current block (up to 36 weeks) is converted like E1 and then moved by the measured change in speed at 75% of max HR since that race (gain capped at 5%). Without an efficiency comparison it credits a change only when weekly volume was maintained (at least 90% of the level before that race) and there was no gap over 14 days, using the Tanda training-index ratio. Sigma starts at 6.5% (the training formula's level: published models that add a prior race to training data improve marathon prediction only modestly, so it is not weighted above them), +0.1% per week beyond the block, +2% if volume fell or there was a break, +1% without an efficiency comparison. When the prior marathon exists, the exponent moves halfway from the default towards the marathon-vs-race relationship in the lead-up to it (one pair is noisy and mixes in fitness change).
- E2's efficiency comparison also runs at marathon effort: splits of steady runs at 82-92% of max HR (long runs, marathon-pace work) in the last 6 weeks of each block, speed predicted at 87% of max HR. It is matched on effort (heart rate), not on pace, so it works when this year's goal pace differs from last year's. It is blended 50/50 with the aerobic (75%) ratio; a gap above 3% between the two adds 1% sigma; either alone is used when the other cannot be fitted (15 splits and a heart-rate spread are needed in both blocks). Only sustained stretches of 3 or more consecutive splits in the band count, because heart rate lags pace in short efforts. `block_comparison.pace_at_same_hr` lists the pace per km at 160, 165, 170 and 175 bpm for each block and the % faster, only inside the heart-rate range both blocks cover (no extrapolation). Splits in the aerobic band and the marathon-effort band never overlap, so the same split is not counted twice.
- Raw streams are read for a shortlist (limit 72 runs per request, 28 s soft time budget), not for every run. Priority: the prior marathon and tagged races, earlier-race candidates, every run of 8 km or more in the last 6 weeks of each block (the two comparison windows), then steady runs, the current block's long runs and best efforts, the prior block's long runs. Older weeks of a block are mostly judged from summaries (weekly km, counts, average HR). `block_comparison.runs_read_in_detail` reports [read, total] runs of 8 km or more in each comparison window. `prediction.central_before_durability` and `probability_before_durability` show the estimate without the weak-evidence durability checks.
- Body mass: fitness change from weight is already in speed at a fixed heart rate, so it is not added to E2 or to E1s when an efficiency comparison exists. Where there is none (E1s volume/none basis), mass change moves the time by 0.5% per 1% of body mass (capped at 4%, weak evidence). Tanda uses body fat directly. `block_comparison.body_mass_kg_now_vs_prior` reports the 28-day means.
- Estimators that disagree widen the uncertainty: their weighted spread is added in quadrature to the combined sigma (`combine.disagreementFactor`).
- No score is returned (`insufficient_data`) when fewer than 6 of the last 16 weeks have runs, or when neither a race-quality effort (E1) nor a prior-marathon comparison (E2) exists. The training-based estimator is never used alone.
- Not supported: heart-rate cadence-lock detection (no cadence stream is guaranteed); only implausible or flat HR traces are flagged. Weather checks need the recording app to have stored temperature (Apple Watch does).

## Race-day context (marathon only)

| Input | Effect | Notes |
|---|---|---|
| `course` = flat / rolling / hilly | 0 / +1% / +2.5% | Default: treated as flat. Source efforts are assumed to be on roughly flat terrain; a hilly source is flagged but not corrected. |
| `expected_temp_c` | +0.4% per degree above 15 degC, capped at 8% | Heat slows marathoners, slower runners more ([Ely et al. 2007](https://experts.umn.edu/en/publications/impact-of-weather-on-marathon-running-performance/)). Never fetched from a forecast: pass what the user says. |
| `new_super_shoes` | -1% (what-if) | Population averages are about 1%, individual response varies from a loss to a large gain; Apple Health does not record shoes. Use only if the shoes were not worn for the source efforts, or the gain is counted twice. |
| Heat in the source efforts | time expressed at a mild temperature | Uses the run's recorded temperature (Apple Watch); hot runs are also excluded from the efficiency fit. |
| Fueling, crowds | not modelled | Fueling is reported as context (carbs logged on long runs) and in confidence only; unlogged does not mean unfueled. Crowds are covered by the 2% race-day term. |

Every adjustment is labelled weak evidence, listed in `adjustments`, and adds to sigma (its size x 0.5, the shoes what-if x 1.0) in quadrature. The 52-week base volume is shown as context only and is not used in the estimate.

## Backtest

```
cd firebase/functions
GCP_PROJECT_ID=<project> node_modules/.bin/tsx scripts/backtest-readiness.ts <uid>[,<uid>...] [--days-before 14] [--max-hr N] [--config overrides.json] [--json out.json]
```

For every past marathon (41.5-43.5 km run) the tool is run as of 14 days before with the goal set to the actual time. It reports the signed error of the central prediction, how often the actual time fell inside the 80% range (should be near 80%), and the probability-integral-transform value (should be spread evenly over 0-1 if calibrated). One runner has only a handful of marathons: pool runners before changing defaults, then freeze `config.ts`.
