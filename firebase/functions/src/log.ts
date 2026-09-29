/**
 * Structured logging that never includes health values, tool arguments, tokens or raw errors
 * from user data. Only whitelisted scalar fields are emitted.
 */
type Fields = Record<string, string | number | boolean | null | undefined>;

const SAFE_KEYS = new Set([
  'uid', 'batchId', 'type', 'result', 'records', 'reason', 'tool', 'provider', 'ms', 'bytes',
  'status', 'files', 'partition', 'job', 'count', 'code', 'op', 'removed', 'generation',
  'mode', 'readMs', 'uploadMs', 'types',
]);

function emit(severity: string, message: string, fields: Fields = {}) {
  if (process.env.HS_LOG === 'off') return;
  const safe: Fields = {};
  for (const [k, v] of Object.entries(fields)) {
    if (!SAFE_KEYS.has(k)) continue;
    safe[k] = typeof v === 'string' ? v.slice(0, 200) : v;
  }
  // Cloud Logging parses one JSON object per line.
  process.stdout.write(JSON.stringify({ severity, message, ...safe }) + '\n');
}

export const log = {
  info: (m: string, f?: Fields) => emit('INFO', m, f),
  warn: (m: string, f?: Fields) => emit('WARNING', m, f),
  error: (m: string, f?: Fields) => emit('ERROR', m, f),
};
