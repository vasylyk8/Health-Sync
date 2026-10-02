// Additional synthetic-only fixtures so every public tool has reviewer data.
// Keep the production monitor's original fixtures and categories unchanged.
import { batches, CATEGORIES } from './data.mjs';
import { randomUUID } from 'node:crypto';
export const REVIEWER_CATEGORIES = [...CATEGORIES, 'nutrition', 'profile'];
export function reviewerBatches() {
  const now = Date.now();
  const header = (type) => ({ kind: 'header', schema: 2, batchId: randomUUID(), type,
    seq: now, tz: 'Europe/Berlin', createdAt: now, mode: 'anchored', caughtUp: true });
  const times = Array.from({ length: 7 }, (_, day) => Date.UTC(2024, 2, day + 1, 12));
  return [...batches(), [header('_events_nutrition'),
    { k: 'ev', ty: 'DietaryEnergyConsumed', u: 'kcal', src: 'Synthetic reviewer nutrition', s: times, v: times.map(() => 600) },
    { k: 'ev', ty: 'DietaryProtein', u: 'g', src: 'Synthetic reviewer nutrition', s: times, v: times.map(() => 30) }],
  [header('_events_profile'), { k: 'ev', ty: 'Profile', s: [Date.UTC(2024, 0, 1)], ids: ['synthetic-reviewer-profile'],
    meta: [{ dob: '1990-05-01', sex: 'male', wheelchair: false }] }]];
}
