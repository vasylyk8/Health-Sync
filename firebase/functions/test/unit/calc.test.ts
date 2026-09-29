import { describe, expect, it } from 'vitest';
import {
  bestEfforts, distanceFromIncrements, elevationProfile, haversine, heartRateDrift, heartRateZones, movingMs,
  pausesFromEvents, routeDistance, splits, thin, timeAtDistance, timeAtMoving, trimRouteIndexes, weightReadings, zoneBounds,
} from '../../src/query/calc.js';

const T0 = Date.UTC(2024, 5, 20, 7, 0, 0);
const sec = (s: number) => T0 + s * 1000;

/** 3000 m in 900 s: 100 m every 30 s (5:00 per km). */
const steady = () => {
  const t = Array.from({ length: 30 }, (_, i) => sec(30 * (i + 1)));
  return distanceFromIncrements(t, t.map(() => 100), T0);
};

describe('geometry', () => {
  it('0.001 degrees of latitude is about 111.2 m', () => {
    expect(haversine(50, 30, 50.001, 30)).toBeCloseTo(111.195, 2);
  });
  it('interpolates time at distance', () => {
    const d = steady();
    expect(timeAtDistance(d, 1000)).toBe(sec(300));
    expect(timeAtDistance(d, 1050)).toBe(sec(315));
    expect(timeAtDistance(d, 3001)).toBeNull();
  });
});

describe('pauses', () => {
  it('pairs pause/resume and auto-pause events; an open pause runs to the end', () => {
    const p = pausesFromEvents([{ t: sec(100), type: 1 }, { t: sec(160), type: 2 }, { t: sec(300), type: 5 }, { t: sec(330), type: 6 }, { t: sec(800), type: 1 }], sec(900));
    expect(p).toEqual([{ s: sec(100), e: sec(160) }, { s: sec(300), e: sec(330) }, { s: sec(800), e: sec(900) }]);
    expect(movingMs(p, T0, sec(900))).toBe((900 - 60 - 30 - 100) * 1000);
    expect(timeAtMoving(p, T0, 100_000)).toBe(sec(100)); // the clock reaches 100 s the moment the pause starts
    expect(timeAtMoving(p, T0, 110_000)).toBe(sec(170));
  });
});

describe('splits and best efforts', () => {
  it('constant 5:00/km gives 300 s kilometres and exact best efforts', () => {
    const rows = splits({ dist: steady(), unitM: 1000, startMs: T0, pauses: [] });
    expect(rows.map((r) => r.moving_seconds)).toEqual([300, 300, 300]);
    expect(rows.map((r) => r.pace_seconds_per_unit)).toEqual([300, 300, 300]);
    expect(rows.some((r) => r.partial)).toBe(false);
    const be = bestEfforts(steady(), [1000, 3000, 5000], T0, []);
    expect(be.map((b) => [b.distance_m, b.moving_seconds])).toEqual([[1000, 300], [3000, 900]]); // 5 km is longer than the run
    expect(be[0]!.pace_seconds_per_km).toBe(300);
  });

  it('finds the fast stretch inside a slower run', () => {
    // 100 m per 30 s, except metres 1000–2000 which take 240 s per km (24 s per 100 m)
    const t: number[] = [];
    const v: number[] = [];
    let clock = 0;
    for (let i = 0; i < 30; i++) {
      clock += i >= 10 && i < 20 ? 24 : 30;
      t.push(sec(clock));
      v.push(100);
    }
    const d = distanceFromIncrements(t, v, T0);
    const [best] = bestEfforts(d, [1000], T0, []);
    expect(best!.moving_seconds).toBe(240);
    expect(best!.start_offset_seconds).toBe(300);
  });

  it('removes paused time from splits', () => {
    // steady run, but 150 s standing still between 450 s and 600 s
    const t: number[] = [];
    const v: number[] = [];
    for (let i = 1; i <= 30; i++) {
      const moving = 30 * i;
      const clock = moving <= 450 ? moving : moving + 150;
      t.push(sec(clock));
      v.push(100);
    }
    const d = distanceFromIncrements(t, v, T0);
    const pauses = pausesFromEvents([{ t: sec(450), type: 1 }, { t: sec(600), type: 2 }], sec(1050));
    const rows = splits({ dist: d, unitM: 1000, startMs: T0, pauses });
    expect(rows.map((r) => r.moving_seconds)).toEqual([300, 300, 300]);
  });

  it('reports a trailing partial split and drops tiny remainders', () => {
    const t = [sec(300), sec(600), sec(690)];
    const d = distanceFromIncrements(t, [1000, 1000, 300], T0); // 2300 m
    const rows = splits({ dist: d, unitM: 1000, startMs: T0, pauses: [] });
    expect(rows).toHaveLength(3);
    expect(rows[2]).toMatchObject({ partial: true, distance_m: 300, moving_seconds: 90, pace_seconds_per_unit: 300 });
    const tiny = distanceFromIncrements([sec(300), sec(600), sec(610)], [1000, 1000, 20], T0);
    expect(splits({ dist: tiny, unitM: 1000, startMs: T0, pauses: [] })).toHaveLength(2);
  });

  it('adds average HR per split', () => {
    const hrT = Array.from({ length: 180 }, (_, i) => sec(i * 5));
    const hrV = hrT.map((_, i) => (i < 60 ? 140 : i < 120 ? 150 : 160));
    const rows = splits({ dist: steady(), unitM: 1000, startMs: T0, pauses: [], hr: { t: hrT, v: hrV } });
    expect(rows.map((r) => r.avg_hr)).toEqual([140, 150, 160]);
  });
});

