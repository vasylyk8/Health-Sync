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
}

export const COVERAGE: { version: number; types: CoverageEntry[] } = coverageJson as never;
export const TYPES_BY_ID = new Map(COVERAGE.types.map((t) => [t.id, t]));

/** Friendly name for the AI: HKQuantityTypeIdentifierHeartRate -> HeartRate. */
export function shortName(id: string): string {
  return id.replace(/^HK(QuantityTypeIdentifier|CategoryTypeIdentifier|DataTypeIdentifier|CorrelationTypeIdentifier|ScoredAssessmentTypeIdentifier)/, '').replace(/^HK/, '');
}

const BY_SHORT = new Map(COVERAGE.types.map((t) => [shortName(t.id).toLowerCase(), t]));

/** Accepts either the full HealthKit identifier or the short name (case-insensitive). */
export function resolveType(name: string): CoverageEntry | undefined {
  return TYPES_BY_ID.get(name) ?? BY_SHORT.get(name.toLowerCase());
}
