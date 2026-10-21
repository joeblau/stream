// OPTIONAL FILE-ONLY control for the fixture graph in rendered-return-oracle.
// Chrome155 remote MediaStream element audio is silent (null source provider):
// file success must never qualify that live graph or normal physical output.
// The same strict100ms decoder rejects both authored150ms signs.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {WebSocket} from 'ws';
import {analyzeReturnAV} from './native-return-video-analysis.mjs';
import {renderedReturnWorklet,installRenderedReturnOracle} from './rendered-return-oracle.mjs';
import {chromeFixtureExecutable,chromeFixtureCredentialArguments} from './chrome-fixture.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(label,predicate){const end=Date.now()+10000;while(Date.now()<end){const value=await predicate();if(value)return value;await pause(25);}throw Error(`Bounded calibration deadline: ${label}`);}
const owned=await fs.mkdtemp(path.join(os.tmpdir(),'stream-rendered-oracle-calibration-'));
console.log(`Owned file-only oracle calibration artifacts: ${owned}`);
let chrome,socket,server;
class CDP{
 constructor(socket){this.socket=socket;this.id=0;this.pending=new Map();socket.on('message',data=>{const value=JSON.parse(data),pending=this.pending.get(value.id);if(pending){this.pending.delete(value.id);clearTimeout(pending.timer);value.error?pending.reject(Error(value.error.message)):pending.resolve(value.result);}});}
 send(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++this.id,timer=setTimeout(()=>{this.pending.delete(id);reject(Error(`CDP deadline ${method}`));},10000);this.pending.set(id,{resolve,reject,timer});this.socket.send(JSON.stringify({id,method,params,sessionId}));});}
 async evaluate(sessionId,expression){const result=await this.send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,userGesture:true},sessionId);assert(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));return result.result.value;}
}
try{
 for(const [name,audioAt]of [['aligned',1],['audio-late',1.15],['audio-early',.85]]){
  const result=spawnSync('ffmpeg',['-v','error','-f','lavfi','-i','color=c=black:s=320x180:r=30:d=2.4','-f','lavfi','-i',`aevalsrc=0.2*sin(2*PI*1000*t)*gte(t\\,${audioAt}):s=48000:d=2.4`,'-vf',"drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='gte(t,1)'",'-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-ac','2','-movflags','+faststart','-y',path.join(owned,`${name}.mp4`)],{encoding:'utf8',timeout:20000});
  assert.equal(result.status,0,result.stderr);
  if(name==='aligned')assert(Math.abs(analyzeReturnAV(path.join(owned,`${name}.mp4`)).deltaSeconds)<.025,'Authored aligned source codec mapping');
  else assert.throws(()=>analyzeReturnAV(path.join(owned,`${name}.mp4`)),/exceeds100ms/,'Authored known150ms source must fail unchanged100ms gate');
 }
 server=http.createServer(async(req,res)=>{try{
  if(req.url==='/fixture-rendered-return-cue.js'){res.setHeader('Content-Type','text/javascript');res.end(renderedReturnWorklet);return;}
  if(req.url==='/'){res.setHeader('Content-Type','text/html');res.end('<video id=element playsinline controls width=320 height=180></video>');return;}
  const name=req.url.slice(1);if(!['aligned.mp4','audio-late.mp4','audio-early.mp4'].includes(name)){res.writeHead(404);res.end();return;}
  const data=await fs.readFile(path.join(owned,name));res.setHeader('Content-Type','video/mp4');res.setHeader('Content-Length',data.length);res.end(data);
 }catch{res.writeHead(500);res.end();}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const executable=await chromeFixtureExecutable(process.env.CHROME_BIN??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',owned),profile=path.join(owned,'chrome');await fs.mkdir(profile,{mode:0o700});
 chrome=spawn(executable,['--headless=new','--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run','--disable-background-networking','--disable-extensions','--autoplay-policy=no-user-gesture-required',...chromeFixtureCredentialArguments(),'about:blank'],{detached:true,stdio:'ignore'});
 const debug=await until('Chrome debug port',async()=>{try{return(await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).trim().split('\n');}catch{return undefined;}});
 socket=new WebSocket(`ws://127.0.0.1:${debug[0]}${debug[1]}`);await new Promise((resolve,reject)=>{socket.once('open',resolve);socket.once('error',reject);});const cdp=new CDP(socket);
 const {targetId}=await cdp.send('Target.createTarget',{url:`http://127.0.0.1:${server.address().port}/`}),{sessionId}=await cdp.send('Target.attachToTarget',{targetId,flatten:true});
 await cdp.send('Page.enable',{},sessionId);await until('Owned media element',()=>cdp.evaluate(sessionId,"Boolean(document.getElementById('element'))"));
 for(const name of ['aligned','audio-late','audio-early']){
  await cdp.evaluate(sessionId,`(async()=>{const old=document.getElementById('element'),v=document.createElement('video');v.id='element';v.playsInline=true;v.controls=true;v.width=320;v.height=180;old.replaceWith(v);v.src='/${name}.mp4';await new Promise((resolve,reject)=>{v.onloadeddata=resolve;v.onerror=reject;v.load();});window.oracle=await (${installRenderedReturnOracle})(v);oracle.reset();window.parts=[];window.recorder=new MediaRecorder(oracle.stream,{mimeType:'video/webm;codecs=vp8,opus',videoBitsPerSecond:400000,audioBitsPerSecond:128000});recorder.ondataavailable=e=>{if(e.data.size)parts.push(e.data);};recorder.start();await v.play();})()`);
  await until(`${name} authored playback ended`,()=>cdp.evaluate(sessionId,"document.getElementById('element').ended"));
  const measurement=await cdp.evaluate(sessionId,'oracle.measure()');
  const encoded=await cdp.evaluate(sessionId,"new Promise(resolve=>{recorder.onstop=async()=>{const a=new Uint8Array(await new Blob(parts).arrayBuffer());let s='';for(let i=0;i<a.length;i+=8192)s+=String.fromCharCode(...a.subarray(i,i+8192));resolve(btoa(s));};recorder.stop();})");
  assert(encoded.length<1048576,'Bounded calibration artifact');const file=path.join(owned,`${name}-instrumented.webm`);await fs.writeFile(file,Buffer.from(encoded,'base64'),{mode:0o600});
  console.log(`OBSERVED file-only control ${name}: ${JSON.stringify({measurement,file})}`);
  assert(Number.isFinite(measurement.deltaMilliseconds),'Actual element audio and video cues required');
  assert(measurement.maxCallbackDisplayDifference<50,'rVFC callback/display difference must remain bounded to50ms');
  if(name==='aligned'){assert(Math.abs(measurement.deltaMilliseconds)<100,'Aligned instrumented cue must pass same100ms bound');console.log(`PASS aligned exact graph ${JSON.stringify({measurement,recording:analyzeReturnAV(file)})}`);}
  else{assert(Math.abs(measurement.deltaMilliseconds)>100&&Math.sign(measurement.deltaMilliseconds)===(name==='audio-late'?-1:1),'Known150ms offset must fail with correct sign');assert.throws(()=>analyzeReturnAV(file),/exceeds100ms/,'Instrumented known150ms recording must fail unchanged100ms gate');console.log(`PASS negative control ${name}: unchanged100ms gate refuses ${JSON.stringify(measurement)}`);}
  await cdp.evaluate(sessionId,'oracle.stop()');
 }
 console.log(`PASS exact instrumented element/WebAudio + rVFC-canvas oracle calibration:0/+150/-150ms authored controls; artifacts ${owned}; no physical-output or untouched-element qualification`);
}finally{
 socket?.close();if(chrome?.exitCode===null){try{process.kill(-chrome.pid,'SIGTERM');}catch{}await Promise.race([new Promise(resolve=>chrome.once('close',resolve)),pause(2000)]);if(chrome.exitCode===null)try{process.kill(-chrome.pid,'SIGKILL');}catch{}}
 await new Promise(resolve=>server?server.close(resolve):resolve());
}
