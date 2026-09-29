/**
 * QA findings (2026-09-29). Each test asserts the CORRECT behaviour and is marked `it.fails`
 * because the current code gets it wrong. When a bug is fixed, its test starts "unexpectedly
 * passing": flip `it.fails` to `it` so it guards against regressions. IDs match QA_REPORT.md.
 */
import { randomUUID } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { deps, makeEnv, type Env } from '../helpers/memory.js';
import { ingestObject } from '../../src/ingest/ingest.js';
import { getOverview, getSleep, summarize } from '../../src/query/tools.js';
import { ToolError } from '../../src/query/context.js';

const STEPS = 'HKQuantityTypeIdentifierStepCount';
const SLEEP = 'HKCategoryTypeIdentifierSleepAnalysis';
const day = (d: number, h = 0, m = 0) => Date.UTC(2024, 5, d, h, m);

/** Like the shared helper, but with an explicit per-type `seq` (the phone's counter). */
async function send(env: Env, seq: number, header: Record<string, unknown>, records: object[]) {
  const batchId = randomUUID();
  const h = { kind: 'header', schema: 1, batchId, seq, tz: 'UTC', createdAt: env.now, checkedAt: env.now, ...header };
  const path = `incoming/${env.uid}/${batchId}.ndjson.gz`;
  await env.incoming.write(path, gzipSync([h, ...records].map((r) => JSON.stringify(r)).join('\n')));
  return ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
}

/** iPhone + Watch both counted the same 1000-step walk; Apple's merged total is 1000. */
async function seedDoubleSourceSteps(env: Env) {
  await send(env, 1, { type: STEPS, mode: 'recent', window: { start: day(1), end: env.now } }, [
    { k: 's', id: 'w1', s: day(29, 9), e: day(29, 10), v: 1000, u: 'count', src: 'Apple Watch' },
    { k: 's', id: 'p1', s: day(29, 9), e: day(29, 10), v: 1000, u: 'count', src: 'iPhone' },
  ]);
  await send(env, 2, { type: STEPS, mode: 'stats', window: { start: day(1), end: env.now } }, [
    { k: 'h', s: day(29, 9), e: day(29, 10), agg: 'sum', v: 1000, u: 'count' },
  ]);
}

describe('QA findings: totals', () => {
  it('S-1: merged stats stay in use after a later anchored batch advances checkedAt', async () => {
    const env = makeEnv(day(30, 12));
    await seedDoubleSourceSteps(env);
    // The phone's run() does stats first, then the anchored pass: checkedAt moves past the stats window.
    env.now += 5 * 60_000;
    await send(env, 3, { type: STEPS, mode: 'anchored', caughtUp: true, checkedAt: env.now }, []);
    const r = await summarize(deps(env), { type: 'StepCount', start_date: '2024-06-29', end_date: '2024-06-30', period: 'none' });
    expect(r.method).toBe('merged');
    expect(r.rows).toEqual([expect.objectContaining({ value: 1000 })]);
  });

  it('S-2: get_health_overview must not report double-counted steps (and must keep the warning)', async () => {
    const env = makeEnv(day(30, 12));
    // Stats cover only the first half of the 30-day window, so the overview falls back to raw data.
    await send(env, 1, { type: STEPS, mode: 'recent', window: { start: day(1), end: env.now } }, [
      { k: 's', id: 'w1', s: day(29, 9), e: day(29, 10), v: 1000, u: 'count', src: 'Apple Watch' },
      { k: 's', id: 'p1', s: day(29, 9), e: day(29, 10), v: 1000, u: 'count', src: 'iPhone' },
    ]);
    const r = await getOverview(deps(env), { days: 7 });
    const steps = r.metrics as { steps: { total: number } };
    const warned = r.notes.some((n) => /double/i.test(n));
    expect(steps.steps.total === 1000 || warned).toBe(true);
  });

  it.fails('S-3: a deleted hour disappears from merged totals (phone omits empty buckets)', async () => {
    const env = makeEnv(day(30, 12));
    await send(env, 1, { type: STEPS, mode: 'stats', window: { start: day(28), end: env.now } }, [
      { k: 'h', s: day(29, 9), e: day(29, 10), agg: 'sum', v: 50_000, u: 'count' }, // bogus manual entry
      { k: 'h', s: day(29, 11), e: day(29, 12), agg: 'sum', v: 300, u: 'count' },
    ]);
    // User deletes the bogus entry; HealthKit returns no statistic for 09:00, so the phone sends none.
    await send(env, 2, { type: STEPS, mode: 'stats', window: { start: day(28), end: env.now } }, [
      { k: 'h', s: day(29, 11), e: day(29, 12), agg: 'sum', v: 300, u: 'count' },
    ]);
    const r = await summarize(deps(env), { type: 'StepCount', start_date: '2024-06-29', end_date: '2024-06-29', period: 'none' });
    expect(r.rows).toEqual([expect.objectContaining({ value: 300 })]);
  });

  it.fails('S-4: after an app reinstall (seq restarts at 1) newer stats still win', async () => {
    const env = makeEnv(day(30, 12));
    await send(env, 900, { type: STEPS, mode: 'stats', window: { start: day(29), end: day(29, 10, 30) } }, [
      { k: 'h', s: day(29, 10), e: day(29, 11), agg: 'sum', v: 500, u: 'count' }, // partial hour
    ]);
    // Reinstall: same anonymous Firebase user (Keychain survives), fresh outbox => seq starts again.
    await send(env, 1, { type: STEPS, mode: 'stats', window: { start: day(29), end: env.now } }, [
      { k: 'h', s: day(29, 10), e: day(29, 11), agg: 'sum', v: 800, u: 'count' },
    ]);
    const r = await summarize(deps(env), { type: 'StepCount', start_date: '2024-06-29', end_date: '2024-06-29', period: 'none' });
    expect(r.rows).toEqual([expect.objectContaining({ value: 800 })]);
  });
});

