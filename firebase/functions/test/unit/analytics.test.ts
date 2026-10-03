import { describe, expect, it } from 'vitest';
import { parseProductEvent } from '../../src/analytics/events.js';
import { computeDailyRollups, type AccessRow, type AnalyticsUser } from '../../src/analytics/rollup.js';
import type { ProductEvent } from '../../src/analytics/contract.js';

const DAY = 86_400_000;
const at = (day: number, hour = 12) => Date.UTC(2026, 8, 1 + day, hour);

describe('analytics event privacy boundary', () => {
  it('accepts only the documented typed payloads', () => {
    expect(parseProductEvent({ name: 'app_opened', appVersion: '1.2.3' })).toEqual({ name: 'app_opened', appVersion: '1.2.3' });
    expect(parseProductEvent({ name: 'sync_finished', appVersion: '1.2.3', outcome: 'success', durationMs: 1234 })).toEqual({
      name: 'sync_finished', appVersion: '1.2.3', outcome: 'success', durationMs: 1234,
    });
  });

  it.each(['healthValue', 'route', 'workoutCount', 'freeText', 'email', 'connectorUrl', 'toolArguments'])(
    'rejects sensitive or open-ended field %s', (key) => {
      expect(() => parseProductEvent({ name: 'app_opened', [key]: 'secret' })).toThrow('unsupported analytics field');
    },
  );

  it('rejects invalid sync shapes and client timestamps', () => {
    expect(() => parseProductEvent({ name: 'sync_finished', outcome: 'success' })).toThrow('durationMs');
    expect(() => parseProductEvent({ name: 'app_opened', at: at(0) })).toThrow('unsupported analytics field');
  });
});

describe('analytics cohort rollups', () => {
  it('computes funnel, activity, provider, reliability, and mature retention without identifiers', () => {
    const users: AnalyticsUser[] = [
      { uid: 'u1', analytics: { firstOpenedAt: at(0), healthConnectStartedAt: at(0), healthConnectedAt: at(0), appleLinkedAt: at(1), firstSyncReadyAt: at(1), assistantConnectedAt: at(2), activatedAt: at(2), activationProvider: 'claude', appVersion: '1.0.0' } },
      { uid: 'u2', analytics: { firstOpenedAt: at(0), healthConnectStartedAt: at(0), appVersion: '1.0.0' } },
      { uid: 'deleted', deleting: true, analytics: { firstOpenedAt: at(0), activatedAt: at(0) } },
    ];
    const access: AccessRow[] = [
      { uid: 'u1', provider: 'claude', tool: 'get_workouts', ok: true, at: at(2), ms: 100 },
      { uid: 'u1', provider: 'claude', tool: 'get_workouts', ok: false, at: at(3), ms: 200 },
      { uid: 'u1', provider: 'claude', tool: 'get_workouts', ok: true, at: at(10), ms: 300 },
      { uid: 'u1', provider: 'claude', tool: 'get_workouts', ok: true, at: at(31), ms: 400 },
    ];
    const events: ProductEvent[] = [
      { uid: 'u1', name: 'sync_finished', at: at(3), outcome: 'success', durationMs: 500 },
      { uid: 'u2', name: 'sync_finished', at: at(3), outcome: 'offline', durationMs: 700 },
    ];
    const rows = computeDailyRollups(users, access, events, at(0), at(40), at(40));
    const first = rows[0]!;
    expect(first.cohort.steps).toMatchObject({ first_opened: 2, health_connect_started: 2, health_connected: 1, activated: 1 });
    expect(first.cohort.byAppVersion['1.0.0']?.first_opened).toBe(2);
    const activated = rows.find((r) => r.date === '2026-09-03')!;
    expect(activated.retention).toEqual({ activated: 1, w1Eligible: 1, w1Retained: 1, w4Eligible: 1, w4Retained: 1 });
    const reliability = rows.find((r) => r.date === '2026-09-04')!;
    expect(reliability.reliability).toMatchObject({ syncAttempts: 2, syncSuccesses: 1, syncFailures: 1 });
    expect(reliability.usage).toMatchObject({ calls: 1, successfulCalls: 0, failedCalls: 1, activeUsers: 0 });
    expect(JSON.stringify(rows)).not.toContain('u1');
  });

  it('excludes immature cohorts from retention denominators', () => {
    const activatedAt = at(0);
    const rows = computeDailyRollups([{ uid: 'u', analytics: { firstOpenedAt: at(0), activatedAt } }], [], [], at(0), at(5), activatedAt + 10 * DAY);
    expect(rows[0]!.retention).toEqual({ activated: 1, w1Eligible: 0, w1Retained: 0, w4Eligible: 0, w4Retained: 0 });
  });
});

