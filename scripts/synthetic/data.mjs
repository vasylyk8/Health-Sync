// Deterministic synthetic data for the monitoring user and the real-AI evals: workouts with raw
// streams (heart rate, distance, GPS) and daily context. Every value comes from simple formulas,
// so the evals know the exact right answers.
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';

/** Bump when the synthetic data changes: the seed script then replaces what is stored. */
export const DATA_VERSION = 2;
export const UID = 'synthetic-monitor';
export const TZ = 'Europe/Berlin';
const DAY = 86_400_000;
const H = 3_600_000;
const start = Date.UTC(2024, 0, 1);
const days = 366;
/** Metres per degree of latitude (matches the server's haversine). */
const M_PER_DEG = 111_194.93;

export const stepsOn = (d) => 6000 + (d % 7) * 1000; // 6000..12000
export const restingHrOn = (d) => 55 + (d % 5); // 55..59
export const isRunDay = (d) => new Date(start + d * DAY).getUTCDay() === 1; // Mondays
export const runKm = (d) => 5 + (Math.floor(d / 7) % 3); // 5, 6, 7 km
/** Minutes asleep on the night that ENDS on day d (the night starts on day d-1). */
export const sleepMinutes = (d) => 420 + ((d - 1) % 4) * 15; // 7h..7h45
export const dateOf = (d) => new Date(start + d * DAY).toISOString().slice(0, 10);
export const runId = (d) => `run-${dateOf(d)}`;

const PACE = 360; // seconds per km (6:00/km)
const HR_FIRST = 140;
const HR_SECOND = 150;

function header(type, mode, extra = {}) {
  return { kind: 'header', schema: 2, batchId: randomUUID(), type, seq: Date.now(), tz: TZ, createdAt: Date.now(), mode, checkedAt: Date.now(), ...extra };
}

/** The run of day d: 17:00 UTC, constant 6:00/km, HR 140 in the first half and 150 in the second, straight north. */
function run(d) {
  const km = runKm(d);
  const s = start + d * DAY + 17 * H;
  const total = km * PACE; // seconds
  const id = runId(d);
  const summary = {
    k: 'w', id, s, e: s + total * 1000, act: 37, actName: 'Running', dur: total, en: km * 70, dist: km * 1000, hrAvg: 145, hrMax: 150, src: 'Apple Watch', dev: 'Watch',
    stats: { HeartRate: { avg: 145, min: 140, max: 150, u: 'count/min' } },
  };
  const gen = Date.now();
  const hrT = [], hrV = [];
  for (let m = 0; m < total; m += 5) { hrT.push(s + m * 1000); hrV.push(m < total / 2 ? HR_FIRST : HR_SECOND); }
  const dT = [], dV = [];
  for (let m = 36; m <= total; m += 36) { dT.push(s + m * 1000); dV.push(100); }
  const rT = [], lat = [], lon = [], alt = [];
  for (let m = 0; m <= total; m += 6) {
    const dist = (m * 1000) / PACE;
    rT.push(s + m * 1000); lat.push(50 + dist / M_PER_DEG); lon.push(30);
    alt.push(dist < (km * 1000) / 2 ? dist * 0.01 : (km * 1000 - dist) * 0.01);
  }
  const streams = [
    header('_wstream', 'workoutdata'),
    { k: 'ws', wid: id, st: 'HeartRate', gen, u: 'count/min', t: hrT, v: hrV },
    { k: 'ws', wid: id, st: 'DistanceWalkingRunning', gen, u: 'm', t: dT, v: dV },
    { k: 'ws', wid: id, st: 'route', gen, t: rT, lat, lon, alt },
    { k: 'wd', wid: id, gen, expected: { HeartRate: hrT.length, DistanceWalkingRunning: dT.length, route: rT.length } },
  ];
  return { summary, streams };
}

/** Hourly heart rate (UTC hour h of any day): average 55 + h, minimum 5 lower, maximum 10 higher. Steps: 500 from 08:00 to 19:59 UTC. */
export const hourHr = (h) => 55 + h;
export const hourSteps = (h) => (h >= 8 && h < 20 ? 500 : 0);
/** Glucose every 5 minutes in March 2024: 90 mg/dL while a run is on (all runs start 17:00 UTC), otherwise 100. */
export const GLUCOSE_FROM = Date.UTC(2024, 2, 1);
export const GLUCOSE_TO = Date.UTC(2024, 3, 1);
export const glucoseAt = (t) => {
  const d = Math.floor((t - start) / DAY);
  const s0 = start + d * DAY + 17 * H;
  return isRunDay(d) && t >= s0 && t < s0 + runKm(d) * PACE * 1000 ? 90 : 100;
};
/** A headache entry at 08:00 UTC on every fifth day. */
export const headacheOn = (d) => d % 5 === 0;
export const SYMPTOM_ID = (d) => `sym-${String(d).padStart(4, '0')}`;
/** Categories the synthetic user has switched on (everything except medications, which is off by default). */
export const CATEGORIES = ['core', 'nutrition', 'heart', 'devices', 'mind', 'cycle', 'profile'];

