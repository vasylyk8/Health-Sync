/**
 * Pure calculations over raw workout streams. No I/O: everything here is tested against
 * hand-computed fixtures. Times are epoch milliseconds, distances metres, speeds m/s.
 */

export interface Pause {
  s: number;
  e: number;
}

/** HKWorkoutEventType raw values the phone sends in `ev[].type`. */
export const EVENT_NAMES: Record<number, string> = {
  1: 'pause', 2: 'resume', 3: 'lap', 4: 'marker', 5: 'motion_paused', 6: 'motion_resumed', 7: 'segment', 8: 'pause_or_resume_request',
};

export interface WorkoutEvent {
  t: number;
  type: number;
  dur?: number;
  /** Details Apple attaches to laps and segments (swim stroke style, lap length). */
  md?: Record<string, unknown>;
}

/**
 * Intervals in which the workout clock was stopped: explicit pause→resume and automatic
 * motionPaused→motionResumed. An unmatched pause lasts until `endMs`.
 */
export function pausesFromEvents(events: WorkoutEvent[] | null | undefined, endMs: number): Pause[] {
  const list = [...(events ?? [])].sort((a, b) => a.t - b.t);
  const out: Pause[] = [];
  let open: { manual: number | null; auto: number | null } = { manual: null, auto: null };
  for (const ev of list) {
    if (ev.type === 1 && open.manual === null) open.manual = ev.t;
    else if (ev.type === 2 && open.manual !== null) {
      out.push({ s: open.manual, e: ev.t });
      open = { ...open, manual: null };
    } else if (ev.type === 5 && open.auto === null) open.auto = ev.t;
    else if (ev.type === 6 && open.auto !== null) {
      out.push({ s: open.auto, e: ev.t });
      open = { ...open, auto: null };
    }
  }
  if (open.manual !== null) out.push({ s: open.manual, e: endMs });
  if (open.auto !== null) out.push({ s: open.auto, e: endMs });
  return mergePauses(out);
}

export function mergePauses(list: Pause[]): Pause[] {
  const sorted = list.filter((p) => p.e > p.s).sort((a, b) => a.s - b.s);
  const out: Pause[] = [];
  for (const p of sorted) {
    const last = out[out.length - 1];
    if (last && p.s <= last.e) last.e = Math.max(last.e, p.e);
    else out.push({ ...p });
  }
  return out;
}

/** Milliseconds of the interval [a, b) that fall inside pauses. */
export function pausedWithin(pauses: Pause[], a: number, b: number): number {
  let sum = 0;
  for (const p of pauses) {
    if (p.e <= a) continue;
    if (p.s >= b) break;
    sum += Math.min(p.e, b) - Math.max(p.s, a);
  }
  return sum;
}

/** Elapsed workout-clock milliseconds between `start` and `t` (pauses removed). */
export const movingMs = (pauses: Pause[], start: number, t: number): number => Math.max(0, t - start - pausedWithin(pauses, start, t));

/** Inverse of `movingMs`: the wall-clock time at which `target` moving milliseconds have elapsed. */
export function timeAtMoving(pauses: Pause[], start: number, target: number): number {
  let t = start + target;
  for (const p of pauses) {
    if (p.e <= start) continue;
    if (p.s >= t) break;
    t += p.e - Math.max(p.s, start);
  }
  return t;
}

// ---------------------------------------------------------------------------------------------
// Geometry

export function haversine(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6_371_008.8;
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad;
  const dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}

export interface RoutePoints {
  t: number[];
  lat: (number | null)[];
  lon: (number | null)[];
  alt?: (number | null)[];
  spd?: (number | null)[];
}

/** Cumulative distance along valid route points. Points without coordinates are skipped. */
export function routeDistance(r: RoutePoints): { idx: number[]; t: number[]; d: number[] } {
  const idx: number[] = [];
  const t: number[] = [];
  const d: number[] = [];
  let total = 0;
  let prev: [number, number] | null = null;
  for (let i = 0; i < r.t.length; i++) {
    const la = r.lat[i];
    const lo = r.lon[i];
    if (la == null || lo == null) continue;
    if (prev) total += haversine(prev[0], prev[1], la, lo);
    prev = [la, lo];
    idx.push(i);
    t.push(r.t[i]!);
    d.push(total);
  }
  return { idx, t, d };
}

export interface DistSeries {
  t: number[];
  d: number[];
}

/**
 * Cumulative distance from incremental samples (each value = metres covered up to its time `t`),
 * anchored at 0 m at `startMs`.
 */
