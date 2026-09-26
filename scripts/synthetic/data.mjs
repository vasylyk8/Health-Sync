// Deterministic synthetic Health data for the monitoring user and the real-AI evals.
// Every value is derived from simple formulas so the evals know the exact right answers.
import { randomUUID } from 'node:crypto';

export const UID = 'synthetic-monitor';
export const TZ = 'Europe/Berlin';
const DAY = 86_400_000;
const H = 3_600_000;
// 2024 calendar year in Berlin; timestamps built in UTC with a fixed +1h/+2h offset handled by
// using local noon-ish times far from midnight, so day attribution is unambiguous.
const start = Date.UTC(2024, 0, 1);
const days = 366;

export const stepsOn = (d) => 6000 + (d % 7) * 1000; // 6000..12000
export const restingHrOn = (d) => 55 + (d % 5); // 55..59
export const isRunDay = (d) => new Date(start + d * DAY).getUTCDay() === 1; // Mondays
export const runKm = (d) => 5 + (Math.floor(d / 7) % 3); // 5, 6, 7 km
export const sleepMinutes = (d) => 420 + (d % 4) * 15; // 7h..7h45

function header(type, mode, extra = {}) {
  return { kind: 'header', schema: 1, batchId: randomUUID(), type, seq: Date.now(), tz: TZ, createdAt: Date.now(), mode, checkedAt: Date.now(), ...extra };
}

/** Returns the batches (arrays of JSON lines) to upload. */
export function batches() {
  const out = [];
  const window = { start: start - DAY, end: Date.now() };
  // Steps: one sample per day at 10:00 UTC plus matching merged hourly stats.
  const steps = [], stepStats = [];
  for (let d = 0; d < days; d++) {
    const t = start + d * DAY + 10 * H;
    steps.push({ k: 's', id: `steps-${d}`, s: t, e: t + H, v: stepsOn(d), u: 'count', src: 'Apple Watch', dev: 'Watch' });
    stepStats.push({ k: 'h', s: t, e: t + H, agg: 'sum', v: stepsOn(d), u: 'count' });
  }
  out.push([header('HKQuantityTypeIdentifierStepCount', 'anchored', { caughtUp: true }), ...steps]);
  out.push([header('HKQuantityTypeIdentifierStepCount', 'stats', { window }), ...stepStats]);
  // Resting heart rate: one per day at 08:00 UTC.
  const rhr = [];
  for (let d = 0; d < days; d++) rhr.push({ k: 's', id: `rhr-${d}`, s: start + d * DAY + 8 * H, e: start + d * DAY + 8 * H, v: restingHrOn(d), u: 'count/min', src: 'Apple Watch' });
  out.push([header('HKQuantityTypeIdentifierRestingHeartRate', 'anchored', { caughtUp: true }), ...rhr]);
  // Running workouts on Mondays at 17:00 UTC, 6 min/km.
  const runs = [];
  for (let d = 0; d < days; d++) {
    if (!isRunDay(d)) continue;
    const s = start + d * DAY + 17 * H, km = runKm(d);
    runs.push({ k: 'w', id: `run-${d}`, s, e: s + km * 6 * 60_000, act: 37, actName: 'Running', dur: km * 360, en: km * 70, dist: km * 1000, src: 'Apple Watch' });
  }
  out.push([header('HKWorkoutTypeIdentifier', 'anchored', { caughtUp: true }), ...runs]);
  // Sleep: core sleep from 22:00 UTC for sleepMinutes(d), ending on day d+1.
  const sleep = [];
  for (let d = 0; d < days - 1; d++) {
    const s = start + d * DAY + 22 * H;
    sleep.push({ k: 's', id: `sleep-${d}`, s, e: s + sleepMinutes(d) * 60_000, c: 3, src: 'Apple Watch' });
  }
  out.push([header('HKCategoryTypeIdentifierSleepAnalysis', 'anchored', { caughtUp: true }), ...sleep]);
  out.push([header('_profile', 'profile'), { k: 'p', dob: '1990-01-01', sex: 'female', blood: 'O+' }]);
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
  return [
    { q: 'How many steps did I take in total in March 2024?', expect: [sum(march.map(stepsOn))] },
    { q: 'How many running workouts did I do in the first quarter of 2024 (January to March)?', expect: [runsQ1.length] },
    { q: 'What total distance in km did I run in the first quarter of 2024? Round to a whole number.', expect: [sum(runsQ1.map(runKm))] },
    { q: 'What was my average resting heart rate in June 2024? Give one decimal.', expect: [Math.round((sum(juneRhr) / juneRhr.length) * 10) / 10] },
    { q: 'How many minutes did I sleep on the night ending 2024-04-10?', expect: [sleepMinutes(dayIndex('2024-04-09'))] },
    { q: 'How old am I? (today, using my date of birth)', expect: [new Date().getUTCFullYear() - 1990 - (new Date().getUTCMonth() === 0 && new Date().getUTCDate() < 1 ? 1 : 0)] },
  ];
}