describe('heart rate zones', () => {
  it('bounds from max HR or custom, validated', () => {
    expect(zoneBounds({ max_hr: 200 }).bounds).toEqual([120, 140, 160, 180]);
    expect(zoneBounds({ zones_bpm: [110, 130, 150, 170] }).bounds).toEqual([110, 130, 150, 170]);
    expect(() => zoneBounds({})).toThrow();
    expect(() => zoneBounds({ zones_bpm: [130, 110, 150, 170] })).toThrow();
  });

  it('counts exact seconds per zone', () => {
    const t = Array.from({ length: 120 }, (_, i) => sec(i * 5));
    const v = t.map((_, i) => (i < 60 ? 100 : 150));
    const r = heartRateZones(weightReadings(t, v, sec(600), []), [120, 140, 160, 180], 600);
    expect(r.zones.map((z) => z.seconds)).toEqual([300, 0, 300, 0, 0]);
    expect(r.unmeasured_seconds).toBe(0);
    expect(r.zones[0]!.percent_of_measured).toBe(50);
  });

  it('caps long gaps and reports them as unmeasured; excludes paused time', () => {
    // readings at 0 s and 60 s, workout ends at 90 s: each reading covers at most 30 s
    const r = heartRateZones(weightReadings([sec(0), sec(60)], [100, 100], sec(90), []), [120, 140, 160, 180], 90);
    expect(r.measured_seconds).toBe(60);
    expect(r.unmeasured_seconds).toBe(30);
    // pause 10–20 s inside a single 30 s reading
    const p = pausesFromEvents([{ t: sec(10), type: 1 }, { t: sec(20), type: 2 }], sec(30));
    const w = weightReadings([sec(0)], [100], sec(30), p);
    expect(w[0]!.w).toBe(20);
  });
});

describe('heart rate drift', () => {
  it('compares halves and computes decoupling', () => {
    const t = Array.from({ length: 180 }, (_, i) => sec(i * 5));
    const v = t.map((_, i) => (i < 90 ? 140 : 150));
    const r = heartRateDrift({ readings: weightReadings(t, v, sec(900), []), startMs: T0, endMs: sec(900), pauses: [], dist: steady() });
    expect(r.first_half.avg_hr).toBe(140);
    expect(r.second_half.avg_hr).toBe(150);
    expect(r.hr_change_percent).toBe(7.1);
    expect(r.decoupling_percent).toBe(6.7);
    expect(r.first_half.pace_seconds_per_km).toBe(300);
  });
});

describe('route and elevation', () => {
  const N = 200;
  const route = {
    t: Array.from({ length: N }, (_, i) => sec(i)),
    lat: Array.from({ length: N }, (_, i) => 50 + i * 0.0001),
    lon: Array.from({ length: N }, () => 30),
    alt: Array.from({ length: N }, (_, i) => (i < 100 ? i * 0.5 : (N - 1 - i) * 0.5 * (49.5 / 49.5))),
  };

  it('measures route distance', () => {
    const rd = routeDistance(route);
    expect(rd.d[N - 1]).toBeCloseTo(199 * 11.1195, 0);
  });

  it('trims the first and last 300 m', () => {
    const k = trimRouteIndexes(route, 300)!;
    expect(k.keep[0]).toBe(27);
    expect(k.keep[k.keep.length - 1]).toBe(172);
    expect(trimRouteIndexes({ t: [1, 2], lat: [50, 50.0001], lon: [30, 30] }, 300)).toBeNull();
  });

  it('computes gain, loss and grade', () => {
    const e = elevationProfile(route)!;
    expect(e.gain_m).toBeGreaterThan(46);
    expect(e.gain_m).toBeLessThanOrEqual(50);
    expect(e.loss_m).toBeGreaterThan(46);
    expect(e.max_m).toBeCloseTo(49.5, 0);
    expect(e.min_m).toBeCloseTo(0.2, 0);
    // 0.5 m per 11.12 m = 4.5 % grade both ways
    expect(e.steepest_climb_percent).toBeGreaterThan(4);
    expect(e.steepest_descent_percent).toBeLessThan(-4);
    expect(e.share_flat_percent!).toBeLessThan(15);
    expect(e.profile).toHaveLength(20);
  });

  it('returns null without altitude', () => {
    expect(elevationProfile({ ...route, alt: route.t.map(() => null) })).toBeNull();
  });
});

describe('thin', () => {
  it('keeps the ends and the requested count', () => {
    const a = Array.from({ length: 1000 }, (_, i) => i);
    const t = thin(a, 10);
    expect(t).toHaveLength(10);
    expect(t[0]).toBe(0);
    expect(t[9]).toBe(999);
    expect(thin([1, 2, 3], 10)).toEqual([1, 2, 3]);
  });
});
