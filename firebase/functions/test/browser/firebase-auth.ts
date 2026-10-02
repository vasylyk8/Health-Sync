// Test-only adapter: use the real Firebase SDK and local Auth emulator.
export * from 'firebase/auth';
import type { FirebaseApp } from 'firebase/app';
import { getAuth as firebaseAuth, connectAuthEmulator } from 'firebase/auth';
export function getAuth(app: FirebaseApp) {
  const auth = firebaseAuth(app);
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
  return auth;
}
