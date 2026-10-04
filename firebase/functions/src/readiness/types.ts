import type { SplitRow } from '../query/calc.js';

export type Evidence = 'strong' | 'moderate' | 'weak';
export type StdDistanceKey = 'fiveK' | 'tenK' | 'half';

/** One running workout as summarised by Apple Health (cheap: no raw streams read). */
export interface RunSummary {
  id: string;
  startMs: number;
  endMs: number;
  /** Local calendar date, YYYY-MM-DD. */
  date: string;
  distanceM: number | null;
  /** Apple's duration excluding pauses, seconds. */
  movingSec: number | null;
  avgHr: number | null;
  maxHr: number | null;
  source: string | null;
  indoor: boolean;
  /** Recorded workout temperature, degC; null when the recording app did not store weather. */
  tempC: number | null;
}

/** A best effort of a standard distance inside one run, with the heart rate over that stretch. */
export interface EffortHr {
  distanceM: number;
  movingSec: number;
  avgHr: number | null;
}

/** Everything computed from the raw streams of one run. */
export interface RunRaw {
  id: string;
  distanceSource: string | null;
  /** 1 km splits with GPS dropouts already removed. */
  splits: SplitRow[];
  /** Share of moving seconds covered by an HR reading; null when the run has no HR stream. */
  hrCoverage: number | null;
  hrUnreliable: boolean;
  decouplingPct: number | null;
  efforts: EffortHr[];
  movingSec: number;
  distanceM: number;
  /** Elevation gain per km over the whole run; null when there is no altitude (and it is not a treadmill run). */
  gainPerKm: number | null;
  /** Moving seconds of the first / second half of the distance. */
  halves: [number, number] | null;
  rawComplete: boolean;
  /** Recorded workout temperature (degC), when the recording app stored weather. */
  tempC: number | null;
}

export interface PriorMarathon {
  run: RunSummary;
  raw: RunRaw | null;
  /** Time over 42 195 m in seconds (best effort when streams exist, else scaled from the summary). */
  seconds: number;
}

export interface MaxHrInfo {
  value: number;
  source: 'user' | 'observed' | 'default';
  /** How a default was chosen, for disclosure. */
  note?: string;
}

/** All inputs of the pure computation. Built by extract.ts from the data store, or by tests/backtests from fixtures. */
export interface ReadinessInputs {
  asOf: string;
  tz: string;
  race: { id: string; name: string; date: string; daysUntil: number };
  goalSeconds: number;
  maxHr: MaxHrInfo;
  sex: 'male' | 'female' | null;
  bodyFatPct: number | null;
  /** Deduplicated running workouts from (as_of - lookback) to as_of. */
  runs: RunSummary[];
  /** Runs whose raw streams were analysed. */
  raw: Map<string, RunRaw>;
  /** Shortlisted runs that could not be analysed (time budget, no raw data yet, no distance). */
  rawSkipped: { id: string; reason: string }[];
  /** User-tagged tune-up races. */
  taggedRaceIds: string[];
  priorMarathon: PriorMarathon | null;
  /** The prior marathon was explicitly disabled ("none"). */
  priorDisabled: boolean;
  nutrition: { enabled: boolean; carbRunIds: string[] };
  /** What the caller knows about race day; each adjusts the prediction only when given. */
  context: { course: 'flat' | 'rolling' | 'hilly' | null; expectedTempC: number | null; newSuperShoes: boolean };
  /** Gaps the extraction already knows about (missing categories, truncation, duplicates removed...). */
  gaps: string[];
  /** Extraction notes worth showing to the user. */
  notes: string[];
}

export interface Estimate {
  name: string;
  available: boolean;
  predictedSeconds: number | null;
  sigmaPct: number | null;
  inputs: Record<string, unknown>;
  notes: string[];
}

export interface RaceEffort {
  workoutId: string;
  date: string;
  ageWeeks: number;
  distanceM: number;
  seconds: number;
  /** Average HR over the effort as a fraction of HRmax; null when unknown. */
  hrFraction: number | null;
  tagged: boolean;
  /** True when the effort is inferred from an HR test, false for tagged races and lower bounds. */
  effortInferred: boolean;
  qualifies: boolean;
  klass: StdDistanceKey;
  /** Recorded temperature of the run the effort came from (degC). */
  tempC: number | null;
}

export interface ModifierResult {
  check: string;
  value: number | null;
  benchmark: string;
  appliedPct: number;
  status: 'met' | 'not_met' | 'unknown';
  evidence: Evidence;
  detail?: string;
}

export interface ConfidenceComponent {
  name: string;
  points: number;
  max: number;
  status: 'full' | 'partial' | 'none' | 'unknown';
  reason: string;
}

export interface Adjustment {
  name: 'course' | 'expected_race_day_heat' | 'super_shoes_what_if';
  /** Percent of the finish time; positive = slower. */
  pct: number;
  /** Percent of the finish time added to sigma, in quadrature. */
  sigmaPct: number;
  detail: string;
}
