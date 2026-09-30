import { describe, expect, it } from 'vitest';
import { gzipSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import { BatchError, parseBatch } from '../../src/ingest/batch.js';

const header = (over: object = {}) => ({ kind: 'header', schema: 1, batchId: randomUUID(), type: 'HKWorkoutTypeIdentifier', seq: 1, createdAt: 1_700_000_000_000, mode: 'anchored', ...over });
const gz = (lines: object[] | string[]) => gzipSync(lines.map((l) => (typeof l === 'string' ? l : JSON.stringify(l))).join('\n'));
const S = Date.UTC(2024, 2, 31, 23, 30);

describe('parseBatch', () => {
  it('partitions workouts by UTC month of their start and collects tombstones', () => {
    const p = parseBatch(gz([
      header(),
      { k: 'w', id: 'a', s: S, e: S + 600_000, act: 37 },
      { k: 'w', id: 'b', s: S + 3_600_000, e: S + 4_200_000, act: 13 },
      { k: 'd', id: 'zzz' },
    ]));
    expect([...p.partitions.keys()].sort()).toEqual(['2024-03', '2024-04']);
    expect(p.tombstones).toEqual(['zzz']);
    expect(p.span).toEqual({ start: S, end: S + 4_200_000 });
    expect(p.recordCount).toBe(3);
  });

  it('keeps unknown fields in extra', () => {
    const p = parseBatch(gz([header({ type: 'HKWorkoutTypeIdentifier' }), { k: 'w', id: 'w1', s: S, e: S + 60_000, act: 37, actName: 'Running', dist: 5000, futureField: 1 }]));
    const row = p.partitions.get('2024-03')![0]!;
    expect(JSON.parse(row.extra!)).toMatchObject({ act: 37, actName: 'Running', dist: 5000, futureField: 1 });
  });

  it.each([
    ['invalid JSON', [JSON.stringify(header()), '{nope']],
    ['unknown type', [header({ type: 'HKQuantityTypeIdentifierMadeUp' })]],
    ['a type that is no longer synced', [header({ type: 'HKQuantityTypeIdentifierHeartRate' }), { k: 'w', id: 'a', s: S, e: S, act: 1 }]],
    ['sample records (not stored any more)', [header(), { k: 's', id: 'a', s: S, e: S, v: 1 }]],
    ['stat buckets (not stored any more)', [header(), { k: 'h', s: S, e: S + 1, agg: 'avg', v: 1, u: 'x' }]],
    ['wrong schema', [header({ schema: 3 })]],
    ['end before start', [header(), { k: 'w', id: 'a', s: S, e: S - 1, act: 1 }]],
    ['non-finite value', [JSON.stringify(header()), '{"k":"w","id":"a","s":1,"e":1,"act":1,"dur":1e999}']],
    ['unknown record kind', [header(), { k: 'zz', id: 'a' }]],
  ])('rejects %s', (_name, lines) => {
    expect(() => parseBatch(gz(lines as object[]))).toThrow(BatchError);
  });

  it('keeps the valid records when only some are invalid, and counts the skipped ones', () => {
    const p = parseBatch(gz([
      header(),
      { k: 'w', id: 'good', s: S, e: S + 60_000, act: 37 },
      { k: 'w', id: 'bad', s: S, e: S - 1, act: 1 },
      '{nope',
    ]));
    expect(p.recordCount).toBe(1);
    expect(p.skipped).toBe(2);
    expect(p.partitions.get('2024-03')).toHaveLength(1);
  });

  it('rejects non-gzip and decompression bombs', () => {
    expect(() => parseBatch(Buffer.from('plain'))).toThrow(BatchError);
    const bomb = gzipSync(Buffer.alloc(200 * 1024 * 1024, 32));
    expect(bomb.byteLength).toBeLessThan(5 * 1024 * 1024);
    expect(() => parseBatch(bomb)).toThrow(/decompressed/);
  });
});