export function distanceFromIncrements(t: number[], v: (number | null)[], startMs: number): DistSeries {
  const outT = [startMs];
  const outD = [0];
  let total = 0;
  for (let i = 0; i < t.length; i++) {
    const x = v[i];
    if (x == null || x < 0) continue;
    total += x;
    outT.push(Math.max(t[i]!, outT[outT.length - 1]!));
    outD.push(total);
  }
  return { t: outT, d: outD };
}

/** Time at which cumulative distance first reaches `target` (linear interpolation), or null. */
export function timeAtDistance(s: DistSeries, target: number): number | null {
  const n = s.d.length;
  if (n === 0 || target > s.d[n - 1]! || target < s.d[0]!) return null;
  let lo = 0;
  let hi = n - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (s.d[mid]! < target) lo = mid + 1;
    else hi = mid;
  }
  if (lo === 0) return s.t[0]!;
  const d0 = s.d[lo - 1]!;
  const d1 = s.d[lo]!;
  if (d1 === d0) return s.t[lo]!;
  return s.t[lo - 1]! + ((target - d0) / (d1 - d0)) * (s.t[lo]! - s.t[lo - 1]!);
}

/** Distance covered by time `t` (linear interpolation, clamped to the series). */
export function distanceAtTime(s: DistSeries, t: number): number {
  const n = s.t.length;
  if (n === 0) return 0;
  if (t <= s.t[0]!) return s.d[0]!;
  if (t >= s.t[n - 1]!) return s.d[n - 1]!;
  let lo = 0;
  let hi = n - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (s.t[mid]! < t) lo = mid + 1;
    else hi = mid;
  }
  const t0 = s.t[lo - 1]!;
  const t1 = s.t[lo]!;
  if (t1 === t0) return s.d[lo]!;
  return s.d[lo - 1]! + ((t - t0) / (t1 - t0)) * (s.d[lo]! - s.d[lo - 1]!);
}

// ---------------------------------------------------------------------------------------------
// Heart rate

export interface Weighted {
  /** Moving seconds this reading represents. */
  w: number;
  v: number;
  t: number;
}

export const HR_GAP_CAP_MS = 30_000;

/**
 * Each reading stands for the time until the next reading (at most `gapCapMs`), minus paused time.
 * Time not covered by a reading (gaps, missing tail) is reported by the callers as "unmeasured".
 */
export function weightReadings(t: number[], v: (number | null)[], endMs: number, pauses: Pause[], gapCapMs = HR_GAP_CAP_MS): Weighted[] {
  const out: Weighted[] = [];
  for (let i = 0; i < t.length; i++) {
    const x = v[i];
    if (x == null) continue;
    let nextT = endMs;
    for (let j = i + 1; j < t.length; j++) {
      if (v[j] != null) {
        nextT = t[j]!;
        break;
      }
    }
    const end = Math.min(nextT, t[i]! + gapCapMs, endMs);
    if (end <= t[i]!) continue;
    const w = (end - t[i]! - pausedWithin(pauses, t[i]!, end)) / 1000;
    if (w > 0) out.push({ w, v: x, t: t[i]! });
  }
  return out;
}

export interface ZoneResult {
  bounds_bpm: number[];
  zones: { zone: number; label: string; seconds: number; percent_of_measured: number }[];
  measured_seconds: number;
  unmeasured_seconds: number;
  moving_seconds: number;
}

/** `bounds` are the 4 upper limits of zones 1–4 (bpm); zone 5 is at or above the last bound. */
export function heartRateZones(readings: Weighted[], bounds: number[], movingSeconds: number): ZoneResult {
  const seconds = new Array<number>(bounds.length + 1).fill(0);
  for (const r of readings) {
    let z = 0;
    while (z < bounds.length && r.v >= bounds[z]!) z++;
    seconds[z]! += r.w;
  }
  const measured = seconds.reduce((a, b) => a + b, 0);
  const labels = bounds.map((b, i) => (i === 0 ? `below ${b} bpm` : `${bounds[i - 1]}–${b - 1} bpm`));
  labels.push(`${bounds[bounds.length - 1]} bpm and above`);
  return {
    bounds_bpm: bounds,
    zones: seconds.map((s, i) => ({ zone: i + 1, label: labels[i]!, seconds: round(s, 1), percent_of_measured: measured > 0 ? round((s / measured) * 100, 1) : 0 })),
    measured_seconds: round(measured, 1),
    unmeasured_seconds: round(Math.max(0, movingSeconds - measured), 1),
    moving_seconds: round(movingSeconds, 1),
  };
}

