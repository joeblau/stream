import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createLoopbackTerminal} from './owned-loopback-lifecycle.mjs';

const deferred=()=>{let resolve;const promise=new Promise(value=>{resolve=value;});return {promise,resolve};};
function fixture(){
  const target={},writes=[];
  const terminal=createLoopbackTerminal('/owned/receipt.json',{processTarget:target,
    writeSync(_path,text){writes.push(JSON.parse(text));}});
  const result={};
  return {target,writes,terminal,result,write:async(_path,text)=>{writes.push(JSON.parse(text));}};
}

test('early abort before metadata binding and later completion cannot restore success',()=>{
  const {target,terminal,result}=fixture();
  terminal.abort('SIGTERM');terminal.bind(result);terminal.complete();
  assert.equal(result.result,'UNQUALIFIED');assert.equal(target.exitCode,77);
});

test('signal after positive try during awaited cleanup is latched before terminal publication',async()=>{
  const {target,writes,terminal,result,write}=fixture(),cleanup=deferred();
  terminal.bind(result);terminal.complete();assert.equal(result.result,'DIAGNOSTIC_COMPLETE');
  const ending=(async()=>{await cleanup.promise;await terminal.publish(write);})();
  terminal.abort('SIGTERM');cleanup.resolve();await ending;
  assert.equal(writes.at(-1).result,'UNQUALIFIED');assert.equal(writes.at(-1).reason,'owned-signal-SIGTERM');
  assert.equal(target.exitCode,77);
});

test('signal during held receipt write replaces earlier serialized completion with unqualified',async()=>{
  const {target,writes,terminal,result}=fixture(),held=deferred();
  terminal.bind(result);terminal.complete();
  const publication=terminal.publish(async(_path,text)=>{writes.push(JSON.parse(text));await held.promise;});
  assert.equal(writes[0].result,'DIAGNOSTIC_COMPLETE');
  terminal.abort('SIGINT');held.resolve();await publication;
  assert.equal(writes.at(-1).result,'UNQUALIFIED');assert.equal(target.exitCode,77);
});

test('pending signal after publication rewrites the receipt and late completion remains refused',async()=>{
  const {target,writes,terminal,result,write}=fixture();
  terminal.bind(result);terminal.complete();await terminal.publish(write);
  terminal.abort('SIGTERM');terminal.complete();
  assert.equal(writes.at(-1).result,'UNQUALIFIED');assert.equal(result.result,'UNQUALIFIED');
  assert.equal(target.exitCode,77);
});
