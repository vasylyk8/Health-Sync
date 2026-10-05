// Backtest of assess_race_readiness on a runner's own past marathons: for each one the tool is run as of N days before the
// race (default 14), with the goal set to the actual finish time, and compared with what happened. Nothing after as_of is read.
//
//   GCP_PROJECT_ID=<project> npx tsx scripts/backtest-readiness.ts <uid>[,<uid>...] [options]
//   npx tsx scripts/backtest-readiness.ts --synthetic                      (smoke test on the synthetic dataset)
//
// Options:  --days-before N   as_of = race date - N days (default 14)
//           --max-hr N        measured max HR to use for every run (default: observed in the data)
//           --config file     JSON with overrides of src/readiness/config.ts (tuning), e.g. {"e1":{"rDefault":1.12}}
//           --json file       write the per-race rows as JSON
//
// What it reports: error of the central prediction (percent of the actual time, signed: positive = predicted slower), how often
// the actual time fell inside the 80% range (should be near 80%), and the probability-integral-transform value
// P(finish <= actual) = the tool's own likelihood at goal = actual (a calibrated model gives values spread evenly over 0-1).
// With only a handful of marathons per runner this is anecdotal: pool runners (comma-separated uids) before changing any default.
import { writeFileSync, readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { assessRaceReadiness } from '../src/readiness/assess.js';
import { withConfig, READINESS_CONFIG, type ReadinessConfig } from '../src/readiness/config.js';
import { loadRunSummaries } from '../src/readiness/extract.js';
import { addDays, hms, runKm } from '../src/readiness/features.js';
import { withDuck } from '../src/query/duck.js';
import type { QueryDeps } from '../src/query/context.js';

const positional: string[] = [];
const flags = new Map<string, string | true>();
{
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (!a.startsWith('--')) positional.push(a);
    else if (a !== '--synthetic' && argv[i + 1] !== undefined && !argv[i + 1]!.startsWith('--')) flags.set(a, argv[++i]!);
    else flags.set(a, true);
  }
}
const flag = (name: string): string | undefined => {
  const v = flags.get(name);
  return typeof v === 'string' ? v : undefined;
};
const synthetic = flags.has('--synthetic');
const daysBefore = Number(flag('--days-before') ?? 14);
const maxHr = flag('--max-hr') ? Number(flag('--max-hr')) : undefined;
const cfg: ReadinessConfig = flag('--config') ? withConfig(JSON.parse(readFileSync(flag('--config')!, 'utf8'))) : READINESS_CONFIG;
const uids = (positional[0] ?? '').split(',').filter(Boolean);

export interface BacktestRow {
  uid: string;
  race_date: string;
  as_of: string;
  actual: string;
  status: string;
  predicted?: string;
  range_80?: [string, string];
  error_pct?: number;
  inside_80?: boolean;
  pit?: number;
  confidence?: number;
}

/** Summary statistics of a set of rows (pure; used by the script and its test). */
export function summarise(rows: BacktestRow[]) {
  const ok = rows.filter((r) => r.status === 'ok' && r.error_pct !== undefined);
  const n = ok.length;
  const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
  return {
    races: rows.length,
    scored: n,
    insufficient: rows.length - n,
    mean_error_pct: mean(ok.map((r) => r.error_pct!)),
    mean_abs_error_pct: mean(ok.map((r) => Math.abs(r.error_pct!))),
    inside_80_share: n ? ok.filter((r) => r.inside_80).length / n : null,
    pit: ok.map((r) => r.pit!).sort((a, b) => a - b),
  };
}

