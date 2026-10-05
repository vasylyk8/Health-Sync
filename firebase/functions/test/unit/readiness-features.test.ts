import { describe, expect, it } from 'vitest';
import { READINESS_CONFIG as cfg } from '../../src/readiness/config.js';
import {
  addDays, addMonths, avgWeeklyKm, cleanSplits, countRunsAtLeast, cv, daysBetween, detectPriorMarathon, findDuplicateGroups, hms, longestGapDays, median, normalCdf, resolveMaxHr, runSummary, tempCelsius, weeksWithRuns, weekStart, windowStart,
} from '../../src/readiness/features.js';
import { toWorkoutRow } from '../../src/query/lookup.js';
import { run, splitsOf } from '../helpers/readiness.js';

describe('local-date helpers', () => {
  it('adds days and months without rolling over', () => {
    expect(addDays('2024-02-28', 2)).toBe('2024-03-01');
    expect(addMonths('2024-01-31', 1)).toBe('2024-02-29');
    expect(addMonths('2024-03-31', -1)).toBe('2024-02-29');
    expect(addMonths('2026-10-04', -36)).toBe('2023-10-04');
    expect(daysBetween('2024-06-29', '2024-07-13')).toBe(14);
  });
  it('finds the Monday of a week and an inclusive window', () => {
    expect(weekStart('2024-06-30')).toBe('2024-06-24'); // Sunday
    expect(weekStart('2024-06-24')).toBe('2024-06-24');
    expect(windowStart('2024-06-30', 1)).toBe('2024-06-24');
    expect(windowStart('2024-06-30', 16)).toBe('2024-03-11');
  });
  it('formats seconds without printing :60', () => {
    expect(hms(10_796.7)).toBe('2:59:57');
    expect(hms(3599.6)).toBe('1:00:00');
  });
});

describe('statistics', () => {
  it('median, coefficient of variation and the normal distribution', () => {
    expect(median([5, 1, 3])).toBe(3);
    expect(median([4, 1, 3, 2])).toBe(2.5);
    expect(median([])).toBeNull();
    expect(cv([10, 10, 10])).toBe(0);
    expect(cv([8, 12])).toBeCloseTo(Math.SQRT2 * 2 / 10, 6);
    expect(normalCdf(0)).toBeCloseTo(0.5, 7);
    expect(normalCdf(1)).toBeCloseTo(0.8413447, 6);
    expect(normalCdf(-1)).toBeCloseTo(0.1586553, 6);
    expect(normalCdf(1.2816)).toBeCloseTo(0.9, 4);
    expect(normalCdf(-1.96)).toBeCloseTo(0.025, 4);
  });
});

describe('run summaries', () => {
  const row = (extra: Record<string, unknown>) => toWorkoutRow({ id: 'abcdefgh', s: Date.UTC(2024, 5, 20, 7), e: Date.UTC(2024, 5, 20, 8), src: 'Apple Watch', bid: null, dev: null, extra: JSON.stringify(extra), start_local: '2024-06-20 07:00', end_local: '2024-06-20 08:00' });

  it('reads distance, duration, heart rate, treadmill flag and temperature from Apple\'s summary', () => {
    const r = runSummary(row({ actName: 'Running', dist: 10_000, dur: 3000, hrAvg: 151, hrMax: 178, md: { HKIndoorWorkout: false, HKWeatherTemperature: '68 degF' } }));
    expect(r).toMatchObject({ id: 'abcdefgh', date: '2024-06-20', distanceM: 10_000, movingSec: 3000, avgHr: 151, maxHr: 178, indoor: false });
    expect(r.tempC).toBeCloseTo(20, 5);
    expect(runSummary(row({ md: { HKIndoorWorkout: true } })).indoor).toBe(true);
    expect(runSummary(row({ dist: 0, hrAvg: 0 }))).toMatchObject({ distanceM: null, avgHr: null });
  });
  it('parses weather temperatures', () => {
    expect(tempCelsius({ HKWeatherTemperature: '24 degC' })).toBe(24);
    expect(tempCelsius({ HKWeatherTemperature: 'warm' })).toBeNull();
    expect(tempCelsius(null)).toBeNull();
  });
});

