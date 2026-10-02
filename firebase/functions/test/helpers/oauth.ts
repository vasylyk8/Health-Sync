import type { OAuthStore, OAuthTransaction } from '../../src/auth/oauth-store.js';

export class MemoryOAuthStore implements OAuthStore {
  docs = new Map<string, object>();
  private tail: Promise<unknown> = Promise.resolve();
  async get<T>(path: string): Promise<T | undefined> { return structuredClone(this.docs.get(path)) as T | undefined; }
  async set(path: string, value: object) { this.docs.set(path, structuredClone(value)); }
  transaction<T>(run: (tx: OAuthTransaction) => Promise<T>): Promise<T> {
    const task = this.tail.then(async () => {
      const writes = new Map<string, object>();
      const result = await run({ get: <V>(path: string) => this.get<V>(path), set: (path, value) => writes.set(path, structuredClone(value)) });
      for (const [path, value] of writes) this.docs.set(path, value);
      return result;
    });
    this.tail = task.catch(() => undefined);
    return task;
  }
}
