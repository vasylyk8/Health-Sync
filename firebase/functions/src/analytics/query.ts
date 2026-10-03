import type { Firestore } from 'firebase-admin/firestore';
import { METRIC_DEFINITIONS, type MetricName } from './contract.js';
import { DURATION_BUCKETS_MS, STEP_NAMES, type DailyRollup } from './rollup.js';

const MAX_DAYS = 90;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export class AnalyticsQueryError extends Error {
  constructor(readonly code: 'bad_request' | 'no_data', message: string) { super(message); }
}

function range(startDate: string, endDate: string): { start: string; end: string; days: number } {
  if (!DATE_RE.test(startDate) || !DATE_RE.test(endDate)) throw new AnalyticsQueryError('bad_request', 'Dates must use YYYY-MM-DD.');
  const start = Date.parse(`${startDate}T00:00:00Z`), end = Date.parse(`${endDate}T00:00:00Z`);
  const days = Math.floor((end - start) / 86_400_000) + 1;
  if (!Number.isFinite(days) || days < 1 || days > MAX_DAYS) throw new AnalyticsQueryError('bad_request', `Choose a range from 1 to ${MAX_DAYS} days.`);
  return { start: startDate, end: endDate, days };
}

async function rows(db: Firestore, startDate: string, endDate: string): Promise<DailyRollup[]> {
  const r = range(startDate, endDate);
  const snap = await db.collection('analyticsRollups').where('date', '>=', r.start).where('date', '<=', r.end).orderBy('date').get();
  if (snap.empty) throw new AnalyticsQueryError('no_data', 'No analytics rollups exist for that period yet.');
  return snap.docs.map((d) => d.data() as DailyRollup);
}

const sum = (list: number[]) => list.reduce((a, b) => a + b, 0);
const rate = (a: number, b: number) => b ? a / b : null;
const fresh = (rs: DailyRollup[]) => new Date(Math.max(...rs.map((r) => r.generatedAt))).toISOString();
const percentile = (rs: DailyRollup[], field: 'syncDurationBuckets' | 'mcpDurationBuckets', q: number) => {
  const buckets = DURATION_BUCKETS_MS.map((_, i) => sum(rs.map((r) => r.reliability[field]?.[i] ?? 0)));
  const total = sum(buckets); if (!total) return null;
  const target = Math.ceil(total * q); let seen = 0;
  for (let i = 0; i < buckets.length; i++) { seen += buckets[i]!; if (seen >= target) return DURATION_BUCKETS_MS[i]; }
  return DURATION_BUCKETS_MS.at(-1)!;
};

export async function activationFunnel(db: Firestore, startDate: string, endDate: string, appVersion?: string) {
  const rs = await rows(db, startDate, endDate);
  if (appVersion && !/^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$/.test(appVersion)) throw new AnalyticsQueryError('bad_request', 'app_version is invalid.');
  const steps = Object.fromEntries(STEP_NAMES.map((name) => [name, sum(rs.map((r) => appVersion ? (r.cohort.byAppVersion[appVersion]?.[name] ?? 0) : r.cohort.steps[name]))]));
  const first = steps.first_opened as number;
  return { period: { start_date: startDate, end_date: endDate, timezone: 'UTC' }, app_version: appVersion ?? null,
    steps: STEP_NAMES.map((name) => ({ name, users: steps[name], rate_from_first_open: rate(steps[name] as number, first) })),
    data_fresh_as_of: fresh(rs) };
}

export async function usageOverview(db: Firestore, startDate: string, endDate: string) {
  const rs = await rows(db, startDate, endDate);
  const calls = sum(rs.map((r) => r.usage.calls)), success = sum(rs.map((r) => r.usage.successfulCalls));
  const byProvider: Record<string, { calls: number; active_user_days: number }> = {};
  for (const r of rs) for (const [p, v] of Object.entries(r.usage.byProvider)) {
    const out = byProvider[p] ??= { calls: 0, active_user_days: 0 }; out.calls += v.calls; out.active_user_days += v.activeUsers;
  }
  return { period: { start_date: startDate, end_date: endDate, timezone: 'UTC' },
    activated_users: sum(rs.map((r) => r.retention.activated)), active_user_days: sum(rs.map((r) => r.usage.activeUsers)),
    successful_tool_calls: success, failed_tool_calls: calls - success, mcp_success_rate: rate(success, calls), by_provider: byProvider,
    notes: ['active_user_days sums each day\'s distinct active users; a person active on two days counts twice.'], data_fresh_as_of: fresh(rs) };
}

