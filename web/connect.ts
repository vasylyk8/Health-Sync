import { initializeApp } from '../firebase/functions/node_modules/firebase/app';
import { getAuth, OAuthProvider, signInWithRedirect, getRedirectResult, onAuthStateChanged, signOut, signInWithEmailAndPassword } from '../firebase/functions/node_modules/firebase/auth';

const status = document.querySelector<HTMLElement>('#status')!;
const signIn = document.querySelector<HTMLButtonElement>('#sign-in')!;
const approve = document.querySelector<HTMLButtonElement>('#approve')!;
const deny = document.querySelector<HTMLButtonElement>('#deny')!;
const request = new URL(location.href).searchParams.get('request');
const descriptions: Record<string, string> = {
  'health:workouts:read': 'Workouts and detailed measurements, including heart rate, pace, power, and cadence.',
  'health:daily:read': 'Daily summaries, including sleep, HRV, body measurements, nutrition, mood, and cycle data you sync.',
  'health:events:read': 'Detailed health events you opted to sync: glucose, cardiac alerts, symptoms, blood pressure, insulin, medications, and timed nutrition entries.',
  'health:profile:read': 'Personal health profile you opted to sync: age, date of birth, biological sex, wheelchair use, and activity mode.',
  'health:routes:read': 'Workout GPS routes, with the first and last 300 metres hidden.',
  'health:routes:full': 'Exact workout start/end locations, only when you explicitly request them.',
  offline_access: 'Keep this assistant connected until you disconnect it or authorization expires.',
};
const fullRoutes = document.querySelector<HTMLInputElement>('#full-routes')!;

async function start() {
  const configResponse = await fetch('/__/firebase/init.json');
  if (!configResponse.ok) throw new Error('KROK sign-in is not configured. Please try again later.');
  const config = await configResponse.json();
  // Serve login and Firebase auth helpers from the same Hosting origin. This avoids
  // third-party storage restrictions during redirect sign-in on Safari.
  const auth = getAuth(initializeApp({ ...config, authDomain: location.hostname }));
  // A failed Apple callback must not leave the user stranded without retry/cancel.
  let appleRedirectFailed = false;
  try { await getRedirectResult(auth); }
  catch { appleRedirectFailed = true; }
  if (!request) {
    status.textContent = 'Start the connection in Claude or ChatGPT. To link your existing data, first sign in with Apple inside KROK on your iPhone.';
    return;
  }
  const infoResponse = await fetch(`/oauth/request/${encodeURIComponent(request)}`);
  const info = await infoResponse.json();
  if (!infoResponse.ok) throw new Error(info.message ?? 'This request expired. Start again in your assistant.');
  document.querySelector<HTMLElement>('#assistant')!.textContent = info.provider === 'claude' ? 'Claude' : 'ChatGPT';
  document.querySelector<HTMLElement>('#client')!.textContent = `Connecting ${info.clientName} (${info.callbackHost}).`;
  const list = document.querySelector<HTMLUListElement>('#permissions')!;
  for (const scope of info.scopes as string[]) {
    if (scope === 'health:routes:full') continue;
    const li = document.createElement('li');
    li.textContent = descriptions[scope] ?? scope;
    list.append(li);
  }
  document.querySelector<HTMLElement>('#full-route-option')!.hidden = !info.scopes.includes('health:routes:full');
  document.querySelector<HTMLElement>('#consent')!.hidden = false;
  signIn.hidden = false;
  const updateUser = () => {
    const user = auth.currentUser;
    signIn.hidden = !!user;
    approve.disabled = !user;
    document.querySelector<HTMLElement>('#switch-account')!.hidden = !user;
    status.textContent = user ? 'Signed in. Authorize access only if this is the assistant you chose to connect.'
      : appleRedirectFailed ? 'Apple sign-in did not complete. Try signing in again, or cancel and restart the connection in your assistant. If Apple shows a different app, cancel and contact KROK support.'
      : 'Sign in using the same Apple Account you linked in the KROK iPhone app.';
  };
  onAuthStateChanged(auth, updateUser);
  signIn.onclick = async () => {
    appleRedirectFailed = false;
    try { await signInWithRedirect(auth, new OAuthProvider('apple.com')); }
    catch { status.textContent = 'Apple sign-in could not start. Try again.'; }
  };
  document.querySelector<HTMLButtonElement>('#switch-account')!.onclick = async () => { await signOut(auth); updateUser(); };
  const finish = async (accepted: boolean) => {
    approve.disabled = deny.disabled = true;
    try {
      const token = accepted ? await auth.currentUser?.getIdToken(true) : undefined;
      const response = await fetch('/oauth/consent', { method: 'POST', headers: {
        'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}),
      }, body: JSON.stringify({ request, approve: accepted, fullRoutes: fullRoutes.checked }) });
      const body = await response.json();
      if (!response.ok) throw new Error(body.message ?? 'Could not authorize access. Try again.');
      location.assign(body.redirect);
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : 'Could not connect. Please retry.';
      deny.disabled = false;
      approve.disabled = !auth.currentUser;
    }
  };
  approve.onclick = () => void finish(true);
  deny.onclick = () => void finish(false);
  // Reviewer accounts must be explicitly marked by an administrator; ordinary
  // password accounts cannot authorize health access. Never ship a bypass credential.
  document.querySelector<HTMLFormElement>('#reviewer-form')!.onsubmit = async (event) => {
    event.preventDefault();
    try {
      await signInWithEmailAndPassword(auth, document.querySelector<HTMLInputElement>('#reviewer-email')!.value,
        document.querySelector<HTMLInputElement>('#reviewer-password')!.value);
      document.querySelector<HTMLInputElement>('#reviewer-password')!.value = '';
      updateUser();
    } catch { status.textContent = 'Reviewer sign-in failed. Check the credentials supplied through the review portal.'; }
  };
}
void start().catch((error) => { status.textContent = error instanceof Error ? error.message : 'Could not load KROK sign-in. Please retry.'; });