export function zoneBounds(args: { max_hr?: number; zones_bpm?: number[] }): { bounds: number[]; method: string } {
  if (args.zones_bpm) {
    const b = args.zones_bpm;
    if (b.length !== 4 || b.some((x, i) => !Number.isFinite(x) || x <= 0 || (i > 0 && x <= b[i - 1]!))) {
      throw new Error('zones_bpm must be 4 increasing positive numbers (upper limits of zones 1 to 4)');
    }
    return { bounds: b, method: 'custom bpm boundaries' };
  }
  if (args.max_hr === undefined) throw new Error('max_hr or zones_bpm is required');
  const m = args.max_hr;
  return { bounds: [0.6, 0.7, 0.8, 0.9].map((p) => Math.round(m * p)), method: `percent of max heart rate ${m} bpm (60/70/80/90%)` };
}

// ---------------------------------------------------------------------------------------------
// Splits, best efforts, drift

export interface SplitRow {
  split: number;
  from_distance_m: number;
  distance_m: number;
  moving_seconds: number;
  pace_seconds_per_unit: number;
  avg_hr: number | null;
  elevation_gain_m: number | null;
  partial: boolean;
}

export function meanIn(t: number[], v: (number | null)[], a: number, b: number): number | null {
  let sum = 0;
  let n = 0;
  for (let i = 0; i < t.length; i++) {
    if (t[i]! < a) continue;
    if (t[i]! >= b) break;
    const x = v[i];
    if (x == null) continue;
    sum += x;
    n++;
  }
  return n ? sum / n : null;
}

/** Positive altitude change between two times, with a small threshold against GPS noise. */
export function gainBetween(altT: number[], alt: (number | null)[], a: number, b: number, thresholdM = 2): number | null {
  let ref: number | null = null;
  let gain = 0;
  let seen = 0;
  for (let i = 0; i < altT.length; i++) {
    if (altT[i]! < a) continue;
    if (altT[i]! > b) break;
    const x = alt[i];
    if (x == null) continue;
    seen++;
    if (ref === null) ref = x;
    else if (x - ref >= thresholdM) {
      gain += x - ref;
      ref = x;
    } else if (ref - x >= thresholdM) ref = x;
  }
  return seen >= 2 ? gain : null;
}

export function splits(args: {
  dist: DistSeries;
  unitM: number;
  startMs: number;
  pauses: Pause[];
  hr?: { t: number[]; v: (number | null)[] };
  alt?: { t: number[]; v: (number | null)[] };
  minPartialFraction?: number;
}): SplitRow[] {
  const { dist, unitM, startMs, pauses } = args;
  const total = dist.d[dist.d.length - 1] ?? 0;
  const out: SplitRow[] = [];
  const minPartial = args.minPartialFraction ?? 0.1;
  for (let k = 0; k * unitM < total; k++) {
    const from = k * unitM;
    const to = Math.min((k + 1) * unitM, total);
    const len = to - from;
    if (len < unitM * minPartial && k > 0) break;
    const t0 = timeAtDistance(dist, from);
    const t1 = timeAtDistance(dist, to);
    if (t0 === null || t1 === null) break;
    const moving = (movingMs(pauses, startMs, t1) - movingMs(pauses, startMs, t0)) / 1000;
    out.push({
      split: k + 1,
      from_distance_m: round(from, 1),
      distance_m: round(len, 1),
      moving_seconds: round(moving, 1),
      pace_seconds_per_unit: len > 0 ? round((moving / len) * unitM, 1) : 0,
      avg_hr: args.hr ? round(meanIn(args.hr.t, args.hr.v, t0, t1), 1) : null,
      elevation_gain_m: args.alt ? round(gainBetween(args.alt.t, args.alt.v, t0, t1), 1) : null,
      partial: to - from < unitM - 1e-6,
    });
  }
  return out;
}

export interface Effort {
  distance_m: number;
  moving_seconds: number;
  pace_seconds_per_km: number;
  start_offset_seconds: number;
  end_offset_seconds: number;
}

