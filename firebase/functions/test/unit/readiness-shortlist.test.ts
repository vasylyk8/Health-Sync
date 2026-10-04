import { describe, expect, it } from 'vitest';
import { READINESS_CONFIG as cfg } from '../../src/readiness/config.js';
import { addDays } from '../../src/readiness/features.js';
import { selectAllForRawAnalysis, selectForRawAnalysis } from '../../src/readiness/extract.js';
import { run } from '../helpers/readiness.js';

const AS_OF = '2026-10-04';

describe('raw-run shortlist', () => {
  // A busy runner: far more candidate runs than the raw-run budget allows.
  const busy = Array.from({ length: 120 }, (_, i) => run(`long${i}`, addDays(AS_OF, -(i % 80)), 20 + (i % 12), 360, { hr: 150 }));
  const earlierRace = run('hm-old', addDays(AS_OF, -26 * 7), 21.1, 286, { hr: 178 });
  // A small budget stands in for a runner whose training runs exceed the real one.
  const small = { ...cfg, budget: { ...cfg.budget, maxRawRuns: 10 } };
  const args = { runs: [...busy, earlierRace], asOf: AS_OF, maxHr: 195, taggedIds: [] as string[], prior: null, cfg: small };

  it('keeps an earlier race even when the budget would otherwise be filled by training runs', () => {
    expect(selectAllForRawAnalysis(args).length).toBeGreaterThan(10);
    const list = selectForRawAnalysis(args);
    expect(list).toHaveLength(10);
    expect(list.find((x) => x.id === 'hm-old')).toMatchObject({ why: 'earlier race candidate' });
  });
  it('does not treat easy-effort runs as earlier races', () => {
    const easy = run('easy-old', addDays(AS_OF, -26 * 7), 21.1, 330, { hr: 150 });
    const list = selectForRawAnalysis({ ...args, runs: [easy] });
    expect(list.find((x) => x.why === 'earlier race candidate')).toBeUndefined();
  });
});
