import { describe, expect, it } from 'vitest';
import { deps, makeEnv, upload, makeBatch } from '../helpers/memory.js';
import { getSamples, getSleep, getOverview, listAvailableData, summarize } from '../../src/query/tools.js';
import { parseDate } from '../../src/query/context.js';
import { ingestObject } from '../../src/ingest/ingest.js';
import { gunzipSync, gzipSync } from 'node:zlib';
const HR = 'HKQuantityTypeIdentifierHeartRate';
const STEPS = 'HKQuantityTypeIdentifierStepCount';
const SLEEP = 'HKCategoryTypeIdentifierSleepAnalysis';
const day = (d: number, h = 0) => Date.UTC(2024, 5, d, h);
const base = { start_date: '2024-06-01', end_date: '2024-06-01' };

describe('QA independent correctness checks', () => {
  it.fails('sleep overlap within one source is a union, not a sum', async () => {
    const env = makeEnv();
    await upload(env, { type: SLEEP, caughtUp: true }, [
      { k: 's', id: 'a', s: day(1,22), e: day(2,6), c: 3, src: 'Watch' },
      { k: 's', id: 'b', s: day(1,23), e: day(2,5), c: 3, src: 'Watch' },
    ]);
    const r = await getSleep(deps(env), { start_date:'2024-06-02', end_date:'2024-06-02' });
    expect(r.nights).toMatchObject([{ asleep_min:480, core_min:480 }]);
  });
  it('sleep ending after noon belongs to the date it ends', async () => {
    const env = makeEnv();
    await upload(env, { type:SLEEP, caughtUp:true }, [{ k:'s',id:'shift',s:day(2,6),e:day(2,14),c:1,src:'Watch' }]);
    const r = await getSleep(deps(env), {start_date:'2024-06-02',end_date:'2024-06-02'});
    expect(r.nights).toMatchObject([{night:'2024-06-02',asleep_min:480}]);
  });
  it('recomputed empty statistics remove previous totals', async () => {
    const env=makeEnv(); const window={start:day(1),end:day(2)};
    await upload(env,{type:STEPS,mode:'stats',window},[{k:'h',s:day(1,9),e:day(1,10),agg:'sum',v:1000,u:'count'}]);
    await upload(env,{type:STEPS,mode:'stats',window},[]);
    const r=await summarize(deps(env),{...base,type:'StepCount',period:'none'});
    expect((r.rows as {value:number}[]).reduce((s,r)=>s+r.value,0)).toBe(0);
  });
  it.fails('empty catalog does not claim completeness', async () => {
    expect((await listAvailableData(deps(makeEnv()))).complete).toBe(false);
  });
  it.fails('overview with every metric failing is incomplete', async () => {
    const env=makeEnv(); env.meta.getManifest=async()=>{throw new Error('storage offline');};
    const r=await getOverview(deps(env),{days:1});
    expect(r.complete).toBe(false);
  });
  it.fails('count returns count units, not bpm', async () => {
    const env=makeEnv();
    await upload(env,{type:HR,caughtUp:true},[{k:'s',id:'a',s:day(1,8),e:day(1,8),v:60,u:'count/min'}]);
    const r=await summarize(deps(env),{...base,type:'HeartRate',period:'none',stat:'count'});
    expect(r.unit).toBe('count');
  });
  it('invalid calendar dates rejected by input validation',()=>{
    expect(()=>parseDate('2024-02-30','start_date')).toThrow();
  });
  it('month totals equal the sum of known daily totals',async()=>{
    const env=makeEnv();
    await upload(env,{type:STEPS,mode:'stats',window:{start:day(1),end:env.now}},Array.from({length:29},(_,i)=>({k:'h',s:day(i+1,9),e:day(i+1,10),agg:'sum',v:(i+1)*100,u:'count'})));
    const args={type:'StepCount',start_date:'2024-06-01',end_date:'2024-06-29'};
    const daily=await summarize(deps(env),{...args,period:'day'});
    const monthly=await summarize(deps(env),{...args,period:'month'});
    expect((monthly.rows as {value:number}[])[0].value).toBe(43500);
    expect((daily.rows as {value:number}[]).reduce((n,r)=>n+r.value,0)).toBe(43500);
  });
  it('501 readings are rejected, 500 returned without truncation',async()=>{
    const env=makeEnv();
    await upload(env,{type:HR,caughtUp:true},Array.from({length:501},(_,i)=>({k:'s',id:String(i),s:day(1)+i*1000,e:day(1)+i*1000,v:60,u:'count/min'})));
    await expect(getSamples(deps(env),{...base,type:'HeartRate'})).rejects.toThrow(/501/);
    await upload(env,{type:HR},[{k:'d',id:'500'}]);
    expect((await getSamples(deps(env),{...base,type:'HeartRate'})).count).toBe(500);
  });
  it('SQL-like source text stays data',async()=>{
    const env=makeEnv(); const src="Watch'; DROP TABLE raw; --";
    await upload(env,{type:HR,caughtUp:true},[{k:'s',id:'a',s:day(1),e:day(1),v:60,u:'count/min',src}]);
    expect((await getSamples(deps(env),{...base,type:'HeartRate',source:src})).count).toBe(1);
  });
  it('reversed date ranges are rejected',async()=>{
    await expect(getSamples(deps(makeEnv()),{type:'HeartRate',start_date:'2024-06-02',end_date:'2024-06-01'})).rejects.toThrow(/before/);
  });
  it.fails('reconciliation retry completes cleanup after post-publication failure',async()=>{
    const env=makeEnv(); const rid='11111111-1111-4111-8111-111111111111';
    const b=makeBatch(env,{type:HR,mode:'reconcile',reconcileId:rid,reconcileDone:true,caughtUp:true},[]);
    await env.incoming.write(b.path,b.gz); let calls=0;
    const dep={...env,now:()=>env.now,onReconcileDone:async()=>{calls++; if(calls===1)throw new Error('transient');}};
    await expect(ingestObject(b.path,dep)).rejects.toThrow('transient');
    await ingestObject(b.path,dep);
    expect(calls).toBe(2);
  });
  it.fails('out-of-order publication cannot claim full history before earlier pages arrive',async()=>{
    const env=makeEnv();
    const earlier = makeBatch(env,{type:HR,caughtUp:false},[{k:'s',id:'pending',s:day(1),e:day(1),v:60,u:'count/min'}]);
    await env.incoming.write(earlier.path, earlier.gz); // Accepted but not ingested.
    await upload(env,{type:HR,caughtUp:true},[]);
    // The final empty page can arrive before earlier non-empty pages in event-driven ingestion.
    const r=await getSamples(deps(env),{...base,type:'HeartRate'});
    expect(r.complete).toBe(false);
  });
  it('higher sequence wins when events arrive out of order',async()=>{
    const env=makeEnv();
    const write=async(seq:number,v:number)=>{const b=makeBatch(env,{type:HR,caughtUp:true},[{k:'s',id:'a',s:day(1),e:day(1),v,u:'count/min'}]);const lines=gunzipSync(b.gz).toString().split('\n');const h=JSON.parse(lines[0]);h.seq=seq;lines[0]=JSON.stringify(h);await env.incoming.write(b.path,gzipSync(lines.join('\n')));await ingestObject(b.path,{...env,now:()=>env.now});};
    await write(10,80);await write(5,60);
    expect((await getSamples(deps(env),{...base,type:'HeartRate'})).samples).toMatchObject([{value:80}]);
  });
});
