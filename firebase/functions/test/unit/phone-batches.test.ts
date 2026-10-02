import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { ingestObject } from '../../src/ingest/ingest.js';
import { makeEnv } from '../helpers/memory.js';
import { serve } from '../helpers/synthetic.js';

/**
 * The upload batches the real app built from the iOS simulator's HealthKit (daily-check workflow), ingested by the real
 * server code and asked about through the MCP endpoint. Skipped unless PHONE_BATCH_DIR points at the collected batches.
 */
const dir = process.env.PHONE_BATCH_DIR;
type S = Awaited<ReturnType<typeof serve>>;
let s: S;
let published = 0;

describe.skipIf(!dir)('what the phone sends is what an AI gets back', () => {
  beforeAll(async () => {
    const env = makeEnv(Date.now());
    env.meta.users.get(env.uid)!.categories = ['core', 'nutrition', 'mind', 'cycle'];
    const files = readdirSync(dir!).filter((f) => f.endsWith('.ndjson.gz'));
    expect(files.length, 'the app dumped no batches').toBeGreaterThan(0);
    for (const f of files) {
      const path = `incoming/${env.uid}/${f}`;
      await env.incoming.write(path, readFileSync(join(dir!, f)));
      const r = await ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
      expect(r, f).toBe('published');
      published++;
    }
    s = await serve(env);
  }, 120_000);
  afterAll(async () => { await s?.close(); });

  it('every seeded metric comes back with the value that was written, day by day', async () => {
    const r = await s.call('get_daily_context', { start_date: new Date(Date.now() - 14 * 86_400_000).toISOString().slice(0, 10), end_date: new Date(Date.now() + 86_400_000).toISOString().slice(0, 10) });
    expect(r.isError, r.text.slice(0, 300)).toBe(false);
    const days = (r.json.days as Record<string, number | string>[]).filter((d) => typeof d.steps === 'number');
    expect(days.length).toBe(10);
    for (const row of days) {
      // The check seeds day d (1 = yesterday) with steps 3 x (800 + d) and the other types with a value that depends on d too.
      const d = (row.steps as number) / 3 - 800;
      expect(d, JSON.stringify(row)).toBeGreaterThanOrEqual(1);
      const near = (key: string, want: number) => expect(Number(row[key]), `${row.date} ${key}`).toBeCloseTo(want, 1);
      near('activeKcal', 3 * (40 + d));
      near('walkRunDistanceM', 3 * (600 + d));
      near('flightsClimbed', 3 * (4 + d));
      near('restingHr', 54 + d);
      near('hrv', 62 + d);
      near('respiratoryRate', 15 + d);
      near('vo2max', 48 + d);
      near('walkingSpeedMps', 1.3 + d);
      near('envAudioAvg', 70 + d);
      near('bodyMassKg', 75 + d);
      near('sleepAsleepMin', 420);
    }
    const dates = days.map((d) => String(d.date)).sort();
    expect(new Set(dates).size).toBe(10);
  });

  it('groups, rollups and recovery work on what the phone sent', async () => {
    const from = new Date(Date.now() - 14 * 86_400_000).toISOString().slice(0, 10);
    const to = new Date(Date.now()).toISOString().slice(0, 10);
    const heart = await s.call('get_daily_context', { start_date: from, end_date: to, groups: ['heart'] });
    expect(heart.isError).toBe(false);
    expect(Object.keys(heart.json.days[0])).toEqual(expect.arrayContaining(['date', 'restingHr', 'hrv']));
    const week = await s.call('get_daily_context', { start_date: from, end_date: to, rollup: 'week', metrics: ['steps'] });
    expect(week.isError).toBe(false);
    expect(week.json.periods.length).toBeGreaterThan(0);
    expect(published).toBeGreaterThan(0);
  });
});
