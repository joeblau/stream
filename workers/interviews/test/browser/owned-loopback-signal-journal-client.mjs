import assert from 'node:assert/strict';
import {test} from 'node:test';
import vm from 'node:vm';
import {createLoopbackSignalJournal} from './owned-loopback-signal-journal.mjs';
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const held=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};};
const row=(snapshot,side='receiver')=>snapshot.counts.find(x=>x.side===side&&x.operation==='add-ice-candidate');

test('observer returns exact promise, invokes synchronously and leaves trickle unawaited',async()=>{
  let phase='receiver-remote-description';const journal=createLoopbackSignalJournal(()=>phase);journal.begin();
  const pending=held(),order=[];
  const result=journal.observe('receiver','add-ice-candidate',()=>{order.push('native-call');return pending.promise;});
  order.push('next-signaling-call');assert.equal(result,pending.promise);
  const before=journal.snapshot();assert.equal(row(before).inFlight,1);assert.equal(row(before).completed,0);
  assert.deepEqual(order,['native-call','next-signaling-call']);assert.deepEqual(before.events.map(x=>x.kind),['invoke','start']);
  phase='connection-wait';pending.resolve();await tick();
  const after=journal.snapshot();assert.equal(row(after).inFlight,0);assert.equal(row(after).completed,1);
  assert.equal(after.events[2].phase,'receiver-remote-description');assert.equal(after.events[2].settlementPhase,'connection-wait');
  assert.equal(after.events[2].invocation,after.events[0].sequence);assert.equal(row(before).inFlight,1,'Published snapshot mutated');
});

test('native rejection/throw remains observable by caller without leaking message or arguments',async()=>{
  const journal=createLoopbackSignalJournal(()=>'sender-pending-candidates');journal.begin();
  const error=Object.assign(new Error('PRIVATE_CANDIDATE_SDP_ADDRESS'),{name:'OperationError'});
  const promise=Promise.reject(error),observed=journal.observe('sender','add-ice-candidate',()=>promise);
  assert.equal(observed,promise);await assert.rejects(observed,value=>value===error);await tick();
  assert.throws(()=>journal.observe('sender','set-local-description',()=>{throw error;}),value=>value===error);
  const snapshot=journal.snapshot();assert.equal(row(snapshot,'sender').rejected,1);assert.equal(row(snapshot,'sender').inFlight,0);
  assert.equal(snapshot.events.at(-1).error,'OperationError');assert(!JSON.stringify(snapshot).includes(error.message));
});

test('late promises cannot settle a replacement generation or a retired lease',async()=>{
  let phase='receiver-remote-description';const journal=createLoopbackSignalJournal(()=>phase);journal.begin();
  const old=held();journal.observe('receiver','add-ice-candidate',()=>old.promise);
  const frozen=journal.snapshot();journal.retire();journal.begin();phase='sender-remote-description';
  const current=held();journal.observe('receiver','add-ice-candidate',()=>current.promise);
  old.resolve();await tick();const snapshot=journal.snapshot();
  assert.equal(snapshot.generation,2);assert.equal(row(snapshot).inFlight,1);assert.equal(row(snapshot).completed,0);
  assert(snapshot.events.every(x=>x.generation===2));assert.equal(snapshot.staleSettlements,1);
  journal.retire();current.reject(new Error('PRIVATE'));await tick();
  assert.equal(journal.snapshot().staleSettlements,2);assert.equal(journal.snapshot().active,false);
  assert.equal(frozen.staleSettlements,0);assert.equal(row(frozen).inFlight,1);
});

test('exact serialized factory bounds events and queue/end notes without retaining candidates',async()=>{
  const factory=vm.runInNewContext('('+createLoopbackSignalJournal.toString()+')');
  const journal=factory(()=>'connection-wait');journal.begin();
  journal.note('sender','candidate-emitted');journal.note('receiver','candidate-queued');journal.note('sender','candidate-end');
  for(let i=0;i<100;i++)await journal.observe('receiver','add-ice-candidate',()=>Promise.resolve());
  const snapshot=journal.snapshot();assert.equal(snapshot.events.length,64);assert.equal(snapshot.counts.length,10);
  assert(snapshot.droppedEvents>0);assert.equal(row(snapshot).completed,100);assert.equal(row(snapshot).inFlight,0);
  assert.deepEqual(Array.from(snapshot.events.slice(0,3),x=>x.kind),['candidate-emitted','candidate-queued','candidate-end']);
  assert(JSON.stringify(snapshot).length<16000);
});
