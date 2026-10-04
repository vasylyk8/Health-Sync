import type { ReadinessConfig } from './config.js';
import { normalCdf } from './features.js';
import type { Estimate } from './types.js';

/** Combination of estimators and the likelihood of meeting the goal (spec sections 5.3 and 5.5). Pure. */

export interface Combined {
  /** Inverse-variance weighted mean of the estimators, seconds. */
  centralSeconds: number;
  /** Combined sigma after the correlation floor, seconds. */
  sigmaCombinedSeconds: number;
  sigmaFloorApplied: boolean;
  /** Weighted spread of the estimators around the central estimate (their disagreement), seconds. */
  disagreementSeconds: number;
  /** Sigma including race-day uncertainty, seconds. */
  sigmaTotalSeconds: number;
  weights: { name: string; weight: number }[];
}

export function combineEstimates(estimates: Estimate[], cfg: ReadinessConfig, weeksToRace: number): Combined | null {
  const usable = estimates.filter((e) => e.available && e.predictedSeconds !== null && e.sigmaPct !== null);
  if (!usable.length) return null;
  const parts = usable.map((e) => {
    const sigma = (e.sigmaPct! / 100) * e.predictedSeconds!;
    return { name: e.name, t: e.predictedSeconds!, sigma, w: 1 / (sigma * sigma) };
  });
  const wSum = parts.reduce((n, p) => n + p.w, 0);
  const central = parts.reduce((n, p) => n + p.w * p.t, 0) / wSum;
  const independent = Math.sqrt(1 / wSum);
  // The estimators share one runner, so they are not independent: do not let the combination look more certain than the best of them.
  const floor = cfg.combine.sigmaFloorFactor * Math.min(...parts.map((p) => p.sigma));
  // Estimators that disagree are less certain than each one claims: add their weighted spread, in quadrature.
  const between = Math.sqrt(parts.reduce((n, p) => n + (p.w / wSum) * (p.t - central) ** 2, 0)) * cfg.combine.disagreementFactor;
  const sigmaCombined = Math.sqrt(Math.max(independent, floor) ** 2 + between ** 2);
  const raceDay = (cfg.combine.raceDaySigmaPct / 100) * central;
  const far = weeksToRace > cfg.windows.raceWindowWeeks ? (cfg.combine.farRaceSigmaPct / 100) * central : 0;
  return {
    centralSeconds: central,
    sigmaCombinedSeconds: sigmaCombined,
    sigmaFloorApplied: floor > independent,
    disagreementSeconds: between,
    sigmaTotalSeconds: Math.sqrt(sigmaCombined ** 2 + raceDay ** 2 + far ** 2),
    weights: parts.map((p) => ({ name: p.name, weight: p.w / wSum })),
  };
}

export interface Likelihood {
  probability: number;
  score: number;
  label: string;
}

export const labelOf = (score: number, cfg: ReadinessConfig): string => cfg.likelihood.labels.find(([max]) => score <= max)?.[1] ?? cfg.likelihood.labels[cfg.likelihood.labels.length - 1]![1];

/** P(finish <= goal) with a normal error around the central estimate. */
export function likelihood(goalSeconds: number, centralSeconds: number, sigmaSeconds: number, cfg: ReadinessConfig): Likelihood {
  const probability = normalCdf((goalSeconds - centralSeconds) / sigmaSeconds);
  const score = Math.round(10 * probability * 10) / 10;
  return { probability, score, label: labelOf(score, cfg) };
}

/** Central estimate with the cap-limited durability modifier applied (percent added to the time). */
export const applyModifier = (centralSeconds: number, pct: number): number => centralSeconds * (1 + pct / 100);

export function range80(centralSeconds: number, sigmaSeconds: number, cfg: ReadinessConfig): [number, number] {
  return [centralSeconds - cfg.combine.z80 * sigmaSeconds, centralSeconds + cfg.combine.z80 * sigmaSeconds];
}
