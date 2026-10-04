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
  it('under the real budget keeps the prior block\'s efficiency runs and an earlier race for a runner with many runs', () => {
    const marathon = run('prior-mar', '2025-10-12', 42.2, 340, { hr: 173 });
    const priorSteady = Array.from({ length: 30 }, (_, i) => run(`ps${i}`, addDays('2025-10-11', -(i + 1)), 8 + (i % 5), 350, { hr: 148 }));
    const nowSteady = Array.from({ length: 40 }, (_, i) => run(`ns${i}`, addDays(AS_OF, -(i + 1)), 8 + (i % 5), 350, { hr: 148 }));
    const longs = Array.from({ length: 40 }, (_, i) => run(`lg${i}`, addDays(AS_OF, -(i % 80)), 20 + (i % 12), 360, { hr: 150 }));
    const hm = run('hm-2026', '2026-04-11', 21.1, 286, { hr: 178 });
    const list = selectForRawAnalysis({ runs: [marathon, ...priorSteady, ...nowSteady, ...longs, hm], asOf: AS_OF, maxHr: 195, taggedIds: [], prior: marathon, cfg });
    expect(list.length).toBeLessThanOrEqual(cfg.budget.maxRawRuns);
    expect(list.filter((x) => x.why === 'steady run (prior block)').length).toBeGreaterThanOrEqual(10);
    expect(list.find((x) => x.id === 'hm-2026')).toMatchObject({ why: 'earlier race candidate' });
    expect(list.find((x) => x.id === 'prior-mar')).toBeDefined();
  });
});
