import type { ReadinessConfig } from './config.js';
import type { ConfidenceComponent, RaceEffort } from './types.js';

/**
 * Confidence % (spec section 5.6): how complete and trustworthy the underlying data is. It is reported separately from the
 * likelihood and never shrinks the score; thin data already widens sigma through the estimators. Pure.
 */

export interface ConfidenceInputs {
  cfg: ReadinessConfig;
  /** The E1 source used, if any, and whether only a below-threshold effort exists. */
  effort: RaceEffort | null;
  lowerBoundOnly: boolean;
  weeksWithRuns: number;
  longestGapDays: number;
  /** Runs of 30 km or more in the durability window whose splits were analysed. */
  longRunsWithSplits: number;
  /** Share of run minutes with HR readings (0-1) and how it was measured; null without runs. */
  hrCoverage: { fraction: number; rawRuns: number; summaryRuns: number } | null;
  /** An earlier race used as an estimator when there is no recent one. */
  earlierRace?: { ageWeeks: number; tagged: boolean } | null;
  priorMarathon: { present: boolean; hasStreams: boolean; representative: boolean };
  maxHrSource: 'user' | 'observed' | 'default';
  decouplingRuns: number;
  fueling: { enabled: boolean; qualifyingRuns: number };
  weeksToRace: number;
}

const status = (points: number, max: number): ConfidenceComponent['status'] => (points >= max - 1e-9 ? 'full' : points > 0 ? 'partial' : 'none');
const r1 = (x: number) => Math.round(x * 10) / 10;
const frac = (n: number, full: number) => Math.min(1, n / full);

export function confidenceComponents(i: ConfidenceInputs): ConfidenceComponent[] {
  const c = i.cfg.confidence;
  const w = c.weights;
  const out: ConfidenceComponent[] = [];
  const add = (name: string, points: number, max: number, reason: string, forced?: ConfidenceComponent['status']) => out.push({ name, points: r1(points), max, status: forced ?? status(points, max), reason });

  // Recent race-quality effort.
  {
    let pts = 0;
    let why: string;
    if (i.effort) {
      const e = i.effort;
      const fresh = e.ageWeeks <= i.cfg.e1.halfFreshWeeks;
      const label = e.klass === 'half' ? 'half marathon' : e.klass === 'tenK' ? '10K' : '5K';
      pts = e.klass === 'half' && fresh ? c.raceEffort.halfFresh : e.klass === 'tenK' && fresh ? c.raceEffort.tenKFresh : c.raceEffort.older;
      why = `${e.tagged ? 'tagged' : 'HR-verified'} ${label}, ${r1(e.ageWeeks)} weeks old`;
    } else if (i.earlierRace) {
      pts = c.raceEffort.earlier;
      why = `${i.earlierRace.tagged ? 'tagged' : 'HR-verified'} race ${r1(i.earlierRace.ageWeeks)} weeks old (older than the current block; used with extra uncertainty)`;
    } else if (i.lowerBoundOnly) {
      pts = c.raceEffort.lowerBoundOnly;
      why = 'only a below-threshold effort from a training run (lower bound)';
    } else why = 'no half marathon, 10K or 5K effort in the last 16 weeks';
    add('race_effort', pts, w.raceEffort, why);
  }

  // Training continuity.
  {
    const k = c.continuity;
    const gapped = i.longestGapDays > k.maxGapDays;
    const pts = w.continuity * frac(i.weeksWithRuns, k.fullWeeks) * (gapped ? k.gapPenaltyFactor : 1);
    add('training_continuity', pts, w.continuity, `${i.weeksWithRuns} of the last ${i.cfg.windows.blockWeeks} weeks with runs${gapped ? `; longest gap ${i.longestGapDays} days` : ''}`);
  }

  // Long-run evidence.
  add('long_run_evidence', w.longRunEvidence * frac(i.longRunsWithSplits, c.longRuns.fullCount), w.longRunEvidence, `${i.longRunsWithSplits} run(s) of ${c.longRuns.minKm} km or more with splits (full credit at ${c.longRuns.fullCount})`);

  // Heart rate coverage.
  if (i.hrCoverage) {
    const h = i.hrCoverage;
    add('hr_coverage', w.hrCoverage * frac(h.fraction, c.hrCoverage.full), w.hrCoverage, `${Math.round(h.fraction * 100)}% of run minutes with HR (${h.rawRuns} run(s) from raw streams, ${h.summaryRuns} judged from the workout summary)`);
  } else add('hr_coverage', 0, w.hrCoverage, 'no runs in the block');

  // Prior marathon.
  {
    const p = i.priorMarathon;
    const k = c.priorMarathon;
    if (!p.present) add('prior_marathon', 0, w.priorMarathon, 'no prior marathon detected');
    else if (!p.hasStreams) add('prior_marathon', k.summaryOnly, w.priorMarathon, 'prior marathon found, but its raw streams are not available');
    else if (!p.representative) add('prior_marathon', k.notRepresentative, w.priorMarathon, 'prior marathon with streams, but it may not be representative');
    else add('prior_marathon', k.full, w.priorMarathon, 'prior marathon with full streams');
  }

  // Max HR source.
  add('max_hr_source', c.maxHrSource[i.maxHrSource], w.maxHrSource, i.maxHrSource === 'user' ? 'max HR provided by the user' : i.maxHrSource === 'observed' ? 'max HR observed in workouts' : 'max HR is a default; heart-rate checks are less reliable');

  // Decoupling-qualifying runs.
  add('decoupling_runs', w.decouplingRuns * frac(i.decouplingRuns, c.decouplingRuns.fullCount), w.decouplingRuns, `${i.decouplingRuns} long steady flat run(s) usable for decoupling (full credit at ${c.decouplingRuns.fullCount})`);

  // Fueling (unlogged is not zero fuel: it only lowers confidence).
  if (!i.fueling.enabled) add('fueling_logged', 0, w.fueling, 'nutrition data is switched off; this says nothing about the runner\'s fueling', 'unknown');
  else add('fueling_logged', w.fueling * frac(i.fueling.qualifyingRuns, c.fueling.fullCount), w.fueling, `carbohydrates logged on ${i.fueling.qualifyingRuns} run(s) of ${c.fueling.minRunMinutes} minutes or more (not logged does not mean not eaten)`);

  // Time to race.
  {
    const t = c.timeToRace;
    const pts = i.weeksToRace <= t.nearWeeks ? t.near : i.weeksToRace <= t.midWeeks ? t.mid : t.far;
    add('time_to_race', pts, w.timeToRace, `${r1(i.weeksToRace)} weeks to the race`);
  }
  return out;
}

export const confidencePercent = (components: ConfidenceComponent[]): number => Math.round(components.reduce((n, c) => n + c.points, 0));
