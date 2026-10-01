import { DuckDBInstance, type DuckDBConnection } from '@duckdb/node-api';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { STREAM_COLS, type Row, type StreamChunk } from '../ingest/batch.js';

/**
 * Opens a private in-memory DuckDB for one operation. Only trusted, server-written SQL runs here:
 * AI-written SQL is deliberately not supported in v1 (see plan: "Deferred SQL").
 */
export async function withDuck<T>(fn: (c: DuckDBConnection, dir: string) => Promise<T>, opts: { memoryLimit?: string } = {}): Promise<T> {
  const dir = await mkdtemp(join(tmpdir(), 'hs-'));
  const db = await DuckDBInstance.create(':memory:', {
    autoinstall_known_extensions: 'false',
    autoload_known_extensions: 'false',
    threads: '2',
    memory_limit: opts.memoryLimit ?? '512MB',
    temp_directory: join(dir, 'spill'),
  });
  const c = await db.connect();
  try {
    return await fn(c, dir);
  } finally {
    c.closeSync();
    db.closeSync();
    await rm(dir, { recursive: true, force: true });
  }
}

export const ROW_COLUMNS =
  "{k:'VARCHAR',id:'VARCHAR',s:'BIGINT',e:'BIGINT',v:'DOUBLE',c:'INTEGER',u:'VARCHAR',agg:'VARCHAR',src:'VARCHAR',bid:'VARCHAR',dev:'VARCHAR',tz:'VARCHAR',extra:'VARCHAR',seq:'BIGINT',batch:'VARCHAR',rid:'VARCHAR'}";

/** Quote a string literal for SQL (only used for local file paths we generate). */
export const lit = (s: string) => `'${s.replace(/'/g, "''")}'`;

/** Writes normalized rows to a zstd Parquet file and returns its bytes. */
export async function rowsToParquet(c: DuckDBConnection, dir: string, rows: Row[], name: string): Promise<string> {
  const src = join(dir, `${name}.ndjson`);
  const out = join(dir, `${name}.parquet`);
  await writeFile(src, rows.map((r) => JSON.stringify(r)).join('\n'));
  await c.run(`COPY (SELECT * FROM read_json(${lit(src)}, format='newline_delimited', columns=${ROW_COLUMNS}) ORDER BY s) TO ${lit(out)} (${PARQUET_OPTIONS})`);
  return out;
}

export async function idsToParquet(c: DuckDBConnection, dir: string, ids: string[], name: string): Promise<string> {
  const src = join(dir, `${name}.ndjson`);
  const out = join(dir, `${name}.parquet`);
  await writeFile(src, ids.map((id) => JSON.stringify({ id })).join('\n'));
  await c.run(`COPY (SELECT * FROM read_json(${lit(src)}, format='newline_delimited', columns={id:'VARCHAR'})) TO ${lit(out)} (FORMAT parquet, COMPRESSION zstd)`);
  return out;
}

/** One row per raw workout point; unused value columns stay NULL (cheap in Parquet). */
export const STREAM_COLUMNS = '{t:\'BIGINT\',v:\'DOUBLE\',lat:\'DOUBLE\',lon:\'DOUBLE\',alt:\'DOUBLE\',spd:\'DOUBLE\',crs:\'DOUBLE\',ha:\'DOUBLE\',va:\'DOUBLE\'}';

/** Divisors tried (smallest first) when storing a column as integers; a column that needs more is stored as DOUBLE. */
const SCALES = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000];
/** Integers beyond this are not safe through JSON and doubles. */
const MAX_SAFE_SCALED = 9e15;

/** The smallest divisor that makes every value an exact multiple of 1/m, or null (then the column stays DOUBLE). */
export function columnScale(values: Iterable<number | null | undefined>): number | null {
  const list: number[] = [];
  for (const v of values) if (v !== null && v !== undefined) list.push(v);
  if (!list.length) return 1;
  for (const m of SCALES) {
    let ok = true;
    for (const v of list) {
      const x = Math.round(v * m);
      if (Math.abs(x) > MAX_SAFE_SCALED || x / m !== v) {
        ok = false;
        break;
      }
    }
    if (ok) return m;
  }
  return null;
}

/** Parquet options for stored data: zstd, and format V2 (delta encoding for integer columns). */
export const PARQUET_OPTIONS = 'FORMAT parquet, COMPRESSION zstd, PARQUET_VERSION V2';

/**
 * Writes raw stream chunks of one (workout, stream) to a zstd Parquet file, sorted by time. Columns whose values
 * are exact short decimals are stored as scaled integers (see FileRef.scale); the others as DOUBLE.
 */
export async function streamToParquet(c: DuckDBConnection, dir: string, chunks: StreamChunk[], name: string): Promise<{ path: string; points: number; scale: Record<string, number> }> {
  const src = join(dir, `${name}.ndjson`);
  const out = join(dir, `${name}.parquet`);
  const scale: Record<string, number> = {};
  for (const col of STREAM_COLS) {
    if (!chunks.some((ch) => ch.cols[col])) continue;
    const m = columnScale(chunks.flatMap((ch) => ch.cols[col] ?? []));
    if (m !== null) scale[col] = m;
  }
  const lines: string[] = [];
  for (const ch of chunks) {
    for (let i = 0; i < ch.t.length; i++) {
      const row: Record<string, number | null> = { t: ch.t[i]! };
      for (const col of STREAM_COLS) {
        const v = ch.cols[col]?.[i] ?? null;
        row[col] = v === null ? null : scale[col] ? Math.round(v * scale[col]!) : v;
      }
      lines.push(JSON.stringify(row));
    }
  }
  await writeFile(src, lines.join('\n'));
  const types = STREAM_COLS.map((col) => `${col}:'${scale[col] ? 'BIGINT' : 'DOUBLE'}'`).join(',');
  await c.run(`COPY (SELECT * FROM read_json(${lit(src)}, format='newline_delimited', columns={t:'BIGINT',${types}}) ORDER BY t) TO ${lit(out)} (${PARQUET_OPTIONS})`);
  return { path: out, points: lines.length, scale };
}