/** Fastest continuous stretch of each target distance (moving time, pauses removed). */
export function bestEfforts(dist: DistSeries, targets: number[], startMs: number, pauses: Pause[]): Effort[] {
  const n = dist.t.length;
  const total = dist.d[n - 1] ?? 0;
  const out: Effort[] = [];
  for (const D of targets) {
    if (D > total || D <= 0) continue;
    let best: Effort | null = null;
    for (let i = 0; i < n; i++) {
      const dEnd = dist.d[i]! + D;
      if (dEnd > total + 1e-9) break;
      const tEnd = timeAtDistance(dist, dEnd);
      if (tEnd === null) break;
      const tStart = dist.t[i]!;
      const sec = (movingMs(pauses, startMs, tEnd) - movingMs(pauses, startMs, tStart)) / 1000;
      if (sec > 0 && (!best || sec < best.moving_seconds)) {
        best = { distance_m: D, moving_seconds: sec, pace_seconds_per_km: (sec / D) * 1000, start_offset_seconds: (tStart - startMs) / 1000, end_offset_seconds: (tEnd - startMs) / 1000 };
      }
    }
    if (best) {
      out.push({
        ...best,
        moving_seconds: round(best.moving_seconds, 1),
        pace_seconds_per_km: round(best.pace_seconds_per_km, 1),
        start_offset_seconds: round(best.start_offset_seconds, 1),
        end_offset_seconds: round(best.end_offset_seconds, 1),
      });
    }
  }
  return out;
}

export interface DriftResult {
  first_half: { avg_hr: number | null; distance_m: number | null; pace_seconds_per_km: number | null };
  second_half: { avg_hr: number | null; distance_m: number | null; pace_seconds_per_km: number | null };
  hr_change_percent: number | null;
  decoupling_percent: number | null;
  moving_seconds: number;
}

/**
 * Compares the first and second half of moving time. `decoupling_percent` is the loss of
 * speed-per-heartbeat (aerobic decoupling): positive means the second half was less efficient.
 */
export function heartRateDrift(args: { readings: Weighted[]; startMs: number; endMs: number; pauses: Pause[]; dist?: DistSeries }): DriftResult {
  const { readings, startMs, endMs, pauses, dist } = args;
  const movingTotal = movingMs(pauses, startMs, endMs);
  const half = movingTotal / 2;
  const tMid = timeAtMoving(pauses, startMs, half);
  const agg = (a: number, b: number) => {
    let w = 0;
    let s = 0;
    for (const r of readings) {
      // Each reading's weight is split at the boundary if it straddles it.
      const rStart = r.t;
      const rEnd = r.t + r.w * 1000;
      const overlap = Math.max(0, Math.min(rEnd, b) - Math.max(rStart, a)) / 1000;
      if (overlap > 0) {
        w += overlap;
        s += overlap * r.v;
      }
    }
    return w > 0 ? s / w : null;
  };
  const hr1 = agg(startMs, tMid);
  const hr2 = agg(tMid, endMs);
  const d1 = dist ? distanceAtTime(dist, tMid) - distanceAtTime(dist, startMs) : null;
  const d2 = dist ? distanceAtTime(dist, endMs) - distanceAtTime(dist, tMid) : null;
  const sec1 = (movingMs(pauses, startMs, tMid)) / 1000;
  const sec2 = (movingMs(pauses, startMs, endMs) - movingMs(pauses, startMs, tMid)) / 1000;
  const pace = (d: number | null, s: number) => (d && d > 0 ? (s / d) * 1000 : null);
  const speed1 = d1 && sec1 > 0 ? d1 / sec1 : null;
  const speed2 = d2 && sec2 > 0 ? d2 / sec2 : null;
  const ef1 = speed1 && hr1 ? speed1 / hr1 : null;
  const ef2 = speed2 && hr2 ? speed2 / hr2 : null;
  return {
    first_half: { avg_hr: round(hr1, 1), distance_m: round(d1, 1), pace_seconds_per_km: round(pace(d1, sec1), 1) },
    second_half: { avg_hr: round(hr2, 1), distance_m: round(d2, 1), pace_seconds_per_km: round(pace(d2, sec2), 1) },
    hr_change_percent: hr1 && hr2 ? round(((hr2 - hr1) / hr1) * 100, 1) : null,
    decoupling_percent: ef1 && ef2 ? round(((ef1 - ef2) / ef1) * 100, 1) : null,
    moving_seconds: round(movingTotal / 1000, 1),
  };
}

// ---------------------------------------------------------------------------------------------
// Elevation

export interface ElevationResult {
  gain_m: number;
  loss_m: number;
  min_m: number;
  max_m: number;
  start_m: number;
  end_m: number;
  steepest_climb_percent: number | null;
  steepest_descent_percent: number | null;
  share_uphill_percent: number | null;
  share_flat_percent: number | null;
  share_downhill_percent: number | null;
  profile: { distance_m: number; altitude_m: number }[];
}

