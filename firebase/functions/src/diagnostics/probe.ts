import { createHash, randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parseBatch, STREAM_COLS } from '../ingest/batch.js';
import { ingestObject } from '../ingest/ingest.js';
import { lit, withDuck } from '../query/duck.js';
import { rows } from '../query/common.js';
import type { BlobStore, UserDoc } from '../store/types.js';
import { MemoryMeta } from './isolated-meta.js';

/** No shared state, production buckets, Firestore writes or persisted Health payloads. */
class MemoryBlobs implements BlobStore {
  values = new Map<string, Buffer>();
  async read(path: string) { const b = this.values.get(path); if (!b) throw new Error('missing diagnostic blob'); return b; }
  async write(path: string, b: Buffer) { this.values.set(path, b); }
  async download(path: string, local: string) { await writeFile(local, await this.read(path)); }
  async delete(path: string) { this.values.delete(path); }
  async exists(path: string) { return this.values.has(path); }
  async list(prefix: string) { return [...this.values.keys()].filter(p => p.startsWith(prefix)); }
  async deletePrefix(prefix: string) { for (const p of await this.list(prefix)) this.values.delete(p); }
}
export class DiagnosticProbeError extends Error {}
export function validateProbe(uid: string, input: unknown): { gz: Buffer; sha256: string } {
  if (!input || typeof input !== 'object') throw new DiagnosticProbeError('invalid request');
  const d = input as Record<string, unknown>;
  if (d.expectedUid !== uid) throw new DiagnosticProbeError('account mismatch');
  if (typeof d.gz !== 'string' || d.gz.length === 0 || d.gz.length > 7_000_000 || !/^[A-Za-z0-9+/]*={0,2}$/.test(d.gz)) throw new DiagnosticProbeError('invalid payload');
  const gz = Buffer.from(d.gz, 'base64');
  if (gz.toString('base64') !== d.gz || gz.length > 5 * 1024 * 1024 || typeof d.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(d.sha256) || createHash('sha256').update(gz).digest('hex') !== d.sha256) throw new DiagnosticProbeError('checksum or size mismatch');
  return { gz, sha256: d.sha256 };
}
const normalize = (v: unknown): unknown => typeof v === 'bigint' ? Number(v) : v === undefined ? null : v;
function difference(a: unknown, b: unknown): number {
  a = normalize(a); b = normalize(b);
  if (a === b) return 0;
  if (typeof a === 'number' && typeof b === 'number') return Math.abs(a - b);
  return Infinity;
}

export async function probeBatch(uid: string, input: unknown, user: UserDoc) {
  const started = performance.now(), { gz, sha256 } = validateProbe(uid, input);
  const parsed = parseBatch(gz), parseMs = performance.now() - started;
  if (parsed.skipped) throw new DiagnosticProbeError('invalid records would be skipped');
  const sandbox = 'diag_' + randomUUID().replace(/-/g, ''), meta = new MemoryMeta(), incoming = new MemoryBlobs(), data = new MemoryBlobs();
  meta.addUser(sandbox, { categories: user.categories, tz: user.tz });
  const path = `incoming/${sandbox}/${parsed.header.batchId}.ndjson.gz`;
  await incoming.write(path, gz);
  const ingestStart = performance.now();
  const outcome = await ingestObject(path, { incoming, data, meta }, { sha256 });
  const ingestMs = performance.now() - ingestStart;
  if (outcome !== 'published') throw new DiagnosticProbeError('diagnostic batch not published');
  const repeatStart = performance.now();
  await incoming.write(path, gz);
  const duplicate = await ingestObject(path, { incoming, data, meta }, { sha256 });
  if (duplicate !== 'duplicate') throw new DiagnosticProbeError('idempotency regression');
  const duplicateMs = performance.now() - repeatStart, readStart = performance.now();
  let readbackRows = 0, maxDelta = 0;
  await withDuck(async (c, dir) => {
    let index = 0;
    for (const [partition, expected] of parsed.partitions) {
      const man = await meta.getManifest(sandbox, parsed.header.type), refs = man?.files[partition] ?? [];
      const actual: Record<string, unknown>[] = [];
      for (const ref of refs) { const local = join(dir, `${index++}.parquet`); await data.download(ref.path, local); actual.push(...await rows(c, `SELECT * FROM read_parquet(${lit(local)}) ORDER BY s`)); }
      // Canonical row association, including duplicate occurrences, rather than trusting total counts.
      const keys = ['k', 'id', 's', 'e', 'u', 'agg', 'src', 'bid', 'dev', 'tz', 'extra', 'seq', 'batch', 'rid'];
      const signature = (r: Record<string, unknown>) => JSON.stringify(keys.map(k => normalize(r[k])));
      const buckets = new Map<string, Record<string, unknown>[]>();
      for (const row of actual) { const key = signature(row); const list = buckets.get(key) ?? []; list.push(row); buckets.set(key, list); }
      for (const row of expected) {
        const key = signature(row as unknown as Record<string, unknown>), list = buckets.get(key);
        if (!list?.length) throw new DiagnosticProbeError('missing row');
        const item = list.pop()!;
        for (const k of ['v', 'v2', 'v3', 'c']) maxDelta = Math.max(maxDelta, difference((row as unknown as Record<string, unknown>)[k], item[k]));
      }
      if ([...buckets.values()].some(a => a.length)) throw new DiagnosticProbeError('extra row');
      readbackRows += actual.length;
    }
    for (const workout of await meta.listWorkoutData(sandbox)) {
      for (const [streamName, stream] of Object.entries(workout.streams)) {
        const expected = parsed.streams.filter(s => s.wid === workout.wid && s.st === streamName).flatMap(s => s.t.map((t, i) => Object.fromEntries([['t', t], ...STREAM_COLS.map(k => [k, s.cols[k]?.[i] ?? null])]))).sort((a, b) => Number(a.t) - Number(b.t));
        const actual: Record<string, unknown>[] = [];
        for (const ref of stream.files) {
          const local = join(dir, `${index++}.parquet`); await data.download(ref.path, local);
          const columns = ['t', ...STREAM_COLS].map(k => ref.scale?.[k] ? `${k} / ${ref.scale[k]} AS ${k}` : k).join(',');
          actual.push(...await rows(c, `SELECT ${columns} FROM read_parquet(${lit(local)}) ORDER BY t`));
        }
        actual.sort((a, b) => Number(a.t) - Number(b.t));
        if (actual.length !== expected.length) throw new DiagnosticProbeError('stream count mismatch');
        for (let i = 0; i < expected.length; i++) for (const k of ['t', ...STREAM_COLS]) maxDelta = Math.max(maxDelta, difference(expected[i]![k], actual[i]![k]));
        readbackRows += actual.length;
      }
    }
  }, { memoryLimit: '384MB' });
  if (!Number.isFinite(maxDelta) || maxDelta > 1e-9) throw new DiagnosticProbeError('readback value regression');
  // All buffers and private Parquet files are request-local; withDuck removes its temporary directory.
  return { schema: 1, accountVerified: true, sha256, bytes: gz.length, records: parsed.recordCount, readbackRows, maxDelta, duplicateVerified: true, parseMs, ingestMs, duplicateMs, readbackMs: performance.now() - readStart, totalMs: performance.now() - started };
}