// Every daily metric the phone can send (shared/coverage.json), with a simple deterministic value, so tests can
// check that each one survives the whole path and comes back out of get_daily_context unchanged.
const coveragePath = ['../../shared/coverage.json', '../../../shared/coverage.json'].map((p) => new URL(p, import.meta.url)).find((u) => existsSync(u));
const COVERAGE = JSON.parse(readFileSync(coveragePath, 'utf8'));
const NOT_NUMERIC = new Set(['sleepBedtime', 'sleepWakeTime']);
/** Daily keys by category in coverage order: keys that a metric emits (sleep, rings, state of mind) are expanded. */
export const DAILY_KEYS = (() => {
  const out = new Map(); // key -> category
  for (const m of COVERAGE.dailyMetrics) for (const k of m.outputs ?? [m.key]) if (!NOT_NUMERIC.has(k)) out.set(k, m.category ?? 'core');
  return out;
})();
const KEY_INDEX = new Map([...DAILY_KEYS.keys()].map((k, i) => [k, i]));
/** Steps, resting heart rate and sleep keep their original formulas (the real-AI evals use them). */
export function dailyValue(key, d) {
  if (key === 'steps') return stepsOn(d);
  if (key === 'restingHr') return restingHrOn(d);
  if (key === 'sleepAsleepMin') return sleepMinutes(d);
  return (KEY_INDEX.get(key) + 1) * 10 + (d % 5);
}
const DAILY_TYPE_OF = { core: '_daily', nutrition: '_daily_nutrition', cycle: '_daily_cycle', mind: '_daily_mind' };
/** Hourly HRV (SDNN) of UTC hour h: 40 + h ms. */
export const hourHrv = (h) => 40 + h;
/** Nutrition entries at 12:00 UTC every third day (a meal 5 hours before the 17:00 runs on those days that are Mondays): energy and protein. */
export const mealOn = (d) => d % 3 === 0;
export const MEAL_KCAL = (d) => 600 + (d % 7) * 50;
export const MEAL_PROTEIN = (d) => 30 + (d % 5);
/** One high heart rate alert every 20th day at 14:00 UTC. */
export const alertOn = (d) => d % 20 === 0;
export const PROFILE = { dob: '1985-06-15', sex: 'male', wheelchair: false, moveMode: 'activeEnergy' };

/** Returns the batches (arrays of JSON lines) to upload. */
export function batches() {
  const out = [];
  const runs = [];
  for (let d = 0; d < days; d++) if (isRunDay(d)) runs.push(run(d));
  out.push([header('HKWorkoutTypeIdentifier', 'anchored', { caughtUp: true }), ...runs.map((r) => r.summary)]);
  for (const r of runs) out.push(r.streams);
  // Daily rows: one daily type per category, each with the metrics of that category.
  const window = { start: start - DAY, end: Date.now() };
  for (const [type, cat] of Object.entries({ _daily: 'core', _daily_nutrition: 'nutrition', _daily_cycle: 'cycle', _daily_mind: 'mind' })) {
    const keys = [...DAILY_KEYS].filter(([, c]) => c === cat).map(([k]) => k);
    const rows = [];
    for (let d = 0; d < days; d++) rows.push({ k: 'day', day: dateOf(d), m: Object.fromEntries(keys.map((k) => [k, dailyValue(k, d)])) });
    out.push([header(type, 'stats', { window }), ...rows]);
  }

  // Hourly heart rate and steps for the whole year.
  const hT = [], hAvg = [], hLo = [], hHi = [], sT = [], sV = [], vV = [];
  for (let d = 0; d < days; d++) {
    for (let h = 0; h < 24; h++) {
      const t = start + d * DAY + h * H;
      hT.push(t); hAvg.push(hourHr(h)); hLo.push(hourHr(h) - 5); hHi.push(hourHr(h) + 10); vV.push(hourHrv(h));
      if (hourSteps(h) > 0) { sT.push(t); sV.push(hourSteps(h)); }
    }
  }
  out.push([
    header('_hourly', 'stats', { window: { start, end: start + days * DAY } }),
    { k: 'hs', st: 'HeartRate', u: 'count/min', t: hT, v: hAvg, lo: hLo, hi: hHi },
    { k: 'hs', st: 'StepCount', u: 'count', t: sT, v: sV },
    { k: 'hs', st: 'HeartRateVariabilitySDNN', u: 'ms', t: hT, v: vV },
  ]);

  // Glucose (dense, no ids) and headache entries (with ids).
  const gT = [], gV = [];
  for (let t = GLUCOSE_FROM; t < GLUCOSE_TO; t += 5 * 60_000) { gT.push(t); gV.push(glucoseAt(t)); }
  out.push([header('_events_devices', 'anchored', { caughtUp: true }), { k: 'ev', ty: 'BloodGlucose', u: 'mg/dL', src: 'Synthetic CGM', bid: 'synthetic.cgm', s: gT, v: gV }]);
  const aT = [], aId = [], aC = [];
  for (let d = 0; d < days; d++) if (headacheOn(d)) { aT.push(start + d * DAY + 8 * H); aId.push(SYMPTOM_ID(d)); aC.push(2); }
  out.push([header('_events_mind', 'anchored', { caughtUp: true }), { k: 'ev', ty: 'Headache', src: 'Health', bid: 'com.apple.Health', s: aT, c: aC, ids: aId }]);
  // Nutrition entries (energy and protein, logged together by one app) and high heart rate alerts.
  const nT = [], nE = [], nP = [];
  for (let d = 0; d < days; d++) if (mealOn(d)) { nT.push(start + d * DAY + 12 * H); nE.push(MEAL_KCAL(d)); nP.push(MEAL_PROTEIN(d)); }
  out.push([
    header('_events_nutrition', 'anchored', { caughtUp: true }),
    { k: 'ev', ty: 'DietaryEnergyConsumed', u: 'kcal', src: 'Synthetic Food Log', bid: 'synthetic.food', s: nT, v: nE },
    { k: 'ev', ty: 'DietaryProtein', u: 'g', src: 'Synthetic Food Log', bid: 'synthetic.food', s: nT, v: nP },
  ]);
  const hiT = [], hiId = [];
  for (let d = 0; d < days; d++) if (alertOn(d)) { hiT.push(start + d * DAY + 14 * H); hiId.push(`hhr-${String(d).padStart(4, '0')}`); }
  out.push([header('_events_heart', 'anchored', { caughtUp: true }), { k: 'ev', ty: 'HighHeartRateEvent', src: 'Apple Watch', bid: 'com.apple.health', s: hiT, ids: hiId }]);
  out.push([header('_events_profile', 'anchored', { caughtUp: true }), { k: 'ev', ty: 'Profile', src: 'Health', bid: 'com.apple.Health', s: [start], meta: [PROFILE] }]);
  return out;
}