/** Runs the backtest for one runner. `opts` override the command-line settings (tests). */
export async function evaluate(deps: QueryDeps, uid: string, opts: { daysBefore?: number; maxHr?: number; cfg?: ReadinessConfig } = {}): Promise<BacktestRow[]> {
  const days = opts.daysBefore ?? daysBefore;
  const useCfg = opts.cfg ?? cfg;
  const hr = opts.maxHr ?? maxHr;
  const today = new Date(deps.now()).toISOString().slice(0, 10);
  const marathons = await withDuck(async (c, dir) => {
    const loaded = await loadRunSummaries(deps, c, dir, deps.tz, '2012-01-01', today, useCfg);
    const [lo, hi] = useCfg.detect.marathonKm;
    return loaded.runs.filter((r) => runKm(r) >= lo && runKm(r) <= hi && r.movingSec).sort((a, b) => a.startMs - b.startMs);
  });
  const rows: BacktestRow[] = [];
  for (const m of marathons) {
    const dist = m.distanceM!;
    // Finish time over 42.195 km from Apple's summary (scaled when GPS made the course a little long or short).
    const actual = m.movingSec! * (Math.abs(dist - useCfg.marathonM) / useCfg.marathonM <= 0.03 ? useCfg.marathonM / dist : 1);
    const asOf = addDays(m.date, -days);
    const row: BacktestRow = { uid: uid.slice(0, 6), race_date: m.date, as_of: asOf, actual: hms(actual), status: 'error' };
    try {
      const t0 = performance.now();
      const r = await assessRaceReadiness(deps, { as_of_date: asOf, goal_time: hms(actual), max_hr: hr }, { race: { id: `backtest-${m.id.slice(0, 8)}`, name: 'Backtest', date: m.date }, cfg: useCfg });
      row.status = String(r.status);
      if (r.status === 'ok') {
        const pred = r.prediction as { central: string; range_80: [string, string] };
        const sec = (t: string) => t.split(':').reduce((n, x) => n * 60 + Number(x), 0);
        row.predicted = pred.central;
        row.range_80 = pred.range_80;
        row.error_pct = Math.round(((sec(pred.central) - Math.round(actual)) / actual) * 10_000) / 100;
        row.inside_80 = Math.round(actual) >= sec(pred.range_80[0]) && Math.round(actual) <= sec(pred.range_80[1]);
        row.pit = (r.likelihood as { probability: number }).probability;
        row.confidence = (r.confidence as { percent: number }).percent;
      }
      console.error(`  ${m.date}: ${row.status} (${Math.round(performance.now() - t0)} ms)`);
    } catch (err) {
      row.status = `error: ${(err as Error).message}`;
    }
    rows.push(row);
  }
  return rows;
}

async function main() {
  const rows: BacktestRow[] = [];
  if (synthetic) {
    const { startSynthetic } = await import('../test/helpers/synthetic.js');
    const s = await startSynthetic();
    const deps: QueryDeps = { uid: s.env.uid, meta: s.env.meta, data: s.env.data, incoming: s.env.incoming, now: () => Date.now(), tz: 'UTC' };
    rows.push(...await evaluate(deps, s.env.uid));
    await s.close();
  } else {
    const project = process.env.GCP_PROJECT_ID;
    if (!project || !uids.length) throw new Error('usage: GCP_PROJECT_ID=<project> backtest-readiness.ts <uid>[,<uid>...]  |  --synthetic');
    const { initializeApp } = await import('firebase-admin/app');
    const { getFirestore } = await import('firebase-admin/firestore');
    const { getStorage } = await import('firebase-admin/storage');
    const { GcsBlobs, FirestoreMeta } = await import('../src/store/firestore.js');
    const { dataBucketName } = await import('../src/config.js');
    initializeApp({ projectId: project });
    const meta = new FirestoreMeta(getFirestore());
    const data = new GcsBlobs(getStorage().bucket(dataBucketName(project)) as never);
    for (const uid of uids) {
      const user = await meta.getUser(uid);
      if (!user || user.deleting) {
        console.error(`user ${uid.slice(0, 6)}…: not found`);
        continue;
      }
      console.error(`user ${uid.slice(0, 6)}…`);
      rows.push(...await evaluate({ uid, meta, data, now: () => Date.now(), tz: user.tz ?? 'UTC' }, uid));
    }
  }
  console.table(rows.map((r) => ({ ...r, range_80: r.range_80?.join(' - ') })));
  const sum = summarise(rows);
  console.log(JSON.stringify(sum, null, 2));
  if (!rows.length) console.log('No past marathons found (41.5-43.5 km running workouts).');
  else if (sum.scored < 10) console.log(`Only ${sum.scored} scored race(s): calibration from so few is anecdotal; pool more runners before tuning.`);
  const out = flag('--json');
  if (out) writeFileSync(out, JSON.stringify({ config: cfg, days_before: daysBefore, rows, summary: sum }, null, 2));
}

if (process.argv[1]?.endsWith('backtest-readiness.ts')) await main();