export async function retention(db: Firestore, startDate: string, endDate: string) {
  const rs = await rows(db, startDate, endDate);
  const activated = sum(rs.map((r) => r.retention.activated));
  const w1e = sum(rs.map((r) => r.retention.w1Eligible)), w1r = sum(rs.map((r) => r.retention.w1Retained));
  const w4e = sum(rs.map((r) => r.retention.w4Eligible)), w4r = sum(rs.map((r) => r.retention.w4Retained));
  return { activation_cohort: { start_date: startDate, end_date: endDate, timezone: 'UTC', activated },
    w1: { eligible: w1e, retained: w1r, rate: rate(w1r, w1e), window: 'days 7–13 after activation' },
    w4: { eligible: w4e, retained: w4r, rate: rate(w4r, w4e), window: 'days 28–34 after activation' },
    notes: ['Immature cohorts are excluded from each denominator.'], data_fresh_as_of: fresh(rs) };
}

export async function reliability(db: Firestore, startDate: string, endDate: string, appVersion?: string) {
  const rs = await rows(db, startDate, endDate);
  if (appVersion && !/^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$/.test(appVersion)) throw new AnalyticsQueryError('bad_request', 'app_version is invalid.');
  const attempts = sum(rs.map((r) => appVersion ? (r.reliability.syncByAppVersion?.[appVersion]?.attempts ?? 0) : r.reliability.syncAttempts));
  const syncOk = sum(rs.map((r) => appVersion ? (r.reliability.syncByAppVersion?.[appVersion]?.successes ?? 0) : r.reliability.syncSuccesses));
  const calls = sum(rs.map((r) => r.usage.calls)), mcpOk = sum(rs.map((r) => r.usage.successfulCalls));
  const syncN = sum(rs.map((r) => appVersion ? (r.reliability.syncByAppVersion?.[appVersion]?.durationCount ?? 0) : r.reliability.syncDurationCount));
  const syncMs = sum(rs.map((r) => appVersion ? (r.reliability.syncByAppVersion?.[appVersion]?.durationSumMs ?? 0) : r.reliability.syncDurationSumMs));
  const mcpN = sum(rs.map((r) => r.reliability.mcpDurationCount)), mcpMs = sum(rs.map((r) => r.reliability.mcpDurationSumMs));
  const syncBuckets = appVersion ? DURATION_BUCKETS_MS.map((_, i) => sum(rs.map((r) => r.reliability.syncByAppVersion?.[appVersion]?.durationBuckets?.[i] ?? 0))) : null;
  const syncP95 = syncBuckets ? (() => { const total = sum(syncBuckets); if (!total) return null; const target = Math.ceil(total * 0.95); let seen = 0; for (let i = 0; i < syncBuckets.length; i++) { seen += syncBuckets[i]!; if (seen >= target) return DURATION_BUCKETS_MS[i]; } return DURATION_BUCKETS_MS.at(-1)!; })() : percentile(rs, 'syncDurationBuckets', 0.95);
  return { period: { start_date: startDate, end_date: endDate, timezone: 'UTC' }, app_version: appVersion ?? null,
    sync: { attempts, successes: syncOk, failures: attempts - syncOk, success_rate: rate(syncOk, attempts), mean_duration_ms: syncN ? Math.round(syncMs / syncN) : null, p95_duration_upper_bound_ms: syncP95 },
    mcp: { calls, successes: mcpOk, failures: calls - mcpOk, success_rate: rate(mcpOk, calls), mean_duration_ms: mcpN ? Math.round(mcpMs / mcpN) : null, p95_duration_upper_bound_ms: percentile(rs, 'mcpDurationBuckets', 0.95) },
    notes: ['Crash-free users remain in Firebase Crashlytics and are not joined to KROK analytics.', ...(appVersion ? ['The app-version filter applies to sync only; MCP requests do not carry an app version.'] : [])], data_fresh_as_of: fresh(rs) };
}

export function metricDefinition(name: MetricName) { return { metric: name, definition: METRIC_DEFINITIONS[name], timezone: 'UTC' }; }
