import type { ReadinessConfig } from './config.js';
import type { Adjustment, ReadinessInputs } from './types.js';

/**
 * Context adjustments: heat, course profile and the super-shoes what-if. Percentages of the finish time, positive = slower.
 * Heuristics with weak evidence; each one also widens sigma because the adjustment itself is uncertain. Pure.
 */

/** Slowing (percent of the time) of a marathon run at an air temperature, relative to a mild reference temperature. */
export function heatPenaltyPct(tempC: number, cfg: ReadinessConfig): number {
  const h = cfg.adjust.heat;
  return Math.min(h.capPct, Math.max(0, tempC - h.refC) * h.pctPerC);
}

export function buildAdjustments(ctx: ReadinessInputs['context'], cfg: ReadinessConfig): Adjustment[] {
  const a = cfg.adjust;
  const out: Adjustment[] = [];
  if (ctx.course !== null) {
    const pct = a.course[ctx.course];
    out.push({ name: 'course', pct, sigmaPct: pct * a.sigmaFraction.course, detail: ctx.course === 'flat' ? 'flat course: no adjustment (source efforts are assumed to be on roughly flat terrain)' : `${ctx.course} course relative to flat` });
  }
  if (ctx.expectedTempC !== null) {
    const pct = heatPenaltyPct(ctx.expectedTempC, cfg);
    out.push({ name: 'expected_race_day_heat', pct, sigmaPct: pct * a.sigmaFraction.heat, detail: pct > 0 ? `expected ${ctx.expectedTempC} degC, ${pct.toFixed(1)}% slower than at ${a.heat.refC} degC or cooler` : `expected ${ctx.expectedTempC} degC: no heat penalty (at or below ${a.heat.refC} degC)` });
  }
  if (ctx.newSuperShoes) {
    const pct = a.superShoesPct;
    out.push({ name: 'super_shoes_what_if', pct, sigmaPct: Math.abs(pct) * a.sigmaFraction.shoes, detail: `what-if: carbon-plated shoes not worn for the source efforts; population average about ${Math.abs(pct)}% faster, individual response varies from a loss to a large gain` });
  }
  return out;
}

/** Product of the adjustments applied to a time. */
export const applyAdjustments = (seconds: number, adjustments: Adjustment[]): number => adjustments.reduce((t, x) => t * (1 + x.pct / 100), seconds);

/** Extra sigma (seconds) from the uncertainty of the adjustments, in quadrature. */
export const adjustmentSigmaSeconds = (centralSeconds: number, adjustments: Adjustment[]): number => Math.sqrt(adjustments.reduce((n, x) => n + ((x.sigmaPct / 100) * centralSeconds) ** 2, 0));
