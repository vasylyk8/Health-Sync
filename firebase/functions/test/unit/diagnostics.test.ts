import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { probeBatch, validateProbe } from '../../src/diagnostics/probe.js';
import { makeBatch, makeEnv } from '../helpers/memory.js';
const uid = 'phone-account', start = Date.UTC(2024, 5, 1, 8);
const request = (gz: Buffer) => ({ expectedUid: uid, gz: gz.toString('base64'), sha256: createHash('sha256').update(gz).digest('hex') });
describe('isolated phone diagnostics', () => {
  it('binds payload to authenticated account and exact bytes', () => {
    const b = makeBatch(makeEnv(), { type: 'HKWorkoutTypeIdentifier' }, []);
    expect(() => validateProbe('other', request(b.gz))).toThrow('account mismatch');
    expect(() => validateProbe(uid, { ...request(b.gz), sha256: '0'.repeat(64) })).toThrow('checksum');
    expect(() => validateProbe(uid, { ...request(b.gz), gz: 'a'.repeat(7_000_001) })).toThrow('invalid payload');
    expect(validateProbe(uid, request(b.gz)).gz.equals(b.gz)).toBe(true);
  });
  it('ingests, reads back and verifies duplicates without altering the caller', async () => {
    const env = makeEnv(), user = (await env.meta.getUser(env.uid))!, original = structuredClone(user);
    const b = makeBatch(env, { type: 'HKWorkoutTypeIdentifier' }, [{ k: 'w', id: 'a', s: start, e: start + 60_000, act: 37, actName: 'Running', dur: 60, en: 12.345678, src: 'Watch' }]);
    const receipt = await probeBatch(uid, request(b.gz), user);
    expect(receipt.accountVerified).toBe(true); expect(receipt.maxDelta).toBeLessThanOrEqual(1e-9); expect(receipt.readbackRows).toBe(1); expect(receipt.duplicateVerified).toBe(true);
    expect(user).toEqual(original); expect(env.meta.manifests.size).toBe(0); expect(env.data.paths.size).toBe(0);
  });
  it('checks expanded daily and hourly rows', async () => {
    const env = makeEnv(), user = (await env.meta.getUser(env.uid))!;
    for (const [type, records] of [['_daily', [{ k: 'day', day: '2024-06-01', m: { steps: 12345, restingHr: 54.321 } }]], ['_hourly', [{ k: 'hs', st: 'HeartRate', u: 'count/min', t: [start, start + 3_600_000], v: [65.123, 75.321] }]]] as const) {
      const b = makeBatch(env, { type, mode: 'stats', schema: 2, window: { start, end: env.now } }, [...records]);
      const receipt = await probeBatch(uid, request(b.gz), user); expect(receipt.readbackRows).toBeGreaterThan(0); expect(receipt.maxDelta).toBeLessThanOrEqual(1e-9);
    }
  });
  it('refuses invalid records instead of silently dropping them', async () => {
    const env = makeEnv(), b = makeBatch(env, { type: 'HKWorkoutTypeIdentifier' }, [{ k: 'w', s: -1 }]);
    await expect(probeBatch(uid, request(b.gz), (await env.meta.getUser(env.uid))!)).rejects.toThrow('invalid');
  });
  it('roundtrips workout series, routes, completion marks and same-time duplicates', async () => {
    const env = makeEnv(), user = (await env.meta.getUser(env.uid))!, wid = '11111111-1111-4111-8111-111111111111';
    const b = makeBatch(env, { type: '_wstream', mode: 'workoutdata' }, [
      { k: 'ws', wid, st: 'HeartRate', gen: start, u: 'count/min', t: [start, start], v: [100.125, 120.875] },
      { k: 'ws', wid, st: 'route', gen: start, t: [start, start + 1000], lat: [43.123456, 43.123457], lon: [-79.123456, -79.123457], alt: [10.125, 10.875] },
      { k: 'wd', wid, gen: start, expected: { HeartRate: 2, route: 2 } },
    ]);
    const receipt = await probeBatch(uid, request(b.gz), user);
    expect(receipt.readbackRows).toBe(4); expect(receipt.duplicateVerified).toBe(true); expect(receipt.maxDelta).toBeLessThanOrEqual(1e-9);
  });
  it('verifies delete markers without deleting caller data', async () => {
    const env = makeEnv(), b = makeBatch(env, { type: 'HKWorkoutTypeIdentifier' }, [{ k: 'd', id: '11111111-1111-4111-8111-111111111111' }]);
    const receipt = await probeBatch(uid, request(b.gz), (await env.meta.getUser(env.uid))!);
    expect(receipt.readbackRows).toBe(1); expect(env.meta.manifests.size).toBe(0);
  });

});
