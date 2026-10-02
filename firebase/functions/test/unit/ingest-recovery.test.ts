import { describe, expect, it } from 'vitest';
import { ingestObject } from '../../src/ingest/ingest.js';
import { getWorkouts } from '../../src/query/workouts.js';
import { deps, makeBatch, makeEnv, upload } from '../helpers/memory.js';

const W = 'HKWorkoutTypeIdentifier';
const S = Date.UTC(2024, 5, 1, 8);
const w = (id: string) => ({ k: 'w', id, s: S, e: S + 60_000, act: 37, actName: 'Running' });

describe('ingestion recovery regressions', () => {
  it('reconciliation retry completes cleanup after post-publication failure', async () => {
    const env = makeEnv();
    const rid = '11111111-1111-4111-8111-111111111111';
    const b = makeBatch(env, { type: W, mode: 'reconcile', reconcileId: rid, reconcileDone: true, caughtUp: true }, []);
    await env.incoming.write(b.path, b.gz);
    let calls = 0;
    const dep = { ...env, now: () => env.now, onReconcileDone: async () => { calls++; if (calls === 1) throw new Error('transient'); } };
    await expect(ingestObject(b.path, dep)).rejects.toThrow('transient');
    expect(await env.incoming.exists(b.path)).toBe(true);
    const version = (await env.meta.getManifest(env.uid, W))!.version;
    await ingestObject(b.path, dep);
    expect(calls).toBe(2);
    expect((await env.meta.getManifest(env.uid, W))!.version).toBe(version);
    expect(await env.incoming.exists(b.path)).toBe(false);
    await ingestObject(b.path, dep);
    expect(calls).toBe(2);
  });

  it('out-of-order publication cannot claim full history before earlier pages arrive', async () => {
    const env = makeEnv();
    const earlier = makeBatch(env, { type: W, caughtUp: false }, [w('pending')]);
    await env.incoming.write(earlier.path, earlier.gz); // accepted but not ingested yet
    await upload(env, { type: W, caughtUp: true }, []);
    const r = await getWorkouts(deps(env), { start_date: '2024-06-01', end_date: '2024-06-01' });
    expect(r.complete).toBe(false);
    expect(r.notes.join(' ')).toContain('Accepted uploads');
    expect(r.coverage[0]!.fullHistorySynced).toBe(false);
    await ingestObject(earlier.path, { ...env, now: () => env.now });
    const settled = await getWorkouts(deps(env), { start_date: '2024-06-01', end_date: '2024-06-01' });
    expect(settled.complete).toBe(true);
    expect((settled.workouts as object[])).toHaveLength(1);
  });

  it('does not treat another account pending uploads as this user\'s incomplete history', async () => {
    const env = makeEnv();
    const pending = makeBatch(env, { type: W, uid: 'another-user', caughtUp: false }, [w('other')]);
    await env.incoming.write(pending.path, pending.gz);
    await upload(env, { type: W, caughtUp: true }, [w('own')]);
    const result = await getWorkouts(deps(env), { start_date: '2024-06-01', end_date: '2024-06-01' });
    expect(result.complete).toBe(true);
  });

  it('retries post-publication tombstone cleanup without resurrecting deleted raw data', async () => {
    const env = makeEnv();
    const batch = makeBatch(env, { type: W }, [{ k: 'd', id: 'deleted' }]);
    await env.incoming.write(batch.path, batch.gz);
    const original = env.meta.deleteWorkoutData.bind(env.meta);
    let calls = 0;
    env.meta.deleteWorkoutData = async (...args) => {
      if (++calls === 1) throw new Error('cleanup failed');
      return original(...args);
    };
    await expect(ingestObject(batch.path, { ...env, now: () => env.now })).rejects.toThrow('cleanup failed');
    expect(await env.incoming.exists(batch.path)).toBe(true);
    await ingestObject(batch.path, { ...env, now: () => env.now });
    expect(calls).toBe(2);
    expect(await env.incoming.exists(batch.path)).toBe(false);
  });

  it('higher sequence wins when events arrive out of order', async () => {
    const env = makeEnv();
    const send = async (seq: number, en: number) => {
      const b = makeBatch(env, { type: W, caughtUp: true }, [{ ...w('a'), en }]);
      const { gunzipSync, gzipSync } = await import('node:zlib');
      const lines = gunzipSync(b.gz).toString().split('\n');
      lines[0] = JSON.stringify({ ...JSON.parse(lines[0]!), seq });
      await env.incoming.write(b.path, gzipSync(lines.join('\n')));
      await ingestObject(b.path, { ...env, now: () => env.now });
    };
    await send(10, 80);
    await send(5, 60);
    const r = await getWorkouts(deps(env), { start_date: '2024-06-01', end_date: '2024-06-01' });
    expect((r.workouts as { active_kcal: number }[])[0]!.active_kcal).toBe(80);
  });
});
