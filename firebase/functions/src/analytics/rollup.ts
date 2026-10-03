import type { Firestore } from 'firebase-admin/firestore';
import type { UserDoc } from '../store/types.js';
import type { ProductEvent } from './contract.js';

const DAY = 86_400_000;
const STEP_FIELDS = ['firstOpenedAt', 'healthConnectStartedAt', 'healthConnectedAt', 'appleLinkedAt', 'firstSyncReadyAt', 'assistantConnectedAt', 'activatedAt'] as const;
export const STEP_NAMES = ['first_opened', 'health_connect_started', 'health_connected', 'apple_linked', 'first_sync_ready', 'assistant_connected', 'activated'] as const;

type StepName = (typeof STEP_NAMES)[number];
type Counts = Record<StepName, number>;

export interface AccessRow { uid: string; provider: string; tool: string; ok: boolean; at: number; ms?: number }
export interface AnalyticsUser { uid: string; analytics?: UserDoc['analytics']; deleting?: boolean }

export interface DailyRollup {
  date: string;
  generatedAt: number;
  cohort: { steps: Counts; byProvider: Record<string, Counts>; byAppVersion: Record<string, Counts> };
  usage: { activeUsers: number; calls: number; successfulCalls: number; failedCalls: number; byProvider: Record<string, { activeUsers: number; calls: number }> };
  reliability: { syncAttempts: number; syncSuccesses: number; syncFailures: number; syncDurationCount: number; syncDurationSumMs: number; syncDurationBuckets: number[]; mcpDurationCount: number; mcpDurationSumMs: number; mcpDurationBuckets: number[];
    syncByAppVersion: Record<string, { attempts: number; successes: number; durationCount: number; durationSumMs: number; durationBuckets: number[] }> };
  retention: { activated: number; w1Eligible: number; w1Retained: number; w4Eligible: number; w4Retained: number };
}

const blankCounts = (): Counts => Object.fromEntries(STEP_NAMES.map((k) => [k, 0])) as Counts;
export const DURATION_BUCKETS_MS = [100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000, 60_000, 300_000, 900_000, 3_600_000] as const;
const blankBuckets = () => DURATION_BUCKETS_MS.map(() => 0);
const addDuration = (buckets: number[], ms: number) => {
  const i = DURATION_BUCKETS_MS.findIndex((limit) => ms <= limit);
  buckets[i < 0 ? buckets.length - 1 : i] = (buckets[i < 0 ? buckets.length - 1 : i] ?? 0) + 1;
};
const dateKey = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const dayStart = (ms: number) => Date.parse(`${dateKey(ms)}T00:00:00.000Z`);

function blank(date: string, generatedAt: number): DailyRollup {
  return { date, generatedAt, cohort: { steps: blankCounts(), byProvider: {}, byAppVersion: {} },
    usage: { activeUsers: 0, calls: 0, successfulCalls: 0, failedCalls: 0, byProvider: {} },
    reliability: { syncAttempts: 0, syncSuccesses: 0, syncFailures: 0, syncDurationCount: 0, syncDurationSumMs: 0, syncDurationBuckets: blankBuckets(), mcpDurationCount: 0, mcpDurationSumMs: 0, mcpDurationBuckets: blankBuckets(), syncByAppVersion: {} },
    retention: { activated: 0, w1Eligible: 0, w1Retained: 0, w4Eligible: 0, w4Retained: 0 } };
}

