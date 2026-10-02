// Test-only adapter: use the real Firebase SDK and local Auth emulator.
export * from 'firebase/auth';
import type { FirebaseApp } from 'firebase/app';
import { getAuth as firebaseAuth, connectAuthEmulator, getRedirectResult as firebaseRedirectResult } from 'firebase/auth';
export async function getRedirectResult(...args: Parameters<typeof firebaseRedirectResult>) {
  // Test adapter only: simulate Apple's failed callback without a live Apple login.
  if (sessionStorage.getItem('test-apple-redirect-failure')) {
    sessionStorage.removeItem('test-apple-redirect-failure');
    throw Object.assign(new Error('Firebase: Error (auth/internal-error).'), { code: 'auth/internal-error' });
  }
  return firebaseRedirectResult(...args);
}
export function getAuth(app: FirebaseApp) {
  const auth = firebaseAuth(app);
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
  return auth;
}
