/**
 * Every tunable number of assess_race_readiness lives here (spec section 6), so the backtest can adjust them in
 * one place and freeze them. Nothing in this file is a measured value: the sizes of modifiers, sigmas and
 * confidence weights are heuristics ("weak" evidence) until calibrated by backtest.
 */

const base = {
  /** Marathon distance in metres; the only supported target in v1. */
  marathonM: 42_195,
  /** Standard source distances (metres) for race conversion. */
  stdDistancesM: { fiveK: 5_000, tenK: 10_000, half: 21_097.5 },

  windows: {
    /** Current training block ending at as_of_date. */
    blockWeeks: 16,
    /** Long-term base: weekly km for this many weeks before the current block. */
    baseWeeks: 52,
    /** Volume, long-run and durability checks. */
    durabilityWeeks: 12,
    /** Tanda training indices. */
    e3Weeks: 8,
    /** Steady-run efficiency fit (E2b): final weeks of each block. */
    efficiencyWeeks: 6,
    /** Prior marathon auto-detection. */
    priorMarathonLookbackMonths: 36,
    /** Fewer weeks with runs than this -> insufficient_data. */
    minDataWeeks: 6,
    /** The result describes race-day fitness only inside this many weeks. */
    raceWindowWeeks: 6,
  },

  detect: {
    /** Continuous running workouts of this length (km) are marathons. */
    marathonKm: [41.5, 43.5] as [number, number],
    /** Tagged tune-up races outside this distance (m) are not used as a conversion source. */
    taggedRangeM: [4_500, 23_000] as [number, number],
    /** A tagged race this close (fraction) to a standard distance uses that distance's best effort. */
    taggedNearestTolerance: 0.06,
    /** Two workouts overlapping by more than this fraction of the shorter one are the same run. */
    duplicateOverlapFraction: 0.5,
  },

  maxHr: {
    /** Plausible observed-max range (bpm) and the agreement needed to reject optical spikes. */
    plausible: [140, 230] as [number, number],
    agreeBpm: 3,
    agreeMinWorkouts: 2,
    /** Used only when neither a user value, an observed value nor the profile age exists (same default as get_training_load). */
    fallbackBpm: 190,
    /** HR samples outside this range are treated as sensor errors. */
    sampleRange: [30, 250] as [number, number],
    /** Sample above max_hr + this is flagged as an artefact. */
    spikeMarginBpm: 5,
  },

  e1: {
    /** log2(2.19): the half -> marathon multiplier of Vickers & Vertosick (2016). Literal 1.13 gives 2:59:49 for a 1:22:10 half. */
    rDefault: Math.log2(2.19),
    rClamp: [1.04, 1.22] as [number, number],
    volume: {
      highKmPerWeek: 90,
      highLongRuns: 3,
      longRunKm: 30,
      highDelta: -0.02,
      lowKmPerWeek: 50,
      lowDelta: 0.02,
    },
    /** Absolute sigma (% of predicted time) by source. */
    sigmaPct: { halfUnder8w: 3.5, half8to16w: 5.0, tenK: 5.0, fiveK: 7.0 },
    personalRSigmaDelta: -1.0,
    /** Inferred max effort: average HR of the effort window as a fraction of HRmax. */
    effortHrFraction: { half: 0.88, tenK: 0.9, fiveK: 0.9 },
    /** Source age limits (weeks) for race-conversion inputs. */
    maxSourceAgeWeeks: 16,
    halfFreshWeeks: 8,
  },

  e2: {
    sigmaPct: 4.0,
    /** Added when the prior marathon is not representative (hot, positive split, walk-heavy, pacing duty). */
    nonRepresentativeSigmaAdd: 2.0,
    representative: {
      /** Second half slower than the first by more than this fraction -> positive split. */
      positiveSplit: 0.05,
      /** Recorded temperature above this (degC) -> hot. */
      hotC: 18,
      /** Second half faster by at least this fraction and average HR below paceDutyHrFraction of HRmax -> pacing duty. */
      paceDutySplit: 0.05,
      paceDutyHrFraction: 0.75,
      /** At least this share of km splits slower than walkSlowFactor x the median -> walk-heavy / DNF-like. */
      walkShare: 0.2,
      walkSlowFactor: 1.5,
    },
    efficiency: {
      /** Speed-vs-HR fit uses splits with HR between these fractions of HRmax; predict speed at predictAt. */
      hrBand: [0.65, 0.82] as [number, number],
      predictAt: 0.75,
      minSplitsPerBlock: 15,
      /** Splits with more gain than this (m per km) are not flat. */
      maxGainPerKm: 10,
      /** Runs whose split-pace coefficient of variation exceeds this are not steady. */
      maxPaceCv: 0.1,
      /** The fit needs at least this spread (sd, fraction of HRmax) of HR to be defined; heuristic guard. */
      minHrSd: 0.02,
      /** The first kilometre is warm-up (HR lags pace); heuristic. */
      skipFirstKm: true,
    },
    /** Pace spikes beyond this factor of the median split pace are GPS dropouts and dropped. */
    gpsDropoutFactor: 2,
  },

  e3: {
    /** Tanda & Knechtle (2013), recreational men, valid for 165-266 min. */
    tanda: { a: 11.03, b: 98.46, c: -0.0053, d: 0.387, e: 0.1, f: 0.23 },
    validRangeMin: [165, 266] as [number, number],
    defaultBodyFatPct: 15,
    sigmaPct: { male: 7.0, female: 9.0 },
    minWeeksWithRuns: 6,
  },

  combine: {
    /** Estimators share one runner: combined sigma may not fall below this multiple of the smallest single sigma. */
    sigmaFloorFactor: 0.85,
    /** Race-day uncertainty (weather, course), % of the central time, added in quadrature. */
    raceDaySigmaPct: 2.0,
    /** Extra term, also in quadrature, when the race is further away than windows.raceWindowWeeks. */
    farRaceSigmaPct: 1.0,
    /** 80% central range. */
    z80: 1.2816,
  },

  modifiers: {
    /** Total durability modifier cap (% added to the predicted time). */
    capPct: 5,
    decoupling: {
      minLongRunKm: 25,
      lastN: 3,
      minQualifying: 2,
      maxPaceCv: 0.08,
      maxGainPerKm: 10,
      maxTempC: 22,
      moderateFromPct: 5,
      highFromPct: 10,
      moderatePenaltyPct: 1,
      highPenaltyPct: 2,
    },
    longRuns30k: { minKm: 30, fewerThanTwoPenaltyPct: 2, exactlyTwoPenaltyPct: 1 },
    goalPaceSegment: {
      minRunKm: 20,
      /** A km counts when its speed is at least goal speed x (1 - tolerance). */
      tolerance: 0.03,
      minKm: 10,
      penaltyPct: 1,
    },
    hrLateInLongRuns: {
      afterKm: 25,
      /** Splits within this fraction of goal pace (either side) count as "at goal pace". */
      paceTolerance: 0.03,
      maxHrFraction: 0.9,
      penaltyPct: 1,
    },
  },

  likelihood: {
    /** Upper bounds of the labels on the 0-10 score. */
    labels: [
      [2, 'very unlikely'],
      [4, 'unlikely'],
      [6, 'toss-up'],
      [8, 'likely'],
      [10, 'very likely'],
    ] as [number, string][],
  },

  confidence: {
    weights: {
      raceEffort: 25,
      continuity: 15,
      longRunEvidence: 15,
      hrCoverage: 10,
      priorMarathon: 10,
      maxHrSource: 5,
      decouplingRuns: 5,
      fueling: 5,
      timeToRace: 10,
    },
    raceEffort: { halfFresh: 25, tenKFresh: 18, older: 10, lowerBoundOnly: 5 },
    continuity: { fullWeeks: 12, maxGapDays: 10, gapPenaltyFactor: 0.5 },
    longRuns: { minKm: 30, fullCount: 3 },
    hrCoverage: { full: 0.8 },
    priorMarathon: { full: 10, notRepresentative: 5, summaryOnly: 3 },
    maxHrSource: { user: 5, observed: 3, default: 0 },
    decouplingRuns: { fullCount: 2 },
    fueling: { minRunMinutes: 90, fullCount: 2 },
    timeToRace: { nearWeeks: 6, midWeeks: 12, near: 10, mid: 5, far: 0 },
  },

  /** Raw-data analysis budget: one MCP request has a 45 s deadline and a response-size cap. */
  budget: {
    softTimeMs: 28_000,
    maxRawRuns: 60,
    /** Shortlist sizes (runs analysed from raw streams). */
    candidatesPerBlock: 12,
    steadyRunsPerBlock: 12,
    longRunMinKm: 20,
    effortCandidateMinKm: 5,
    /** Steady-run shortlist: average HR within these fractions of HRmax (summary level). */
    steadyHrFraction: [0.6, 0.86] as [number, number],
    steadyRunKm: [5, 25] as [number, number],
  },

  /** race_workout_ids accepted per call. */
  maxTaggedRaces: 10,
};

export type ReadinessConfig = typeof base;
export const READINESS_CONFIG: ReadinessConfig = base;

type DeepPartial<T> = { [K in keyof T]?: T[K] extends readonly unknown[] ? T[K] : T[K] extends object ? DeepPartial<T[K]> : T[K] };

/** A copy of the defaults with overrides (tests, backtest tuning). */
export function withConfig(overrides: DeepPartial<ReadinessConfig> = {}): ReadinessConfig {
  const merge = (a: unknown, b: unknown): unknown => {
    if (b === undefined) return a;
    if (Array.isArray(a) || typeof a !== 'object' || a === null || typeof b !== 'object' || b === null || Array.isArray(b)) return b;
    const out: Record<string, unknown> = { ...(a as Record<string, unknown>) };
    for (const [k, v] of Object.entries(b)) out[k] = merge((a as Record<string, unknown>)[k], v);
    return out;
  };
  return merge(structuredClone(base), overrides) as ReadinessConfig;
}