/** Pure rollup calculation; sets are discarded before output so documents contain no identifiers. */
export function computeDailyRollups(users: AnalyticsUser[], access: AccessRow[], events: ProductEvent[], start: number, end: number, generatedAt = Date.now()): DailyRollup[] {
  const first = dayStart(start), last = dayStart(end);
  const days = new Map<string, DailyRollup>();
  const active = new Map<string, Set<string>>();
  const providerActive = new Map<string, Map<string, Set<string>>>();
  for (let t = first; t <= last; t += DAY) days.set(dateKey(t), blank(dateKey(t), generatedAt));

  const successesByUid = new Map<string, number[]>();
  for (const row of access) {
    if (row.ok) {
      const list = successesByUid.get(row.uid) ?? [];
      list.push(row.at); successesByUid.set(row.uid, list);
    }
    if (row.at < first || row.at >= last + DAY) continue;
    const key = dateKey(row.at), out = days.get(key);
    if (!out) continue;
    out.usage.calls++;
    if (row.ok) out.usage.successfulCalls++; else out.usage.failedCalls++;
    if (typeof row.ms === 'number' && row.ms >= 0) { out.reliability.mcpDurationCount++; out.reliability.mcpDurationSumMs += row.ms; addDuration(out.reliability.mcpDurationBuckets, row.ms); }
    const by = out.usage.byProvider[row.provider] ??= { activeUsers: 0, calls: 0 };
    by.calls++;
    if (row.ok) {
      const s = active.get(key) ?? new Set<string>(); s.add(row.uid); active.set(key, s);
      const pm = providerActive.get(key) ?? new Map<string, Set<string>>();
      const ps = pm.get(row.provider) ?? new Set<string>(); ps.add(row.uid); pm.set(row.provider, ps); providerActive.set(key, pm);
    }
  }

  for (const event of events) {
    if (event.name !== 'sync_finished' || event.at < first || event.at >= last + DAY) continue;
    const out = days.get(dateKey(event.at)); if (!out) continue;
    out.reliability.syncAttempts++;
    if (event.outcome === 'success') out.reliability.syncSuccesses++; else out.reliability.syncFailures++;
    if (typeof event.durationMs === 'number') { out.reliability.syncDurationCount++; out.reliability.syncDurationSumMs += event.durationMs; addDuration(out.reliability.syncDurationBuckets, event.durationMs); }
    if (event.appVersion) {
      const by = out.reliability.syncByAppVersion[event.appVersion] ??= { attempts: 0, successes: 0, durationCount: 0, durationSumMs: 0, durationBuckets: blankBuckets() };
      by.attempts++; if (event.outcome === 'success') by.successes++;
      if (typeof event.durationMs === 'number') { by.durationCount++; by.durationSumMs += event.durationMs; addDuration(by.durationBuckets, event.durationMs); }
    }
  }

  for (const user of users) {
    if (user.deleting || !user.analytics?.firstOpenedAt) continue;
    const out = days.get(dateKey(user.analytics.firstOpenedAt));
    if (out) {
      STEP_FIELDS.forEach((field, i) => { const name = STEP_NAMES[i]!; if (user.analytics?.[field] !== undefined) out.cohort.steps[name]++; });
      if (user.analytics.activationProvider) {
        const counts = out.cohort.byProvider[user.analytics.activationProvider] ??= blankCounts();
        STEP_FIELDS.forEach((field, i) => { const name = STEP_NAMES[i]!; if (user.analytics?.[field] !== undefined) counts[name]++; });
      }
      if (user.analytics.appVersion) {
        const counts = out.cohort.byAppVersion[user.analytics.appVersion] ??= blankCounts();
        STEP_FIELDS.forEach((field, i) => { const name = STEP_NAMES[i]!; if (user.analytics?.[field] !== undefined) counts[name]++; });
      }
    }
    const activated = user.analytics.activatedAt;
    if (!activated) continue;
    const cohort = days.get(dateKey(activated));
    if (!cohort) continue;
    cohort.retention.activated++;
    const hits = successesByUid.get(user.uid) ?? [];
    if (generatedAt >= activated + 14 * DAY) {
      cohort.retention.w1Eligible++;
      if (hits.some((t) => t >= activated + 7 * DAY && t < activated + 14 * DAY)) cohort.retention.w1Retained++;
    }
    if (generatedAt >= activated + 35 * DAY) {
      cohort.retention.w4Eligible++;
      if (hits.some((t) => t >= activated + 28 * DAY && t < activated + 35 * DAY)) cohort.retention.w4Retained++;
    }
  }

  for (const [key, ids] of active) days.get(key)!.usage.activeUsers = ids.size;
  for (const [key, providers] of providerActive) for (const [provider, ids] of providers) {
    const out = days.get(key)!.usage.byProvider[provider] ??= { activeUsers: 0, calls: 0 };
    out.activeUsers = ids.size;
  }
  return [...days.values()].sort((a, b) => a.date.localeCompare(b.date));
}

export async function rebuildAnalyticsRollups(db: Firestore, now = Date.now(), days = 90): Promise<{ days: number; users: number; access: number; events: number }> {
  const start = dayStart(now) - (days - 1) * DAY;
  const [userSnap, accessSnap, eventSnap] = await Promise.all([
    db.collection('users').select('analytics', 'deleting').get(),
    db.collection('accessLog').where('at', '>=', start).get(),
    db.collection('productEvents').where('at', '>=', start).get(),
  ]);
  const users = userSnap.docs.map((d) => ({ uid: d.id, ...(d.data() as Omit<AnalyticsUser, 'uid'>) }));
  const access = accessSnap.docs.map((d) => d.data() as AccessRow);
  const events = eventSnap.docs.map((d) => d.data() as ProductEvent);
  const rollups = computeDailyRollups(users, access, events, start, now, now);
  for (let i = 0; i < rollups.length; i += 400) {
    const batch = db.batch();
    for (const row of rollups.slice(i, i + 400)) batch.set(db.collection('analyticsRollups').doc(row.date), row);
    await batch.commit();
  }
  return { days: rollups.length, users: users.length, access: access.length, events: events.length };
}

export const analyticsDateKey = dateKey;
