import { addDays } from '../../src/readiness/features.js';
import { upload, type Env } from './memory.js';
import { M_PER_DEG } from './workouts.js';

/** Seeds running workouts (summary rows plus optional raw streams) through the real ingest code, for readiness tests. */

export interface RunSeed {
  id: string;
  /** Start, ISO UTC. */
  start: string;
  km: number;
  /** Seconds per km: constant, or a function of the kilometre index. */
  pace: number | ((kmIndex: number) => number);
  /** Heart rate: constant, or a function of the kilometre index. Null for no heart-rate stream. */
  hr: number | ((kmIndex: number) => number) | null;
  /** Elevation gain, metres per km. */
  gain?: number;
  indoor?: boolean;
  /** Apple's workout temperature text, e.g. "20 degC". */
  temp?: string;
  /** Upload raw streams (default true). */
  raw?: boolean;
  src?: string;
  hrMax?: number;
}

const GEN = Date.UTC(2024, 5, 21);

const paceAt = (s: RunSeed, kmIndex: number) => (typeof s.pace === 'function' ? s.pace(kmIndex) : s.pace);
const hrAt = (s: RunSeed, kmIndex: number) => (s.hr === null ? null : typeof s.hr === 'function' ? s.hr(kmIndex) : s.hr);

/** Elapsed seconds of a run with per-kilometre paces. */
export function elapsedSeconds(s: RunSeed): number {
  let sec = 0;
  for (let k = 0; k < Math.ceil(s.km); k++) sec += paceAt(s, k) * Math.min(1, s.km - k);
  return sec;
}

/** Position (metres) at an elapsed time, following the per-kilometre pace. */
function distanceAt(s: RunSeed, tSec: number): number {
  let d = 0;
  let t = 0;
  for (let k = 0; k < Math.ceil(s.km); k++) {
    const len = Math.min(1, s.km - k);
    const dt = paceAt(s, k) * len;
    if (t + dt >= tSec) return d + ((tSec - t) / dt) * len * 1000;
    t += dt;
    d += len * 1000;
  }
  return s.km * 1000;
}

function streams(s: RunSeed, wid: string, startMs: number) {
  const total = elapsedSeconds(s);
  const dist = { t: [] as number[], v: [] as number[] };
  let prev = 0;
  for (let t = 30; ; t += 30) {
    const at = Math.min(t, total);
    const d = distanceAt(s, at);
    dist.t.push(startMs + at * 1000);
    dist.v.push(d - prev);
    prev = d;
    if (at >= total) break;
  }
  const hr = { t: [] as number[], v: [] as number[] };
  const route = { t: [] as number[], lat: [] as number[], lon: [] as number[], alt: [] as number[], spd: [] as number[] };
  for (let t = 0; t <= total; t += 10) {
    const d = distanceAt(s, t);
    const k = Math.min(Math.floor(d / 1000), Math.ceil(s.km) - 1);
    const h = hrAt(s, k);
    if (h !== null) {
      hr.t.push(startMs + t * 1000);
      hr.v.push(Math.round(h));
    }
    route.t.push(startMs + t * 1000);
    route.lat.push(50 + d / M_PER_DEG);
    route.lon.push(30);
    route.alt.push(100 + ((s.gain ?? 0) * d) / 1000);
    route.spd.push(1000 / paceAt(s, k));
  }
  const recs: object[] = [{ k: 'ws', wid, st: 'DistanceWalkingRunning', gen: GEN, u: 'm', t: dist.t, v: dist.v }];
  if (hr.t.length) recs.push({ k: 'ws', wid, st: 'HeartRate', gen: GEN, u: 'count/min', t: hr.t, v: hr.v });
  if (!s.indoor) recs.push({ k: 'ws', wid, st: 'route', gen: GEN, t: route.t, lat: route.lat, lon: route.lon, alt: route.alt, spd: route.spd });
  recs.push({ k: 'wd', wid, gen: GEN, expected: Object.fromEntries(recs.filter((r) => (r as { k: string }).k === 'ws').map((r) => [(r as { st: string }).st, (r as { t: number[] }).t.length])) });
  return recs;
}

export async function seedRuns(env: Env, seeds: RunSeed[]): Promise<void> {
  const summaries = seeds.map((s) => {
    const startMs = Date.parse(s.start);
    const dur = elapsedSeconds(s);
    const hrs = Array.from({ length: Math.ceil(s.km) }, (_, k) => hrAt(s, k)).filter((x): x is number => x !== null);
    return {
      k: 'w', id: s.id, s: startMs, e: startMs + dur * 1000, act: 37, actName: 'Running', dur, en: dur * 0.2, dist: s.km * 1000,
      ...(hrs.length ? { hrAvg: hrs.reduce((a, b) => a + b, 0) / hrs.length, hrMax: s.hrMax ?? Math.max(...hrs) + 4 } : {}),
      src: s.src ?? 'Apple Watch', bid: 'com.apple.health', dev: 'Watch7,1',
      md: { HKIndoorWorkout: s.indoor ?? false, ...(s.temp ? { HKWeatherTemperature: s.temp } : {}) },
    };
  });
  await upload(env, { type: 'HKWorkoutTypeIdentifier', caughtUp: true }, summaries);
  const withRaw = seeds.filter((s) => s.raw !== false);
  for (let i = 0; i < withRaw.length; i += 6) {
    const recs = withRaw.slice(i, i + 6).flatMap((s) => streams(s, s.id, Date.parse(s.start)));
    await upload(env, { type: '_wstream', mode: 'workoutdata' }, recs);
  }
}

/** ISO start of a run on a local date (UTC); time is HH:MM or HH:MM:SS. */
export const at = (date: string, time = '07:00'): string => `${date}T${time.length === 5 ? time + ':00' : time}Z`;

export const LONG_KM = [18, 20, 22, 24, 26, 28, 30, 24, 32, 32, 24, 16];

/** A runner with 12 weeks of training ending on `asOf` (a Saturday) and a half-marathon race 22 days earlier (a Friday, so it overlaps no other run). */
export function runnerSeeds(asOf: string, hmId: string): RunSeed[] {
  const seeds: RunSeed[] = [];
  LONG_KM.forEach((km, w) => {
    const sat = addDays(asOf, -7 * (LONG_KM.length - 1 - w));
    seeds.push({ id: `easy-${w}-a1`, start: at(addDays(sat, -4)), km: 10, pace: 345, hr: 140, raw: false });
    seeds.push({ id: `easy-${w}-b2`, start: at(addDays(sat, -2)), km: 10, pace: 335, hr: 146, raw: false });
    seeds.push({ id: `easy-${w}-c3`, start: at(addDays(sat, -1)), km: 10, pace: 345, hr: 140, raw: false });
    // Long run: easy, with the last 10 km at goal pace (322 s/km) when it is 28 km or more.
    seeds.push({ id: `long-${w}-run`, start: at(sat), km, pace: (k) => (km >= 28 && k >= km - 10 ? 322 : 340), hr: (k) => (km >= 28 && k >= km - 10 ? 163 : 145) + (k % 4), gain: 2 });
  });
  // Half-marathon race three weeks before as_of: constant 4:55/km, average HR 176.
  seeds.push({ id: hmId, start: at(addDays(asOf, -22), '09:00'), km: 21.2, pace: 295, hr: (k) => 174 + (k % 5), gain: 1 });
  return seeds;
}

