import type { SplitRow } from '../../src/query/calc.js';
import { addDays } from '../../src/readiness/features.js';
import type { EffortHr, ReadinessInputs, RunRaw, RunSummary } from '../../src/readiness/types.js';

/** Hand-buildable runs, raw analyses and inputs for the pure readiness computation. */

export const DAY_MS = 86_400_000;

export function run(id: string, date: string, km: number, pace: number, o: { hr?: number | null; maxHr?: number | null; indoor?: boolean; tempC?: number | null } = {}): RunSummary {
  const startMs = Date.parse(date + 'T07:00:00Z');
  const movingSec = km * pace;
  return {
    id, startMs, endMs: startMs + movingSec * 1000, date, distanceM: km * 1000, movingSec, avgHr: o.hr === undefined ? 150 : o.hr, maxHr: o.maxHr === undefined ? null : o.maxHr,
    source: 'Apple Watch', indoor: o.indoor ?? false, tempC: o.tempC ?? null,
  };
}

export interface SplitSpec {
  pace: number | ((i: number) => number);
  hr?: number | ((i: number) => number) | null;
  gain?: number | null;
}

/** 1 km splits (plus a partial one when km is fractional). */
export function splitsOf(km: number, s: SplitSpec): SplitRow[] {
  const out: SplitRow[] = [];
  const n = Math.ceil(km);
  for (let i = 0; i < n; i++) {
    const len = Math.min(1, km - i);
    const pace = typeof s.pace === 'function' ? s.pace(i) : s.pace;
    const hr = s.hr === undefined || s.hr === null ? null : typeof s.hr === 'function' ? s.hr(i) : s.hr;
    out.push({
      split: i + 1, from_distance_m: i * 1000, distance_m: len * 1000, moving_seconds: pace * len, pace_seconds_per_unit: pace, avg_hr: hr,
      elevation_gain_m: s.gain === undefined ? 0 : s.gain, partial: len < 1,
    });
  }
  return out;
}

export function raw(id: string, km: number, o: Partial<RunRaw> & { split?: SplitSpec } = {}): RunRaw {
  const split = o.split ?? { pace: 330, hr: 145, gain: 0 };
  const splits = o.splits ?? splitsOf(km, split);
  const movingSec = splits.reduce((n, s) => n + s.moving_seconds, 0);
  return {
    id, distanceSource: 'DistanceWalkingRunning', splits, hrCoverage: 1, hrUnreliable: false, decouplingPct: 3, efforts: [], movingSec, distanceM: km * 1000,
    gainPerKm: 0, halves: [movingSec / 2, movingSec / 2], rawComplete: true, ...o,
  };
}

export const effort = (distanceM: number, movingSec: number, avgHr: number | null): EffortHr => ({ distanceM, movingSec, avgHr });

export function inputs(o: Partial<ReadinessInputs> & { runs?: RunSummary[] } = {}): ReadinessInputs {
  return {
    asOf: '2024-06-29', tz: 'UTC', race: { id: 'chicago-marathon-2024', name: 'Chicago Marathon', date: '2024-07-13', daysUntil: 14 }, goalSeconds: 13_500,
    maxHr: { value: 190, source: 'user' }, sex: 'male', bodyFatPct: 14, runs: [], raw: new Map(), rawSkipped: [], taggedRaceIds: [], priorMarathon: null, priorDisabled: false,
    nutrition: { enabled: true, carbRunIds: [] }, gaps: [], notes: [], ...o,
  };
}

/**
 * A runner with `weeks` weeks of four runs per week ending on `asOf` (a Saturday-based schedule): easy runs, a mid-week run and a
 * long run whose length is `longKm(week)`. Every run is analysed from raw data unless `rawFor` says otherwise.
 */
export function trainingBlock(args: { asOf: string; weeks: number; easyPace?: number; longKm?: (w: number) => number; longPace?: number; hr?: number; rawFor?: (r: RunSummary) => boolean; idPrefix?: string }) {
  const { asOf, weeks } = args;
  const runs: RunSummary[] = [];
  const rawMap = new Map<string, RunRaw>();
  const p = args.idPrefix ?? 'r';
  for (let w = 0; w < weeks; w++) {
    const sat = addDays(asOf, -7 * (weeks - 1 - w));
    const specs: [string, number, number, number][] = [
      [addDays(sat, -5), 8, args.easyPace ?? 345, args.hr ?? 140],
      [addDays(sat, -3), 12, (args.easyPace ?? 345) - 10, (args.hr ?? 140) + 6],
      [addDays(sat, -1), 8, args.easyPace ?? 345, args.hr ?? 140],
      [sat, args.longKm ? args.longKm(w) : 22, args.longPace ?? 340, (args.hr ?? 140) + 4],
    ];
    specs.forEach(([date, km, pace, hr], i) => {
      const id = `${p}-${w}-${i}`;
      const r = run(id, date, km, pace, { hr });
      runs.push(r);
      if (!args.rawFor || args.rawFor(r)) rawMap.set(id, raw(id, km, { split: { pace, hr, gain: 2 }, gainPerKm: 2 }));
    });
  }
  return { runs, raw: rawMap };
}
