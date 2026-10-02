import type { Firestore } from 'firebase-admin/firestore';

function document(value: object): object {
  const clean = JSON.parse(JSON.stringify(value));
  if (typeof clean.expires === 'number') clean.expireAt = new Date(clean.expires);
  return clean;
}

/** All credential state transitions use one transaction, across instances. */
export interface OAuthTransaction {
  get<T>(path: string): Promise<T | undefined>;
  set(path: string, value: object): void;
}
export interface OAuthStore {
  get<T>(path: string): Promise<T | undefined>;
  set(path: string, value: object): Promise<void>;
  transaction<T>(run: (tx: OAuthTransaction) => Promise<T>): Promise<T>;
}

export class FirestoreOAuthStore implements OAuthStore {
  constructor(private readonly db: Firestore) {}
  async get<T>(path: string): Promise<T | undefined> {
    return (await this.db.doc(path).get()).data() as T | undefined;
  }
  async set(path: string, value: object): Promise<void> {
    // Optional OAuth fields must be omitted, not sent as Firestore undefined values.
    await this.db.doc(path).set(document(value));
  }
  transaction<T>(run: (tx: OAuthTransaction) => Promise<T>): Promise<T> {
    return this.db.runTransaction(async (tx) => run({
      get: async <V>(path: string) => (await tx.get(this.db.doc(path))).data() as V | undefined,
      set: (path, value) => tx.set(this.db.doc(path), document(value)),
    }));
  }
}
