// Deterministic synthetic data for the monitoring user and the real-AI evals: workouts with raw
// streams (heart rate, distance, GPS) and daily context. Every value comes from simple formulas,
// so the evals know the exact right answers.
import { randomUUID } from 'node:crypto';

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

/** Returns the batches (arrays of JSON lines) to upload. */
export function batches() {
  const out = [];
  const runs = [];
  for (let d = 0; d < days; d++) if (isRunDay(d)) runs.push(run(d));
  out.push([header('HKWorkoutTypeIdentifier', 'anchored', { caughtUp: true }), ...runs.map((r) => r.summary)]);
  for (const r of runs) out.push(r.streams);
  const rows = [];
  for (let d = 0; d < days; d++) {
    rows.push({ k: 'day', day: dateOf(d), m: { steps: stepsOn(d), restingHr: restingHrOn(d), sleepAsleepMin: sleepMinutes(d) } });
  }
  out.push([header('_daily', 'stats', { window: { start: start - DAY, end: Date.now() } }), ...rows]);
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
  ];
}
