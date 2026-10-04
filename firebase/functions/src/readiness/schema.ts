import { z } from 'zod';

/** Output of assess_race_readiness (spec section 7). Every field except status and as_of is absent when the status is not "ok". */

const hms = z.string().describe('h:mm:ss');
const evidence = z.enum(['strong', 'moderate', 'weak']);

export const readinessShape = {
  status: z.enum(['ok', 'insufficient_data', 'unsupported_distance', 'no_race_goal']),
  as_of: z.string().describe('Local date YYYY-MM-DD; no data after it was read'),
  mode: z.enum(['race_window', 'current_fitness_snapshot']).optional().describe('current_fitness_snapshot when the race is more than 6 weeks away'),
  race: z.object({
    id: z.string(), name: z.string(), date: z.string(), days_until: z.number(), goal_time: hms, goal_pace_per_km: z.string().nullable(),
  }).optional(),
  likelihood: z.object({ score_0_10: z.number(), probability: z.number(), label: z.string() }).optional(),
  prediction: z.object({
    central: hms, range_80: z.tuple([hms, hms]), sigma_pct: z.number(),
    central_before_durability: hms.describe('the same estimate without the durability checks (weak-evidence heuristics)'),
    durability_adjustment_pct: z.number(),
    probability_before_durability: z.number().describe('likelihood of meeting the goal without the durability checks'),
  }).optional(),
  confidence: z.object({
    percent: z.number(),
    components: z.array(z.object({ name: z.string(), points: z.number(), max: z.number(), status: z.enum(['full', 'partial', 'none', 'unknown']), reason: z.string() })),
  }).optional(),
  estimators: z.array(z.object({
    name: z.string(), available: z.boolean(), predicted: hms.nullable(), sigma_pct: z.number().nullable(), weight: z.number().nullable(),
    inputs: z.record(z.string(), z.unknown()), notes: z.array(z.string()),
  })).optional(),
  modifiers: z.array(z.object({
    check: z.string(), value: z.number().nullable(), benchmark: z.string(), applied_pct: z.number(), status: z.enum(['met', 'not_met', 'unknown']), evidence, detail: z.string().optional(),
  })).optional(),
  adjustments: z.array(z.object({ name: z.string(), pct: z.number().describe('percent of the finish time, positive = slower'), evidence, detail: z.string() })).optional(),
  benchmarks: z.array(z.object({ metric: z.string(), value: z.number().nullable(), context: z.string(), evidence })).optional(),
  block_comparison: z.object({
    prior_marathon: z.object({ workout_id: z.string(), date: z.string(), time: hms, representative: z.boolean() }).nullable(),
    weekly_km_now_vs_prior: z.tuple([z.number(), z.number().nullable()]),
    runs_30k_now_vs_prior: z.tuple([z.number(), z.number().nullable()]),
    speed_at_75pct_hrmax_ratio: z.number().nullable(),
    speed_at_marathon_effort_ratio: z.number().nullable().describe('speed at 87% of max HR in long runs, now vs the prior block'),
    body_mass_kg_now_vs_prior: z.tuple([z.number().nullable(), z.number().nullable()]).describe('kg, 28-day mean now vs before the prior marathon; context, not added on top of the efficiency comparison'),
    pace_at_same_hr: z.array(z.object({ bpm: z.number(), now: z.string().nullable(), prior: z.string().nullable(), faster_pct: z.number().nullable() })).nullable().describe('pace per km at the same heart rate in sustained stretches of long runs, now vs the prior block (only where both blocks have data at that heart rate)'),
    runs_read_in_detail: z.object({ current_window: z.tuple([z.number(), z.number()]), prior_window: z.tuple([z.number(), z.number()]).nullable() }).describe('[read from raw streams, total] runs of 8 km or more in the last 6 weeks of the current block and of the prior block'),
    volume_based_repeat: hms.nullable().describe('prior marathon scaled by the change in Tanda training indices (cross-check only, not averaged in)'),
  }).optional(),
  data_gaps: z.array(z.string()),
  assumptions: z.object({
    max_hr: z.number(), max_hr_source: z.enum(['user', 'observed', 'default']), max_hr_note: z.string().nullable(),
    body_fat_source: z.enum(['health', 'default']), sex_source: z.enum(['profile', 'unknown']),
    goal_time_source: z.enum(['race_goal', 'parameter']),
    course: z.enum(['flat', 'rolling', 'hilly']).nullable(),
    expected_temp_c: z.number().nullable(),
  }).optional(),
  caveats: z.array(z.string()),
  /** Only with detail "full". */
  workouts: z.array(z.record(z.string(), z.unknown())).optional(),
};

export const readinessSchema = z.object(readinessShape);
export type ReadinessResult = z.infer<typeof readinessSchema>;
