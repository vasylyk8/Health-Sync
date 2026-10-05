import coverageJson from './generated/coverage.json' with { type: 'json' };

export const REGION = 'europe-west1';

/** Buckets are created by provisioning; names derive from the project id. */
export const incomingBucketName = (projectId: string) => `${projectId}-incoming`;
export const dataBucketName = (projectId: string) => `${projectId}-data`;

export const PROVIDERS = ['claude', 'chatgpt'] as const;
export type Provider = (typeof PROVIDERS)[number];

export const LIMITS = {
  /** Compressed upload size accepted per batch. */
  maxBatchBytes: 5 * 1024 * 1024,
  /** Decompressed size guard (zip-bomb protection). */
  maxBatchInflatedBytes: 120 * 1024 * 1024,
  maxRecordsPerBatch: 200_000,
  maxRecordLineBytes: 2 * 1024 * 1024,
  /** Largest serialized tool result returned to the AI (~15k tokens). */
  maxResponseBytes: 60 * 1024,
  /** Largest total Parquet bytes a single tool call may download. */
  maxScanBytes: 400 * 1024 * 1024,
  /** Wall-clock deadline for one MCP request (Hosting cuts at 60 s). */
  requestDeadlineMs: 45_000,
  mcpRequestsPerMinute: 120,
  invalidTokenPerIpPerMinute: 30,
  staleAfterMs: 24 * 3600 * 1000,
  /** Longest a merged-totals window may trail the latest check and still count as current. */
  statsMaxLagMs: 6 * 3600 * 1000,
  purgeAfterMs: 365 * 24 * 3600 * 1000,
  accessLogTtlMs: 90 * 24 * 3600 * 1000,
} as const;

export type Aggregation = 'cumulative' | 'discrete';

export interface CoverageEntry {
  id: string;
  kind: string;
  agg?: Aggregation;
  unit?: string;
  group: string;
  record: string;
  /** Consent category the type belongs to (default "core"). */
  category?: string;
}

export interface CategoryDef { id: string; label: string; default?: boolean }
export interface EventTypeDef { name: string; id: string; kind: string; category: string; unit?: string; dense?: boolean }
export interface DailyMetricDef { key: string; category?: string; outputs?: string[] }
export interface HourlyMetricDef { name: string; id: string; unit: string; cols: string[] }

interface Coverage {
  version: number;
  types: CoverageEntry[];
  categories: CategoryDef[];
  eventTypes: EventTypeDef[];
  hourlyMetrics: HourlyMetricDef[];
  dailyMetrics: DailyMetricDef[];
}

export const COVERAGE: Coverage = coverageJson as never;
export const TYPES_BY_ID = new Map(COVERAGE.types.map((t) => [t.id, t]));

/** Consent categories: what a user can switch on. Data of a switched-off category is neither accepted nor served. */
export const CATEGORIES = COVERAGE.categories;
export const CATEGORY_IDS = new Set(CATEGORIES.map((c) => c.id));
export const DEFAULT_CATEGORIES: string[] = CATEGORIES.filter((c) => c.default).map((c) => c.id);
export const EVENT_TYPES = new Map(COVERAGE.eventTypes.map((e) => [e.name, e]));
export const HOURLY_METRICS = new Map(COVERAGE.hourlyMetrics.map((h) => [h.name, h]));

/**
 * Batch types and consent categories that were removed from the product. Old app builds may still send the
 * batches; the server acknowledges and drops them, and a scheduled job deletes what was stored earlier.
 */
export const RETIRED_TYPES: ReadonlySet<string> = new Set(['_events_heart', '_events_devices', '_events_mind', '_events_medications', '_daily_mind']);
export const RETIRED_CATEGORIES: ReadonlySet<string> = new Set(['heart', 'devices', 'mind', 'medications']);

/** Consent category of a batch type ("core" unless the coverage file says otherwise). */
export const categoryOfType = (type: string): string => TYPES_BY_ID.get(type)?.category ?? 'core';

/** Category of every daily metric output key ("core" unless listed). */
export const DAILY_KEY_CATEGORY = new Map<string, string>(
  COVERAGE.dailyMetrics.flatMap((m) => [m.key, ...(m.outputs ?? [])].map((k) => [k, m.category ?? 'core'] as [string, string])),
);

/** Friendly name for the AI: HKQuantityTypeIdentifierHeartRate -> HeartRate. */
export function shortName(id: string): string {
  if (id === 'HKWorkoutTypeIdentifier') return 'Workouts';
  if (id === '_daily') return 'DailyContext';
  return id.replace(/^HK(QuantityTypeIdentifier|CategoryTypeIdentifier|DataTypeIdentifier|CorrelationTypeIdentifier|ScoredAssessmentTypeIdentifier)/, '').replace(/^HK/, '');
}

const BY_SHORT = new Map(COVERAGE.types.map((t) => [shortName(t.id).toLowerCase(), t]));

/** Accepts either the full HealthKit identifier or the short name (case-insensitive). */
export function resolveType(name: string): CoverageEntry | undefined {
  return TYPES_BY_ID.get(name) ?? BY_SHORT.get(name.toLowerCase());
}
