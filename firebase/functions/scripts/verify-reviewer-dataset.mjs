// Read-only admin validation of synthetic reviewer data, independent of login.
// This is not an OAuth/MCP/host test and never claims to bypass the provider blocker.
import { strict as assert } from 'node:assert';
import { writeFileSync } from 'node:fs';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { FirestoreMeta, GcsBlobs } from '../lib/store/firestore.js';
import * as workouts from '../lib/query/workouts.js';
import * as health from '../lib/query/health.js';

const project = process.env.GCP_PROJECT_ID, uid = process.env.KROK_REVIEWER_UID;
assert.equal(project, 'krok-1d60a'); assert.equal(uid, 'krok-reviewer-directory');
initializeApp({ projectId: project });
const meta = new FirestoreMeta(getFirestore());
const storage = getStorage();
const q = { uid, meta, data: new GcsBlobs(storage.bucket(project + '-data')),
  incoming: new GcsBlobs(storage.bucket(project + '-incoming')), now: Date.now, tz: 'Europe/Berlin' };
const outcomes = [];
let current = 'dedicated account guards';
try {
  assert.equal((await meta.getUser(uid))?.synthetic, true);
  assert.equal((await getAuth().getUser(uid)).customClaims?.krokReviewer, true);
  current = 'fixture ingestion';
  const required = ['HKWorkoutTypeIdentifier', '_daily', '_hourly', '_events_devices', '_events_mind', '_events_nutrition', '_events_profile'];
  for (let attempt = 0; attempt < 30; attempt++) {
    const manifests = await Promise.all(required.map((type) => meta.getManifest(uid, type)));
    if (manifests.every(Boolean)) break;
    assert(attempt < 29, 'all fixture manifests required');
    await new Promise((resolve) => setTimeout(resolve, 10_000));
  }
  const dates = { start_date: '2024-03-01', end_date: '2024-03-07', timezone: 'Europe/Berlin' };
  const discovery = await workouts.getWorkouts(q, { start_date: '2024-01-01', end_date: '2024-01-07', timezone: q.tz });
  const run = discovery.workouts.find((w) => w.distance_km === 5 && w.raw_data === 'complete');
  assert(run && run.duration_min === 30);
  const workout_id = run.id;
  const cases = [
    ['get_workouts', workouts.getWorkouts, dates], ['get_workout', workouts.getWorkout, { workout_id }],
    ['get_workout_series', workouts.getWorkoutSeries, { workout_id, stream: 'HeartRate', max_points: 30 }],
    ['get_workout_route', workouts.getWorkoutRoute, { workout_id, max_points: 50 }],
    ['workout_hr_zones', workouts.workoutHrZones, { workout_id, max_hr: 200 }],
    ['workout_splits', workouts.workoutSplits, { workout_id, unit: 'km' }],
    ['workout_hr_drift', workouts.workoutHrDrift, { workout_id }],
    ['workout_best_efforts', workouts.workoutBestEfforts, { workout_id, distances_m: [1000, 3000] }],
    ['workout_elevation', workouts.workoutElevation, { workout_id }],
    ['get_daily_context', health.getDailyContext, dates],
    ['get_hourly_series', health.getHourlySeries, { ...dates, series: 'HeartRate' }],
    ['get_recovery', health.getRecovery, { date: '2024-03-07', timezone: q.tz }],
    ['get_training_load', health.getTrainingLoad, { end_date: '2024-03-07', days: 14, max_hr: 200 }],
    ['get_glucose', health.getGlucose, dates], ['get_health_events', health.getHealthEvents, { ...dates, category: 'mind' }],
    ['get_nutrition_log', health.getNutritionLog, dates], ['get_profile', health.getProfile, {}],
  ];
  for (const [name, fn, args] of cases) {
    current = name;
    const data = await fn(q, args);
    assert.equal(typeof data.complete, 'boolean');
    if (name === 'workout_splits') assert.equal(data.splits.filter((s) => s.moving_seconds === 360).length, 5);
    if (name === 'get_workout_route') { assert.equal(data.trimmed_ends, true); assert(data.returned > 10); }
    if (name === 'get_workout_series') { assert(data.points.some((p) => p[1] === 140)); assert(data.points.some((p) => p[1] === 150)); }
    if (name === 'get_daily_context') assert.equal(data.days[0].steps, 10000);
    if (name === 'get_glucose') assert(data.overall?.readings > 0);
    if (name === 'get_health_events') assert(data.count > 0);
    if (name === 'get_nutrition_log') assert.equal(data.count, 7);
    if (name === 'get_profile') assert.equal(data.profile.dob, '1990-05-01');
    outcomes.push({ check: name, status: 'passed' });
    console.log('PASS: synthetic production dataset query ' + name);
  }
} catch {
  outcomes.push({ check: current, status: 'failed' });
  console.error('FAIL: synthetic dataset ' + current + ' (values withheld)');
  process.exitCode = 1;
} finally {
  writeFileSync('/tmp/krok-reviewer-dataset-verification.json', JSON.stringify({ checkedAt: new Date().toISOString(),
    syntheticOnly: true, mode: 'read-only admin queries; not OAuth/MCP/host execution', outcomes }, null, 2));
}
