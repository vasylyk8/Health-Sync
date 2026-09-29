import { describe, expect, it } from 'vitest';
import { ingestObject } from '../../src/ingest/ingest.js';
import { makeBatch, makeEnv, upload } from '../helpers/memory.js';

const HR = 'HKQuantityTypeIdentifierHeartRate';
const S = Date.UTC(2024, 5, 1, 8);
const hr = (id: string, s: number, v = 60) => ({ k: 's', id, s, e: s, v, u: 'count/min', src: 'Watch' });

describe('ingestObject', () => {
  it('publishes parquet partitions and coverage', async () => {
    const env = makeEnv();
    const { result } = await upload(env, { type: HR, mode: 'recent', window: { start: S, end: env.now } }, [hr('a', S), hr('b', S + 1000)]);
    expect(result).toBe('published');
    const man = (await env.meta.getManifest(env.uid, HR))!;
    expect(man.files['2024-06']).toHaveLength(1);
    expect(man.coverage.intervals).toEqual([[S, env.now]]);
    expect(man.coverage.earliest).toBe(S);
    expect(man.coverage.visibleAt).toBe(env.now);
    expect(env.incoming.paths.size).toBe(0);
    expect(env.meta.users.get(env.uid)!.lastVisibleAt).toBe(env.now);
  });

  it('is idempotent when the same object is processed twice', async () => {
    const env = makeEnv();
    const b = makeBatch(env, { type: HR }, [hr('a', S)]);
    await env.incoming.write(b.path, b.gz);
    const d = { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now };
    expect(await ingestObject(b.path, d)).toBe('published');
    await env.incoming.write(b.path, b.gz);
    expect(await ingestObject(b.path, d)).toBe('duplicate');
    const man = (await env.meta.getManifest(env.uid, HR))!;
    expect(man.records).toBe(1);
    expect(man.files['2024-06']).toHaveLength(1);
  });

  it('discards batches for users being deleted', async () => {
    const env = makeEnv();
    env.meta.users.get(env.uid)!.deleting = true;
    const { result } = await upload(env, { type: HR }, [hr('a', S)]);
    expect(result).toBe('discarded');
    expect(await env.meta.getManifest(env.uid, HR)).toBeNull();
  });

  it('discards and cleans up when a deletion starts mid-ingest', async () => {
    const env = makeEnv();
    const b = makeBatch(env, { type: HR }, [hr('a', S)]);
    await env.incoming.write(b.path, b.gz);
    const meta = env.meta;
    const racing = Object.create(meta);
    racing.publish = async (args: Parameters<typeof meta.publish>[0]) => {
      meta.users.get(env.uid)!.generation++;
      return meta.publish(args);
    };
    const result = await ingestObject(b.path, { incoming: env.incoming, data: env.data, meta: racing, now: () => env.now });
    expect(result).toBe('discarded');
    expect(env.data.paths.size).toBe(0);
  });

  it('rejects malformed batches without touching the manifest', async () => {
    const env = makeEnv();
    const { result, batchId } = await upload(env, { type: HR }, [{ k: 's', id: 'a', s: 'yesterday' }]);
    expect(result).toBe('rejected');
    expect(env.meta.batches.get(`${env.uid}/${batchId}`)?.detail).toMatch(/line 1/);
    expect(await env.meta.getManifest(env.uid, HR)).toBeNull();
  });

  it('ignores objects outside incoming/', async () => {
    const env = makeEnv();
    expect(await ingestObject('data/x/y.parquet', { incoming: env.incoming, data: env.data, meta: env.meta })).toBe('ignored');
  });

  it('marks full history covered once the anchored pass catches up', async () => {
    const env = makeEnv();
    await upload(env, { type: HR, caughtUp: false }, [hr('a', S)]);
    expect((await env.meta.getManifest(env.uid, HR))!.coverage.caughtUp).toBe(false);
    await upload(env, { type: HR, caughtUp: true, checkedAt: env.now }, [hr('b', S + 5)]);
    const cov = (await env.meta.getManifest(env.uid, HR))!.coverage;
    expect(cov.caughtUp).toBe(true);
    expect(cov.intervals).toEqual([[0, env.now]]);
  });
});

