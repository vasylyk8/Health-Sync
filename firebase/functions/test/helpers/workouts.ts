import { upload, type Env } from './memory.js';

export const RUN = '33333333-3333-4333-8333-333333333333';
export const T0 = Date.UTC(2024, 5, 20, 7, 0, 0);
/** Metres per degree of latitude used by the haversine implementation. */
export const M_PER_DEG = 111_194.93;

/**
 * A 30-minute run with a 60 s pause after 15 minutes: 100 m every 30 s of moving time (5:00/km,
 * 6 km), heart rate 140 in the first half and 150 in the second, straight north with a 30 m hill
 * up (first 3 km) and down (last 3 km). Everything has hand-computable answers.
 */
export async function seedRun(env: Env, opts: { wid?: string; withRaw?: boolean; gen?: number } = {}) {
  const wid = opts.wid ?? RUN;
  const gen = opts.gen ?? Date.UTC(2024, 5, 21);
  const clock = (movingS: number) => T0 + (movingS <= 900 ? movingS : movingS + 60) * 1000;
  await upload(env, { type: 'HKWorkoutTypeIdentifier', caughtUp: true }, [
    {
      k: 'w', id: wid, s: T0, e: T0 + 1860_000, act: 37, actName: 'Running', dur: 1800, en: 310.5, dist: 6000, hrAvg: 145, hrMax: 162,
      src: 'Apple Watch', bid: 'com.apple.health', dev: 'Watch7,1',
      ev: [{ t: T0 + 900_000, type: 1, dur: 60 }, { t: T0 + 960_000, type: 2, dur: 0 }, { t: T0, type: 7, dur: 300 }, { t: T0 + 300_000, type: 7, dur: 300 }],
      stats: { HeartRate: { avg: 145, min: 110, max: 162, u: 'count/min' }, ActiveEnergyBurned: { sum: 310.5, u: 'kcal' } },
      md: { HKIndoorWorkout: false, HKAverageMETs: 9.8, HKWeatherHumidity: '8100 %', HKSwimmingLocationType: true },
    },
  ]);
  if (opts.withRaw === false) return { wid, gen };

  const dist = Array.from({ length: 60 }, (_, i) => ({ t: clock(30 * (i + 1)), v: 100 }));
  const hr: { t: number; v: number }[] = [];
  const route: { t: number; d: number }[] = [];
  for (let m = 0; m <= 1800; m += 5) {
    // The reading at moving-second 900 is taken after the pause ends (second half).
    hr.push({ t: clock(m) + (m === 900 ? 60_000 : 0), v: m < 900 ? 140 : 150 });
    route.push({ t: clock(m), d: m * (100 / 30) });
  }
  const recs = [
    { k: 'ws', wid, st: 'DistanceWalkingRunning', gen, u: 'm', t: dist.map((p) => p.t), v: dist.map((p) => p.v) },
    { k: 'ws', wid, st: 'HeartRate', gen, u: 'count/min', t: hr.map((p) => p.t), v: hr.map((p) => p.v) },
    {
      k: 'ws', wid, st: 'route', gen,
      t: route.map((p) => p.t),
      lat: route.map((p) => 50 + p.d / M_PER_DEG), lon: route.map(() => 30),
      alt: route.map((p) => (p.d < 3000 ? p.d * 0.01 : (6000 - p.d) * 0.01)),
      spd: route.map(() => 3.33),
    },
    { k: 'wd', wid, gen, expected: { DistanceWalkingRunning: dist.length, HeartRate: hr.length, route: route.length } },
  ];
  await upload(env, { type: '_wstream', mode: 'workoutdata' }, recs);
  await upload(env, { type: '_daily', mode: 'stats', window: { start: 0, end: env.now } }, [
    { k: 'day', day: '2024-06-19', m: { sleepMinutes: 455, restingHr: 52, hrv: 61 } },
    { k: 'day', day: '2024-06-20', m: { sleepMinutes: 410, restingHr: 51, steps: 12034 } },
  ]);
  return { wid, gen };
}