describe('duplicates', () => {
  it('groups a watch and a phone recording of the same run, not back-to-back runs', () => {
    const a = run('aaaaaaaa', '2024-06-20', 10, 300);
    const b = { ...run('bbbbbbbb', '2024-06-20', 9.9, 303), startMs: a.startMs + 20_000, endMs: a.endMs + 15_000 };
    const later = { ...run('cccccccc', '2024-06-20', 5, 330), startMs: a.endMs + 3_600_000, endMs: a.endMs + 3_600_000 + 1_650_000 };
    const groups = findDuplicateGroups([later, b, a], cfg.detect.duplicateOverlapFraction);
    expect(groups.map((g) => g.map((r) => r.id).sort())).toEqual([['aaaaaaaa', 'bbbbbbbb']]);
    expect(findDuplicateGroups([a, later], 0.5)).toEqual([]);
  });
});

describe('volume and continuity', () => {
  const runs = [run('a', '2024-06-29', 30, 330), run('b', '2024-06-22', 32, 330), run('c', '2024-06-15', 10, 330), run('d', '2024-04-01', 20, 330), run('e', '2024-03-01', 50, 330)];
  it('averages weekly km over the window and counts long runs', () => {
    expect(avgWeeklyKm(runs, '2024-06-29', 4)).toBeCloseTo(18, 6); // 72 km in 4 weeks
    expect(countRunsAtLeast(runs, 30, '2024-06-02', '2024-06-29')).toBe(2);
  });
  it('counts weeks with runs and the longest gap', () => {
    expect(weeksWithRuns(runs, '2024-06-02', '2024-06-29')).toBe(3);
    expect(longestGapDays(runs, '2024-06-02', '2024-06-29')).toBe(13); // 6/02 -> 6/15
    expect(longestGapDays([], '2024-06-01', '2024-06-30')).toBe(29);
  });
});

describe('max HR', () => {
  const withMax = (...maxes: number[]) => maxes.map((m, i) => run(`r${i}`, addDays('2024-06-01', i), 10, 330, { maxHr: m }));
  it('prefers the user value', () => {
    expect(resolveMaxHr({ user: 187, runs: withMax(180, 181), asOf: '2024-06-29', ageYears: 40, cfg })).toEqual({ value: 187, source: 'user' });
  });
  it('rejects a lone optical spike and takes the highest value confirmed by another workout within 3 bpm', () => {
    const r = resolveMaxHr({ runs: withMax(212, 186, 184, 170), asOf: '2024-06-29', ageYears: null, cfg });
    expect(r).toMatchObject({ value: 186, source: 'observed' });
  });
  it('falls back to the age formula, then a flat default, and flags both as defaults', () => {
    expect(resolveMaxHr({ runs: withMax(200, 160), asOf: '2024-06-29', ageYears: 40, cfg })).toMatchObject({ value: 180, source: 'default' });
    expect(resolveMaxHr({ runs: [], asOf: '2024-06-29', ageYears: null, cfg })).toMatchObject({ value: 190, source: 'default' });
  });
  it('ignores workouts older than a year', () => {
    const old = [run('o1', '2022-01-01', 10, 330, { maxHr: 195 }), run('o2', '2022-01-02', 10, 330, { maxHr: 194 })];
    expect(resolveMaxHr({ runs: old, asOf: '2024-06-29', ageYears: null, cfg }).source).toBe('default');
  });
});

describe('prior marathon detection', () => {
  const runs = [run('old', '2023-04-16', 42.4, 300), run('recent', '2023-10-08', 42.6, 310), run('half', '2024-04-01', 21.1, 300), run('tooold', '2020-10-01', 42.2, 300), run('target', '2024-07-13', 42.2, 300)];
  const base = { asOf: '2024-06-29', raceDate: '2024-07-13', lookbackStart: addMonths('2024-06-29', -36), cfg };
  it('takes the most recent marathon-length run before as_of within 36 months', () => {
    expect(detectPriorMarathon(runs, base)?.id).toBe('recent');
  });
  it('can be overridden or disabled', () => {
    expect(detectPriorMarathon(runs, { ...base, override: 'old' })?.id).toBe('old');
    expect(detectPriorMarathon(runs, { ...base, override: 'none' })).toBeNull();
    expect(detectPriorMarathon(runs, { ...base, override: 'missing' })).toBeNull();
  });
});

describe('GPS dropouts', () => {
  it('drops splits more than 2x slower or faster than the median, keeping partial splits', () => {
    const s = splitsOf(6.5, { pace: (i) => (i === 2 ? 900 : i === 3 ? 100 : 300), hr: 140 });
    const { splits, dropped } = cleanSplits(s, 2);
    expect(dropped).toBe(2);
    expect(splits.map((x) => x.split)).toEqual([1, 2, 5, 6, 7]);
  });
});