describe('checksums', () => {
  it('rejects batches whose checksum does not match', async () => {
    const env = makeEnv();
    const b = makeBatch(env, { type: HR }, [hr('a', S)]);
    await env.incoming.write(b.path, b.gz);
    const r = await ingestObject(b.path, { incoming: env.incoming, data: env.data, meta: env.meta }, { sha256: 'f'.repeat(64) });
    expect(r).toBe('rejected');
  });
});

describe('status batches (many types, nothing new)', () => {
  const STEPS = 'HKQuantityTypeIdentifierStepCount';
  const st = (t: string, at: number, cu = true) => ({ k: 'c', t, at, cu });

  it('marks each listed type checked and fully synced, without data files', async () => {
    const env = makeEnv();
    const { result } = await upload(env, { type: '_status', mode: 'status' }, [st(HR, env.now - 5), st(STEPS, env.now - 5), st('HKFutureType', env.now)]);
    expect(result).toBe('published');
    for (const t of [HR, STEPS]) {
      const man = (await env.meta.getManifest(env.uid, t))!;
      expect(man.coverage.caughtUp).toBe(true);
      expect(man.coverage.intervals).toEqual([[0, env.now - 5]]);
      expect(man.coverage.checkedAt).toBe(env.now - 5);
      expect(man.files).toEqual({});
    }
    expect(await env.meta.getManifest(env.uid, 'HKFutureType')).toBeNull();
    expect(await env.meta.getManifest(env.uid, '_status')).toBeNull();
  });

  it('keeps existing data and only refreshes freshness when not caught up', async () => {
    const env = makeEnv();
    await upload(env, { type: HR, caughtUp: false }, [hr('a', S)]);
    await upload(env, { type: '_status', mode: 'status' }, [st(HR, env.now, false)]);
    const man = (await env.meta.getManifest(env.uid, HR))!;
    expect(man.coverage.caughtUp).toBe(false);
    expect(man.coverage.checkedAt).toBe(env.now);
    expect(man.files['2024-06']).toHaveLength(1);
  });

  it('is idempotent on retry', async () => {
    const env = makeEnv();
    const b = makeBatch(env, { type: '_status', mode: 'status' }, [st(HR, env.now)]);
    const d = { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now };
    await env.incoming.write(b.path, b.gz);
    expect(await ingestObject(b.path, d)).toBe('published');
    const version = (await env.meta.getManifest(env.uid, HR))!.version;
    await env.incoming.write(b.path, b.gz);
    expect(await ingestObject(b.path, d)).toBe('duplicate');
    expect((await env.meta.getManifest(env.uid, HR))!.version).toBe(version);
  });

  it('rejects status records in normal batches and data records in status batches', async () => {
    const env = makeEnv();
    expect((await upload(env, { type: HR }, [st(HR, env.now)])).result).toBe('rejected');
    expect((await upload(env, { type: '_status', mode: 'status' }, [hr('a', S)])).result).toBe('rejected');
    expect((await upload(env, { type: HR, mode: 'status' }, [st(HR, env.now)])).result).toBe('rejected');
  });
});

describe('user "last updated" write throttle', () => {
  it('writes lastVisibleAt at most once a minute', async () => {
    const env = makeEnv();
    await upload(env, { type: HR }, [hr('a', S)]);
    expect(env.meta.users.get(env.uid)!.lastVisibleAt).toBe(env.now);
    const first = env.now;
    env.now += 30_000;
    await upload(env, { type: HR }, [hr('b', S)]);
    expect(env.meta.users.get(env.uid)!.lastVisibleAt).toBe(first);
    env.now += 30_000;
    await upload(env, { type: HR }, [hr('c', S)]);
    expect(env.meta.users.get(env.uid)!.lastVisibleAt).toBe(env.now);
  });
});
