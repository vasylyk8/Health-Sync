import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { rebuildAnalyticsRollups } from '../lib/analytics/rollup.js';

const projectId = process.env.GCP_PROJECT_ID;
if (!projectId) throw new Error('GCP_PROJECT_ID is required.');
initializeApp({ projectId });
const result = await rebuildAnalyticsRollups(getFirestore());
process.stdout.write(`Analytics rollups ready: ${result.days} days, ${result.users} users, ${result.access + result.events} events.\n`);

