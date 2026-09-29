import { describe, expect, it } from 'vitest';
import { gzipSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import { BatchError, parseBatch } from '../../src/ingest/batch.js';

const header = (over: object = {}) => ({ kind: 'header', schema: 1, batchId: randomUUID(), type: 'HKQuantityTypeIdentifierHeartRate', seq: 1, createdAt: 1_700_000_000_000, mode: 'anchored', ...over });
const gz = (lines: object[] | string[]) => gzipSync(lines.map((l) => (typeof l === 'string' ? l : JSON.stringify(l))).join('\n'));
const S = Date.UTC(2024, 2, 31, 23, 30);

describe('parseBatch', () => {
  it('partitions samples by UTC month and collects tombstones', () => {
    const p = parseBatch(gz([
      header(),
      { k: 's', id: 'a', s: S, e: S, v: 60, u: 'count/min', src: 'Watch' },
      { k: 's', id: 'b', s: S + 3_600_000, e: S + 3_600_000, v: 70, u: 'count/min' },
      { k: 'h', s: S, e: S + 3_600_000, agg: 'avg', v: 65, u: 'count/min' },
      { k: 'd', id: 'zzz' },
    ]));
    expect([...p.partitions.keys()].sort()).toEqual(['2024-03', '2024-04', '_stats/2024']);
    expect(p.tombstones).toEqual(['zzz']);
    expect(p.span).toEqual({ start: S, end: S + 3_600_000 });
    expect(p.recordCount).toBe(4);
  });

  it('keeps unknown fields in extra', () => {
    const p = parseBatch(gz([header({ type: 'HKWorkoutTypeIdentifier' }), { k: 'w', id: 'w1', s: S, e: S + 60_000, act: 37, actName: 'Running', dist: 5000, futureField: 1 }]));
    const row = p.partitions.get('2024-03')![0]!;
    expect(JSON.parse(row.extra!)).toMatchObject({ act: 37, actName: 'Running', dist: 5000, futureField: 1 });
  });

  it.each([
    ['invalid JSON', [JSON.stringify(header()), '{nope']],
    ['unknown type', [header({ type: 'HKQuantityTypeIdentifierMadeUp' })]],
    ['wrong schema', [header({ schema: 3 })]],
    ['end before start', [header(), { k: 's', id: 'a', s: S, e: S - 1, v: 1 }]],
    ['non-finite value', [JSON.stringify(header()), '{"k":"s","id":"a","s":1,"e":1,"v":1e999}']],
    ['unknown record kind', [header(), { k: 'zz', id: 'a' }]],
  ])('rejects %s', (_name, lines) => {
    expect(() => parseBatch(gz(lines as object[]))).toThrow(BatchError);
  });

  it('rejects non-gzip and decompression bombs', () => {
    expect(() => parseBatch(Buffer.from('plain'))).toThrow(BatchError);
    const bomb = gzipSync(Buffer.alloc(200 * 1024 * 1024, 32));
    expect(bomb.byteLength).toBeLessThan(5 * 1024 * 1024);
    expect(() => parseBatch(bomb)).toThrow(/decompressed/);
  });
});