describe('QA findings: sleep', () => {
  it.fails('S-5: sleep ending after noon belongs to that day, not the next', async () => {
    const env = makeEnv(day(30, 20));
    // Late sleeper: 02:00 -> 12:30 on Jun 29 (UTC). Nap-free, one night.
    await send(env, 1, { type: SLEEP, mode: 'recent', window: { start: day(20), end: env.now } }, [
      { k: 's', id: 'a', s: day(29, 2), e: day(29, 12, 30), c: 3, src: 'Watch' },
    ]);
    const r = await getSleep(deps(env), { start_date: '2024-06-29', end_date: '2024-06-30' });
    expect((r.nights as { night: string }[]).map((n) => n.night)).toEqual(['2024-06-29']);
  });

  it.fails('S-6: summarize(SleepAnalysis) and get_sleep agree on which day a night belongs to', async () => {
    const env = makeEnv(day(30, 20));
    await send(env, 1, { type: SLEEP, mode: 'recent', window: { start: day(20), end: env.now } }, [
      { k: 's', id: 'a', s: day(28, 23), e: day(29, 1), c: 4, src: 'Watch' }, // deep, starts before midnight
      { k: 's', id: 'b', s: day(29, 1), e: day(29, 7), c: 3, src: 'Watch' },
    ]);
    const sleep = await getSleep(deps(env), { start_date: '2024-06-29', end_date: '2024-06-29' });
    const deep = await summarize(deps(env), { type: 'SleepAnalysis', start_date: '2024-06-29', end_date: '2024-06-29', period: 'day', stat: 'duration_min', category_value: 4 });
    const perNight = (sleep.nights as { deep_min: number }[])[0]!.deep_min;
    const perDay = (deep.rows as { value: number }[])[0]?.value ?? 0;
    expect(perDay).toBe(perNight);
  });
});

describe('QA findings: input validation', () => {
  const expectBadRequest = async (p: Promise<unknown>) => {
    await expect(p).rejects.toBeInstanceOf(ToolError);
  };

  it('V-1: impossible calendar dates are a bad_request, not an internal error', async () => {
    const env = makeEnv();
    await expectBadRequest(summarize(deps(env), { type: 'StepCount', start_date: '2024-02-30', end_date: '2024-03-01', period: 'day' }));
  });

  it('V-2: UTC-offset timezones are rejected (or supported), not an internal error', async () => {
    const env = makeEnv();
    await expectBadRequest(summarize(deps(env), { type: 'StepCount', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day', timezone: '+05:30' }));
  });

  it('V-3: summing a discrete type (heart rate) is refused', async () => {
    const env = makeEnv();
    await expectBadRequest(summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-01', period: 'none', stat: 'sum' }));
  });
});
