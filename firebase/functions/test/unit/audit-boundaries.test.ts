import { describe,it,expect } from 'vitest';
import { deps,makeEnv,upload } from '../helpers/memory.js';
import { summarize,getSamples,getOverview,listAvailableData } from '../../src/query/tools.js';
const HR='HKQuantityTypeIdentifierHeartRate', STEPS='HKQuantityTypeIdentifierStepCount', H=3600000;
describe('QA calendar boundaries and metadata',()=>{
 it.each([['2024-03-10',Date.UTC(2024,2,10,5),23],['2024-11-03',Date.UTC(2024,10,3,4),25]] as const)('Toronto DST %s uses actual hours',async(date,start,hours)=>{
  const env=makeEnv(start+hours*H);
  await upload(env,{type:STEPS,mode:'stats',window:{start,end:env.now}},Array.from({length:hours},(_,i)=>({k:'h',s:start+i*H,e:start+(i+1)*H,agg:'sum',v:100,u:'count'})));
  expect((await summarize(deps(env),{type:'StepCount',start_date:date,end_date:date,timezone:'America/Toronto',period:'day'})).rows).toMatchObject([{value:hours*100}]);
 });
 it('leap-day readings remain on leap day',async()=>{
  const t=Date.UTC(2024,1,29,12),env=makeEnv(t+H);
  await upload(env,{type:HR,caughtUp:true},[{k:'s',id:'a',s:t,e:t,v:60,u:'count/min'}]);
  expect((await getSamples(deps(env),{type:'HeartRate',start_date:'2024-02-29',end_date:'2024-02-29'})).count).toBe(1);
 });
 it('future-only range is not complete',async()=>{
  const env=makeEnv();await upload(env,{type:HR,caughtUp:true},[]);
  expect((await getSamples(deps(env),{type:'HeartRate',start_date:'2025-01-01',end_date:'2025-01-02'})).complete).toBe(false);
 });
 it('stale catalog cannot claim complete',async()=>{
  const env=makeEnv();await upload(env,{type:HR,caughtUp:true,checkedAt:env.now-3*86400000},[]);
  expect((await listAvailableData(deps(env))).complete).toBe(false);
 });
 it('overview retains contributing freshness timestamp',async()=>{
  const env=makeEnv();await upload(env,{type:STEPS,caughtUp:true},[]);
  expect((await getOverview(deps(env),{days:1})).dataAsOf).not.toBeNull();
 });
 it('non-hour timezone rejects inexact daily totals',async()=>{
  const start=Date.UTC(2024,5,1,18),env=makeEnv(start+48*H);
  await upload(env,{type:STEPS,mode:'stats',window:{start:start-24*H,end:env.now}},[{k:'h',s:start,e:start+H,agg:'sum',v:100,u:'count'}]);
  await expect(summarize(deps(env),{type:'StepCount',start_date:'2024-06-02',end_date:'2024-06-02',timezone:'Asia/Kathmandu',period:'day'})).rejects.toThrow();
 });
});
