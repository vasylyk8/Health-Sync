import type { CompactColumn } from '../../src/ingest/compact.js';

/** Reference encoder for compact columns (the phone has its own in Swift; both are checked against shared/compact-fixtures.json). */
export type Plan = { m: number } | 'exact';

const MULTIPLIERS = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000];
const SAFE = 9e15;

function exactMultiplier(values: (number | null)[]): number | null {
  for (const m of MULTIPLIERS) {
    if (values.every((v) => v === null || (Number.isFinite(v) && Math.abs(v * m) < SAFE && Math.round(v * m) / m === v))) return m;
  }
  return null;
}

export function encodeColumn(values: (number | null)[], plan: Plan): CompactColumn {
  const m = plan === 'exact' ? exactMultiplier(values) : plan.m;
  if (m === null) return { r: values.map((v) => (v !== null && Number.isFinite(v) ? v : null)) };
  const x: number[] = [];
  const nulls: number[] = [];
  let prev = 0;
  values.forEach((v, i) => {
    if (v !== null && Number.isFinite(v)) {
      prev = Math.round(v * m);
      x.push(prev);
    } else {
      nulls.push(i);
      x.push(prev);
    }
  });
  const d1 = x.map((v, i) => (i === 0 ? v : v - x[i - 1]!));
  const d2 = d1.map((v, i) => (i < 2 ? v : v - d1[i - 1]!));
  const cost = (d: number[]) => d.slice(2).reduce((n, v) => n + Math.abs(v), 0);
  // Second order only when strictly cheaper.
  const useTwo = cost(d2) < cost(d1);
  return { m, o: useTwo ? 2 : 1, d: useTwo ? d2 : d1, ...(nulls.length ? { x: nulls } : {}) };
}

export interface ChunkInput { t: number[]; cols: Record<string, (number | null)[]>; plans: Record<string, Plan> }

/** A compact `ws` record's columns (without k, wid, st, gen). */
export function encodeChunk(input: ChunkInput): Record<string, unknown> {
  const out: Record<string, unknown> = { enc: 1, n: input.t.length, t: encodeColumn(input.t, { m: 1 }) };
  for (const [name, values] of Object.entries(input.cols)) out[name] = encodeColumn(values, input.plans[name] ?? 'exact');
  return out;
}
