import type { ReadinessConfig } from './config.js';
import { cv, fullSplits, mean, median } from './features.js';
import type { ModifierResult, RunRaw, RunSummary } from './types.js';

/**
 * Durability modifiers (spec section 5.4). Each adds a percentage to the predicted time; the total is capped. Sizes are
 * heuristics, not literature values. A check without qualifying data is "unknown" and adds nothing.
 */

export interface ModifierInputs {
  cfg: ReadinessConfig;
  /** Runs of the last durability window with their summaries (all runs, for counting). */
  runs: RunSummary[];
  /** Analysed runs of the same window. */
  raw: Map<string, RunRaw>;
  windowStart: string;
  windowEnd: string;
  goalPaceSecPerKm: number;
  maxHr: number;
}

const inWin = (r: RunSummary, a: string, b: string) => r.date >= a && r.date <= b;
const km = (r: RunSummary) => (r.distanceM ?? 0) / 1000;

/** Analysed runs of the window with at least `minKm`, newest first. */
function analysed(i: ModifierInputs, minKm: number): { run: RunSummary; raw: RunRaw }[] {
  return i.runs
    .filter((r) => inWin(r, i.windowStart, i.windowEnd) && km(r) >= minKm && i.raw.has(r.id))
    .sort((a, b) => b.startMs - a.startMs)
    .map((run) => ({ run, raw: i.raw.get(run.id)! }));
}

/** Runs that qualify for the decoupling check: long, steady, flat, not hot, with usable HR. */
export function decouplingQualifying(i: ModifierInputs): { run: RunSummary; raw: RunRaw }[] {
  const d = i.cfg.modifiers.decoupling;
  return analysed(i, d.minLongRunKm).filter(({ run, raw }) => {
    if (raw.hrUnreliable || raw.decouplingPct === null) return false;
    if (raw.gainPerKm === null || raw.gainPerKm >= d.maxGainPerKm) return false;
    if (run.tempC !== null && run.tempC >= d.maxTempC) return false;
    const paceCv = cv(fullSplits(raw.splits).map((s) => s.pace_seconds_per_unit));
    return paceCv !== null && paceCv < d.maxPaceCv;
  });
}

export function evaluateModifiers(i: ModifierInputs): { results: ModifierResult[]; totalPct: number; cappedPct: number } {
  const m = i.cfg.modifiers;
  const results: ModifierResult[] = [];

  // 1. Decoupling of the last long steady runs.
  {
    const d = m.decoupling;
    const q = decouplingQualifying(i).slice(0, d.lastN);
    const benchmark = `median decoupling < ${d.moderateFromPct}% over the last ${d.lastN} qualifying runs of ${d.minLongRunKm} km or more (steady, flat, not hot)`;
    if (q.length < d.minQualifying) {
      results.push({ check: 'long_run_decoupling', value: null, benchmark, appliedPct: 0, status: 'unknown', evidence: 'weak', detail: `${q.length} qualifying run(s); need ${d.minQualifying}` });
    } else {
      const med = median(q.map((x) => x.raw.decouplingPct!))!;
      const pct = med > d.highFromPct ? d.highPenaltyPct : med >= d.moderateFromPct ? d.moderatePenaltyPct : 0;
      results.push({ check: 'long_run_decoupling', value: Math.round(med * 10) / 10, benchmark, appliedPct: pct, status: pct === 0 ? 'met' : 'not_met', evidence: 'weak', detail: `${q.length} runs` });
    }
  }

  // 2. Number of runs of 30 km or more (summary level: needs no raw data).
  {
    const l = m.longRuns30k;
    const n = i.runs.filter((r) => inWin(r, i.windowStart, i.windowEnd) && km(r) >= l.minKm).length;
    const pct = n < 2 ? l.fewerThanTwoPenaltyPct : n === 2 ? l.exactlyTwoPenaltyPct : 0;
    results.push({ check: 'runs_30km_or_more', value: n, benchmark: '3 or more runs of 30 km in the last 12 weeks', appliedPct: pct, status: pct === 0 ? 'met' : 'not_met', evidence: 'moderate' });
  }

  // 3. Longest continuous stretch at goal pace inside a run of 20 km or more.
  {
    const g = m.goalPaceSegment;
    const runs = analysed(i, g.minRunKm).filter((x) => x.raw.splits.length > 0);
    const benchmark = `a continuous stretch of ${g.minKm} km or more at goal pace (within ${g.tolerance * 100}%) inside a run of ${g.minRunKm} km or more`;
    if (!runs.length) {
      results.push({ check: 'goal_pace_segment', value: null, benchmark, appliedPct: 0, status: 'unknown', evidence: 'weak', detail: `no analysed runs of ${g.minRunKm} km or more with splits` });
    } else {
      const limit = i.goalPaceSecPerKm / (1 - g.tolerance);
      let best = 0;
      for (const { raw } of runs) {
        let streak = 0;
        for (const s of raw.splits) {
          if (!s.partial && s.pace_seconds_per_unit > 0 && s.pace_seconds_per_unit <= limit) {
            streak++;
            best = Math.max(best, streak);
          } else streak = 0;
        }
      }
      const pct = best < g.minKm ? g.penaltyPct : 0;
      results.push({ check: 'goal_pace_segment', value: best, benchmark, appliedPct: pct, status: pct === 0 ? 'met' : 'not_met', evidence: 'weak', detail: `${runs.length} run(s) examined` });
    }
  }

  // 4. Heart rate late in long runs at goal pace.
  {
    const h = m.hrLateInLongRuns;
    const benchmark = `HR at goal pace after km ${h.afterKm} of long runs at or below ${h.maxHrFraction * 100}% of max HR`;
    const fractions: number[] = [];
    for (const { raw } of analysed(i, h.afterKm)) {
      if (raw.hrUnreliable) continue;
      for (const s of fullSplits(raw.splits)) {
        if (s.split <= h.afterKm || s.avg_hr === null) continue;
        if (Math.abs(s.pace_seconds_per_unit - i.goalPaceSecPerKm) / i.goalPaceSecPerKm <= h.paceTolerance) fractions.push(s.avg_hr / i.maxHr);
      }
    }
    if (!fractions.length) {
      results.push({ check: 'hr_at_goal_pace_late_in_long_runs', value: null, benchmark, appliedPct: 0, status: 'unknown', evidence: 'weak', detail: `no splits after km ${h.afterKm} at goal pace with heart rate` });
    } else {
      const v = mean(fractions)!;
      const pct = v > h.maxHrFraction ? h.penaltyPct : 0;
      results.push({ check: 'hr_at_goal_pace_late_in_long_runs', value: Math.round(v * 1000) / 10, benchmark, appliedPct: pct, status: pct === 0 ? 'met' : 'not_met', evidence: 'weak', detail: `${fractions.length} split(s)` });
    }
  }

  const totalPct = results.reduce((n, r) => n + r.appliedPct, 0);
  return { results, totalPct, cappedPct: Math.min(m.capPct, totalPct) };
}
