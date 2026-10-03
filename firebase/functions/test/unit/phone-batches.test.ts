import { readdirSync, readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
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
    // (The multi-year scenario below adds older days; this one is about the ten most recent.)
    const days = (r.json.days as Record<string, number | string>[]).filter((d) => typeof d.steps === 'number' && (d.steps as number) < 4000);
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

  it('the full sync over about two years: every day of every year has its metrics with the written values', async () => {
    const win = (fromDaysAgo: number, toDaysAgo: number) => ({
      start_date: new Date(Date.now() - fromDaysAgo * 86_400_000).toISOString().slice(0, 10),
      end_date: new Date(Date.now() - toDaysAgo * 86_400_000).toISOString().slice(0, 10),
      metrics: ['steps', 'restingHr', 'hrv', 'activeKcal', 'sleepAsleepMin'],
    });
    const rows: Record<string, number | string>[] = [];
    for (const [a, b] of [[804, 405], [404, 11]] as const) {
      const r = await s.call('get_daily_context', win(a, b));
      expect(r.isError, r.text.slice(0, 300)).toBe(false);
      rows.push(...(r.json.days as Record<string, number | string>[]));
    }
    const history = rows.filter((d) => typeof d.steps === 'number' && (d.steps as number) >= 5011);
    const missing: string[] = [];
    for (const row of history) {
      const d = (row.steps as number) - 5000;
      const want = { restingHr: 50 + (d % 10), hrv: 40 + (d % 20), activeKcal: 300 + (d % 50), sleepAsleepMin: 420 };
      for (const [k, v] of Object.entries(want)) if (Number(row[k]) !== v) missing.push(`${row.date} ${k}=${row[k]} want ${v}`);
    }
    // Every one of the 790 seeded days (11 to 800 days ago) should be there; a day or two at the edges may fall outside
    // the windows when the check runs across midnight.
    expect(history.length, `days with steps per year: ${JSON.stringify(Object.fromEntries([...new Set(history.map((r) => String(r.date).slice(0, 4)))].map((y) => [y, history.filter((r) => String(r.date).startsWith(y)).length])))}`).toBeGreaterThanOrEqual(785);
    expect(missing.slice(0, 10), `${missing.length} wrong or missing values`).toEqual([]);
  });

  it('the diagnostic note travels with the daily batches and the server accepted it', () => {
    const notes: string[] = [];
    for (const f of readdirSync(dir!).filter((x) => x.endsWith('.ndjson.gz'))) {
      const first = JSON.parse(gunzipSync(readFileSync(join(dir!, f))).toString().split('\n')[0]!) as { type: string; perf?: { note?: string } };
      if (first.perf?.note) notes.push(first.perf.note);
    }
    for (const n of notes) console.log(`NOTE ${n}`);
    expect(notes.length, 'the engine sent no diagnostic note').toBeGreaterThan(0);
    const dailyNotes = notes.filter((n) => /daily from=\d{4}-\d{2}-\d{2} to=\d{4}-\d{2}-\d{2}/.test(n));
    expect(dailyNotes.length, 'the engine sent no daily diagnostic note').toBeGreaterThan(0);
    // Every metric of every chunk must report back from the first collection pass; "lost" ones are only rescued by a retry.
    const lost = dailyNotes.filter((n) => !/ lost=0\(/.test(n));
    expect(lost, 'chunks where metric results never reached the collector').toEqual([]);
    expect(dailyNotes.every((n) => /data=\d+\/\d+ got=\d+ lost=\d+/.test(n))).toBe(true);
  });
});
