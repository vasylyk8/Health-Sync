// Copies the shared coverage matrix into the functions source so it ships with the deploy.
import { copyFileSync, mkdirSync } from 'node:fs';
mkdirSync(new URL('../src/generated/', import.meta.url), { recursive: true });
copyFileSync(new URL('../../../shared/coverage.json', import.meta.url), new URL('../src/generated/coverage.json', import.meta.url));
