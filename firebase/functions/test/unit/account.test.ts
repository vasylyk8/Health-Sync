import { describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import { AccountError, batchExists } from '../../src/account.js';
import { makeEnv } from '../helpers/memory.js';

describe('batchExists', () => {
  it('is true for a processed batch, whatever its outcome', async () => {
    const env = makeEnv();
    const id = randomUUID();
    await env.meta.markBatch(env.uid, id, 'rejected', 'bad line');
    expect(await batchExists(env, env.uid, id)).toBe(true);
  });

  it('is true for a batch still waiting in the incoming bucket', async () => {
    const env = makeEnv();
    const id = randomUUID();
    await env.incoming.write(`incoming/${env.uid}/${id}.ndjson.gz`, Buffer.from('x'));
    expect(await batchExists(env, env.uid, id)).toBe(true);
  });

  it('is false for a batch the server never received', async () => {
    const env = makeEnv();
    expect(await batchExists(env, env.uid, randomUUID())).toBe(false);
  });

  it("does not reveal another user's batches", async () => {
    const env = makeEnv();
    const id = randomUUID();
    await env.incoming.write(`incoming/someone-else/${id}.ndjson.gz`, Buffer.from('x'));
    expect(await batchExists(env, env.uid, id)).toBe(false);
  });

  it('rejects anything that is not a batch id', async () => {
    const env = makeEnv();
    await expect(batchExists(env, env.uid, '../../etc/passwd')).rejects.toBeInstanceOf(AccountError);
    await expect(batchExists(env, env.uid, undefined)).rejects.toBeInstanceOf(AccountError);
  });
});
