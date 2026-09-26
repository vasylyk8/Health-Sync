import { describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import { compactType, finishReconcile } from '../../src/jobs/maintenance.js';
import { summarize } from '../../src/query/tools.js';
import { deps, makeEnv, upload } from '../helpers/memory.js';

const HR = 'HKQuantityTypeIdentifierHeartRate';
const t = (h: number) => Date.UTC(2024, 5, 1, h);
const hr = (id: string, h: number, v = 60) => ({ k: 's', id, s: t(h), e: t(h), v, u: 'count/min' });
const count = async (env: ReturnType<typeof makeEnv>) =>
  ((await summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-01', period: 'none', stat: 'count' })).rows as { value: number }[])[0]?.value ?? 0;

describe('finishReconcile', () => {
  it('tombstones records deleted while offline, but keeps records added during the pass', async () => {
    const env = makeEnv();
    await upload(env, { type: HR }, [hr('keep', 1), hr('gone', 2)]);
    const rid = randomUUID();
    await upload(env, { type: HR, mode: 'reconcile', reconcileId: rid }, [hr('keep', 1)]);
    // A new reading arrives through normal change capture during the reconcile pass.
    await upload(env, { type: HR }, [hr('new', 3)]);
    await upload(env, { type: HR, mode: 'reconcile', reconcileId: rid, reconcileDone: true, caughtUp: true }, []);
    expect(await finishReconcile({ meta: env.meta, data: env.data }, env.uid, HR, rid)).toBe(1);
    expect(await count(env)).toBe(2);
  });
});

describe('compactType', () => {
  it('merges partitions without changing query results', async () => {
    const env = makeEnv();
    for (let i = 0; i < 10; i++) await upload(env, { type: HR }, [hr(`x${i}`, i), hr('dup', 12, i)]);
    await upload(env, { type: HR }, [{ k: 'd', id: 'x0' }]);
    const before = await count(env);
    const man0 = (await env.meta.getManifest(env.uid, HR))!;
    expect(man0.fragmented).toBe(true);
    expect(await compactType({ meta: env.meta, data: env.data }, env.uid, HR)).toBe(1);
    const man = (await env.meta.getManifest(env.uid, HR))!;
    expect(man.files['2024-06']).toHaveLength(1);
    expect(man.fragmented).toBe(false);
    expect(await count(env)).toBe(before);
    expect(before).toBe(10); // 9 surviving x's + one deduplicated 'dup'
  });
});
