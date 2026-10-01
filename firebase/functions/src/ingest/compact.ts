import { z } from 'zod';

/**
 * Compact encoding of a raw stream chunk (`enc: 1`, docs/DATA_CONTRACT.md §1 "compact `ws`").
 *
 * Every column is a list of integers `x[i]` and a divisor `m`: the value is `x[i] / m`. The integers are
 * stored as differences (`o: 1`: from the previous point; `o: 2`: difference of differences, which is
 * near zero for steady motion and regular timestamps) so they are small and compress well. A column of
 * values that are not a whole number of 1/m (`r`) is sent as plain numbers. `x` lists the indexes whose
 * value is null (the running value carries over them).
 */
export const MAX_COMPACT_POINTS = 20_000;

const Delta = z.object({
  /** Values are `integer / m`; division of two exactly representable numbers is identical on every platform. */
  m: z.number().int().min(1).max(1e15),
  o: z.union([z.literal(1), z.literal(2)]),
  d: z.array(z.number().int()).max(MAX_COMPACT_POINTS),
  x: z.array(z.number().int().min(0)).max(MAX_COMPACT_POINTS).optional(),
}).strict();
const Raw = z.object({ r: z.array(z.number().finite().nullable()).max(MAX_COMPACT_POINTS) }).strict();
export const CompactColumn = z.union([Delta, Raw]);
export type CompactColumn = z.infer<typeof CompactColumn>;

export class CompactError extends Error {}

/** Decodes one column to `n` values (null where the phone had none). */
export function decodeColumn(col: CompactColumn, n: number): (number | null)[] {
  if ('r' in col) {
    if (col.r.length !== n) throw new CompactError(`has ${col.r.length} values but n is ${n}`);
    return col.r;
  }
  if (col.d.length !== n) throw new CompactError(`has ${col.d.length} values but n is ${n}`);
  const nulls = new Set<number>();
  let last = -1;
  for (const i of col.x ?? []) {
    if (i <= last || i >= n) throw new CompactError('null positions must be increasing and inside the chunk');
    nulls.add(i);
    last = i;
  }
  const out: (number | null)[] = new Array(n);
  let x = 0;
  let step = 0;
  for (let i = 0; i < n; i++) {
    const d = col.d[i]!;
    if (i === 0) x = d;
    else if (col.o === 1 || i === 1) {
      step = d;
      x += step;
    } else {
      step += d;
      x += step;
    }
    if (!Number.isSafeInteger(x) || !Number.isSafeInteger(step)) throw new CompactError('value out of range');
    out[i] = nulls.has(i) ? null : x / col.m;
  }
  return out;
}

/** Decodes the time column: whole milliseconds, never null. */
export function decodeTimes(col: CompactColumn, n: number, max: number): number[] {
  if (!('d' in col) || col.m !== 1 || col.x?.length) throw new CompactError('t must be whole milliseconds without gaps');
  const t = decodeColumn(col, n) as number[];
  for (const v of t) if (v < 0 || v > max) throw new CompactError('t out of range');
  return t;
}
