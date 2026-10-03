/**
 * KROK product analytics contract.
 *
 * This module is intentionally boring: every accepted event and property is enumerated here.
 * Analytics must never receive Health values, routes, workout metadata, free text, connector
 * secrets, email addresses, or Apple identifiers.
 */

export const PRODUCT_EVENTS = [
  'app_opened',
  'health_connect_started',
  'health_connected',
  'apple_linked',
  'sync_finished',
] as const;

export type ProductEventName = (typeof PRODUCT_EVENTS)[number];
export type SyncOutcome = 'success' | 'error' | 'offline';

export interface ProductEvent {
  name: ProductEventName;
  at: number;
  uid: string;
  appVersion?: string;
  outcome?: SyncOutcome;
  /** Coarse wall time only; never a Health-data time or date. */
  durationMs?: number;
  expireAt?: Date;
}

export const MILESTONE_FIELD: Partial<Record<ProductEventName, string>> = {
  app_opened: 'firstOpenedAt',
  health_connect_started: 'healthConnectStartedAt',
  health_connected: 'healthConnectedAt',
  apple_linked: 'appleLinkedAt',
};

export const METRIC_DEFINITIONS = {
  first_opened: 'Accounts whose authenticated KROK app reported its first open in the selected cohort period.',
  health_connect_started: 'First-open cohort members who tapped Connect to Apple Health.',
  health_connected: 'First-open cohort members for whom Apple Health authorization and KROK registration completed.',
  apple_linked: 'First-open cohort members who successfully linked Sign in with Apple.',
  first_sync_ready: 'First-open cohort members whose first Health data became queryable by an assistant.',
  assistant_connected: 'First-open cohort members whose Claude or ChatGPT connector was used for the first time.',
  activated: 'First-open cohort members with a successful non-setup KROK data tool call. This is the observable proxy for a first AI question answered.',
  query_active_user: 'A distinct activated account with at least one successful KROK data tool call in the period.',
  w1_retention: 'Activated accounts with a successful data tool call 7–13 days after activation, divided by cohorts old enough to observe the full window.',
  w4_retention: 'Activated accounts with a successful data tool call 28–34 days after activation, divided by cohorts old enough to observe the full window.',
  mcp_success_rate: 'Successful KROK MCP data-tool calls divided by all KROK MCP data-tool calls in the period.',
  sync_success_rate: 'Successful app sync attempts divided by all reported sync attempts in the period.',
} as const;

export type MetricName = keyof typeof METRIC_DEFINITIONS;

export const ANALYTICS_INSTRUCTIONS = `KROK Analytics contains aggregate product-usage and reliability metrics only; it never contains Apple Health values or individual-user journeys.
Use metric_definition when a term or denominator may be ambiguous.
Always state the selected period, UTC timezone, data freshness, and denominator. Distinguish counts from rates.
Activation means the first successful non-setup KROK data tool call, the closest observable proxy for a first AI question answered.
Do not make causal claims from comparisons. Call out small samples and retention cohorts that are not yet mature.
Never claim that these tools can identify, inspect, or contact an individual user.`;