const range = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => from + i);
const dayIndex = (iso) => Math.round((Date.parse(iso + 'T00:00:00Z') - start) / DAY);
const sum = (xs) => xs.reduce((a, b) => a + b, 0);

/** Questions with exact expected answers (numbers the AI's answer must contain). */
export function evalCases() {
  const march = range(dayIndex('2024-03-01'), dayIndex('2024-03-31'));
  const runsQ1 = range(0, dayIndex('2024-03-31')).filter(isRunDay);
  const juneRhr = range(dayIndex('2024-06-01'), dayIndex('2024-06-30')).map(restingHrOn);
  const mar4 = dayIndex('2024-03-04');
  const jan15 = dayIndex('2024-01-15');
  const mar4Start = Date.UTC(2024, 2, 4, 17);
  const headaches = range(dayIndex('2024-03-01'), dayIndex('2024-03-31')).filter(headacheOn);
  return [
    { q: 'How many running workouts did I do in the first quarter of 2024 (January to March)?', expect: [runsQ1.length] },
    { q: 'What total distance in km did I run in the first quarter of 2024? Round to a whole number.', expect: [sum(runsQ1.map(runKm))] },
    { q: 'For my run on 2024-03-04, how many minutes did I spend in heart rate zone 3? Assume my max heart rate is 200 bpm and the zones are 60/70/80/90% of max.', expect: [(runKm(mar4) * PACE) / 60] },
    { q: 'What was my fastest 3 km, in minutes, within my run on 2024-01-15?', expect: [(3 * PACE) / 60] },
    { q: 'By what percent did my average heart rate rise from the first half to the second half of my run on 2024-03-04? One decimal.', expect: [Math.round(((HR_SECOND - HR_FIRST) / HR_FIRST) * 1000) / 10] },
    { q: 'What was my heart rate 10 minutes into my run on 2024-01-15 (offset 600 seconds from the start)?', expect: [600 < (runKm(jan15) * PACE) / 2 ? HR_FIRST : HR_SECOND] },
    { q: 'How many steps did I take in total in March 2024?', expect: [sum(march.map(stepsOn))] },
    { q: 'What was my average resting heart rate in June 2024? Give one decimal.', expect: [Math.round((sum(juneRhr) / juneRhr.length) * 10) / 10] },
    { q: 'How many minutes did I sleep on the night ending 2024-04-10?', expect: [sleepMinutes(dayIndex('2024-04-10'))] },
    { q: 'What was my average heart rate in the hour from 14:00 to 15:00 local time (Europe/Berlin) on 2024-03-04? Use my hourly heart rate data.', expect: [hourHr(13)] },
    { q: 'How many steps did I take between 09:00 and 11:00 local time (Europe/Berlin) on 2024-03-04, hour by hour from my hourly data?', expect: [hourSteps(8) + hourSteps(9)] },
    { q: 'What was my average blood glucose in mg/dL during my run on 2024-03-04? Round to a whole number.', expect: [glucoseAt(mar4Start + 60_000)] },
    { q: 'How many headaches did I log in March 2024?', expect: [headaches.length] },
  ];
}