const smooth = (a: number[], w = 5): number[] =>
  a.map((_, i) => {
    const lo = Math.max(0, i - (w >> 1));
    const hi = Math.min(a.length - 1, i + (w >> 1));
    let s = 0;
    for (let j = lo; j <= hi; j++) s += a[j]!;
    return s / (hi - lo + 1);
  });

export function elevationProfile(route: RoutePoints, profilePoints = 20, thresholdM = 2, gradeWindowM = 100): ElevationResult | null {
  const rd = routeDistance(route);
  const pts: { d: number; a: number }[] = [];
  rd.idx.forEach((ri, k) => {
    const a = route.alt?.[ri];
    if (a != null) pts.push({ d: rd.d[k]!, a });
  });
  if (pts.length < 2) return null;
  const alts = smooth(pts.map((p) => p.a));
  let ref = alts[0]!;
  let gain = 0;
  let loss = 0;
  for (const a of alts) {
    if (a - ref >= thresholdM) {
      gain += a - ref;
      ref = a;
    } else if (ref - a >= thresholdM) {
      loss += ref - a;
      ref = a;
    }
  }
  // Grade over windows of at least `gradeWindowM`.
  let up = 0;
  let down = 0;
  let flat = 0;
  let steepUp: number | null = null;
  let steepDown: number | null = null;
  let anchor = 0;
  for (let i = 1; i < pts.length; i++) {
    const dd = pts[i]!.d - pts[anchor]!.d;
    if (dd < gradeWindowM) continue;
    const grade = ((alts[i]! - alts[anchor]!) / dd) * 100;
    if (grade > 2) up += dd;
    else if (grade < -2) down += dd;
    else flat += dd;
    steepUp = steepUp === null ? grade : Math.max(steepUp, grade);
    steepDown = steepDown === null ? grade : Math.min(steepDown, grade);
    anchor = i;
  }
  const measured = up + down + flat;
  const totalD = pts[pts.length - 1]!.d;
  const profile: ElevationResult['profile'] = [];
  for (let k = 0; k < Math.min(profilePoints, pts.length); k++) {
    const i = Math.round((k / Math.max(1, Math.min(profilePoints, pts.length) - 1)) * (pts.length - 1));
    profile.push({ distance_m: round(pts[i]!.d, 0), altitude_m: round(alts[i]!, 1) });
  }
  void totalD;
  return {
    gain_m: round(gain, 1)!,
    loss_m: round(loss, 1)!,
    min_m: round(Math.min(...alts), 1)!,
    max_m: round(Math.max(...alts), 1)!,
    start_m: round(alts[0]!, 1)!,
    end_m: round(alts[alts.length - 1]!, 1)!,
    steepest_climb_percent: steepUp !== null && steepUp > 0 ? round(steepUp, 1) : null,
    steepest_descent_percent: steepDown !== null && steepDown < 0 ? round(steepDown, 1) : null,
    share_uphill_percent: measured > 0 ? round((up / measured) * 100, 1) : null,
    share_flat_percent: measured > 0 ? round((flat / measured) * 100, 1) : null,
    share_downhill_percent: measured > 0 ? round((down / measured) * 100, 1) : null,
    profile,
  };
}

// ---------------------------------------------------------------------------------------------
// Privacy trimming and thinning

/**
 * Hides the first and last `trimM` metres of a route (home/work). Returns the kept point indexes,
 * or `null` if the route is too short to show anything without revealing its ends.
 */
export function trimRouteIndexes(r: RoutePoints, trimM: number): { keep: number[]; total_m: number } | null {
  const rd = routeDistance(r);
  const total = rd.d[rd.d.length - 1] ?? 0;
  const keep: number[] = [];
  rd.idx.forEach((ri, k) => {
    if (rd.d[k]! >= trimM && total - rd.d[k]! >= trimM) keep.push(ri);
  });
  return keep.length ? { keep, total_m: total } : null;
}

/** Evenly thins a list of indexes to at most `max`, always keeping the first and last. */
export function thin<T>(items: T[], max: number): T[] {
  if (items.length <= max) return items;
  const out: T[] = [];
  for (let k = 0; k < max; k++) out.push(items[Math.round((k * (items.length - 1)) / (max - 1))]!);
  return out;
}

export function round(x: number, digits: number): number;
export function round(x: number | null, digits: number): number | null;
export function round(x: number | null, digits: number): number | null {
  return x === null || !Number.isFinite(x) ? null : Math.round(x * 10 ** digits) / 10 ** digits;
}
