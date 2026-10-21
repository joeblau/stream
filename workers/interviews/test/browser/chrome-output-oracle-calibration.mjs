// Owned local file controls calibrate normal HTML audio output captured only
// from the exact owned Chrome PID, versus actual rVFC display clock anchors.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {WebSocket} from 'ws';
import {analyzeReturnAV} from './native-return-video-analysis.mjs';

import {chromeFixtureExecutable,chromeFixtureCredentialArguments} from './chrome-fixture.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(label,predicate){const end=Date.now()+10000;while(Date.now()<end){const value=await predicate();if(value)return value;await pause(25);}throw Error(`Bounded calibration deadline: ${label}`);}
const owned=await fs.mkdtemp(path.join(os.tmpdir(),'stream-rendered-oracle-calibration-'));
let chrome,socket,server,observer,noise;
const observerPath=process.env.STREAM_CHROME_AUDIO_OBSERVER;
assert(observerPath&&path.isAbsolute(observerPath),'Set owned observer executable path');
class Observer {
 constructor(process){this.process=process;this.pending='';this.receipts=[];this.failure=undefined;process.stdout.on('data',chunk=>{this.pending+=chunk.toString('utf8');assert(this.pending.length<16384,'Observer bounded JSON');let end;while((end=this.pending.indexOf('\n'))!==-1){const line=this.pending.slice(0,end);this.pending=this.pending.slice(end+1);const value=JSON.parse(line);this.receipts.push(value);assert(this.receipts.length<64,'Observer receipt cap');if(value.type==='unqualified'||value.type==='error'){this.failure=Error('Observer unavailable: '+JSON.stringify(value));this.failure.unqualified=value.type==='unqualified';}}});process.on('error',error=>{this.failure=error;});}
 async receipt(predicate){return until('owned observer receipt',()=>{if(this.failure)throw this.failure;return this.receipts.find(predicate);});}
 async command(action,id){this.process.stdin.write(JSON.stringify({action,id,threshold:.025})+'\n');return this.receipt(value=>value.id===id);}
}

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
  
  if(req.url==='/'){res.setHeader('Content-Type','text/html');res.end('<video id=element playsinline controls width=320 height=180></video>');return;}
  const name=req.url.slice(1);if(!['aligned.mp4','audio-late.mp4','audio-early.mp4'].includes(name)){res.writeHead(404);res.end();return;}
  const data=await fs.readFile(path.join(owned,name));res.setHeader('Content-Type','video/mp4');res.setHeader('Content-Length',data.length);res.end(data);
 }catch{res.writeHead(500);res.end();}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const executable=await chromeFixtureExecutable(process.env.CHROME_BIN??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',owned),profile=path.join(owned,'chrome');await fs.mkdir(profile,{mode:0o700});
 const browserArguments=[...(process.env.STREAM_CHROME_CALIBRATION_HEADED==='1'?['--start-minimized','--disable-backgrounding-occluded-windows']:['--headless=new']),'--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run','--disable-background-networking','--disable-extensions','--autoplay-policy=no-user-gesture-required',...chromeFixtureCredentialArguments(),'about:blank'];
 let ownedChromePID;
 if(process.env.STREAM_CHROME_LS_LAUNCHER){
  assert(process.env.STREAM_CHROME_CALIBRATION_HEADED==='1','LaunchServices control uses normal headed player');
  const bundle=path.dirname(path.dirname(path.dirname(executable)));
  chrome=spawn(process.env.STREAM_CHROME_LS_LAUNCHER,[bundle,...browserArguments],{detached:true,stdio:['pipe','pipe','ignore']});
  let reply='';chrome.stdout.on('data',chunk=>{reply+=chunk.toString('utf8');assert(reply.length<2048,'Bounded LS launcher receipt');});
  const launched=await until('New exact LaunchServices Chrome PID',()=>{if(chrome.exitCode!==null)throw Error('Owned Chrome LaunchServices unavailable');try{return JSON.parse(reply.trim());}catch{return undefined;}});
  assert(launched.type==='launched'&&launched.newInstance===true&&Number.isSafeInteger(launched.pid),'Owned new-instance LS PID receipt');ownedChromePID=launched.pid;
 }else{chrome=spawn(executable,browserArguments,{detached:true,stdio:'ignore'});ownedChromePID=chrome.pid;}

 const debug=await until('Chrome debug port',async()=>{try{return(await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).trim().split('\n');}catch{return undefined;}});
 socket=new WebSocket(`ws://127.0.0.1:${debug[0]}${debug[1]}`);await new Promise((resolve,reject)=>{socket.once('open',resolve);socket.once('error',reject);});const cdp=new CDP(socket);
 const {targetId}=await cdp.send('Target.createTarget',{url:`http://127.0.0.1:${server.address().port}/`}),{sessionId}=await cdp.send('Target.attachToTarget',{targetId,flatten:true});
 await cdp.send('Page.enable',{},sessionId);await until('Owned media element',()=>cdp.evaluate(sessionId,"Boolean(document.getElementById('element'))"));
 const capture=path.join(owned,'observer');await fs.mkdir(capture,{mode:0o700});
 observer=spawn(observerPath,['--pid',String(ownedChromePID),'--seconds','20','--out-dir',capture],{stdio:['pipe','pipe','pipe']});
 const client=new Observer(observer),ready=await client.receipt(v=>v.type==='ready');
 assert(ready.pid===ownedChromePID,'Observer exact owned Chrome identity');
 const epochOffset=ready.unixSeconds-ready.hostSeconds;
 assert(Number.isFinite(epochOffset),'Native host/wall clock anchor');
 console.log('Owned Chrome observer identity/anchor: '+JSON.stringify(ready));
 const noisePath=process.env.STREAM_CHROME_UNRELATED_TONE;
 assert(noisePath&&path.isAbsolute(noisePath),'Set independently owned native tone helper executable');
 noise=spawn(noisePath,['--native-tone','1320'],{stdio:['pipe','pipe','ignore']});
 await pause(800);
 await cdp.evaluate(sessionId,`(async()=>{const v=document.getElementById('element');v.src='/aligned.mp4';await new Promise((resolve,reject)=>{v.onloadeddata=resolve;v.onerror=reject;v.load();});})()`);
 await client.command('arm','unrelated-only');await cdp.evaluate(sessionId,"document.getElementById('element').play()");await pause(800);
 await cdp.evaluate(sessionId,"document.getElementById('element').pause()");
 const quiet=await client.command('snapshot','silence');
 assert(quiet.frames>=24000&&quiet.rms<.002&&quiet.peak<.01&&!Number.isFinite(quiet.firstLoudHostSeconds),'Exact Chrome filter must refuse unrelated native tone while Chrome is silent');
 console.log('OBSERVED owned Chrome silent while unrelated tone active (requires positive Chrome control before any exclusion claim): '+JSON.stringify(quiet));
 for(const name of ['aligned','audio-late','audio-early']){
  await cdp.evaluate(sessionId,`(async()=>{const old=document.getElementById('element'),v=document.createElement('video');v.id='element';v.playsInline=true;v.controls=true;v.width=320;v.height=180;old.replaceWith(v);v.src='/${name}.mp4';await new Promise((resolve,reject)=>{v.onloadeddata=resolve;v.onerror=reject;v.load();});window.videoCue=undefined;window.callbackCount=0;window.maximumCallbackDifference=0;const c=document.createElement('canvas');c.width=1;c.height=1;const draw=c.getContext('2d'),observe=(now,metadata)=>{draw.drawImage(v,0,0,1,1);window.callbackCount++;window.maximumCallbackDifference=Math.max(window.maximumCallbackDifference,Math.abs(now-metadata.expectedDisplayTime));const p=draw.getImageData(0,0,1,1).data;if(p[0]>200&&p[1]>200&&p[2]>200)window.videoCue??={now,expectedDisplayTime:metadata.expectedDisplayTime,timeOrigin:performance.timeOrigin,mediaTime:metadata.mediaTime};v.requestVideoFrameCallback(observe);};v.requestVideoFrameCallback(observe);})()`);
  await client.command('arm','arm-'+name);
  await cdp.evaluate(sessionId,"document.getElementById('element').play()");
  await until(`${name} authored playback ended`,()=>cdp.evaluate(sessionId,"document.getElementById('element').ended"));
  const receipt=await client.command('snapshot','snapshot-'+name);
  const video=await cdp.evaluate(sessionId,'({cue:window.videoCue,frames:window.callbackCount,maximumCallbackDifference:window.maximumCallbackDifference})');
  console.log('Actual normal-player observer receipt '+name+': '+JSON.stringify({receipt,video,headed:process.env.STREAM_CHROME_CALIBRATION_HEADED==='1'}));
  if(!Number.isFinite(receipt.firstLoudHostSeconds)){const unavailable=Error('Known-positive normal element output not observed for exact owned Chrome PID');unavailable.unqualified=true;throw unavailable;}
  assert(video.cue&&video.frames>=30&&video.maximumCallbackDifference<50,'Actual rVFC/display cue and bounded callback delta required');
  const offset=receipt.unixSeconds-receipt.hostSeconds;
  assert(Math.abs(offset-epochOffset)<.005,'Native host/wall clock mapping must stay within5ms');
  const pictureHostSeconds=(video.cue.timeOrigin+video.cue.expectedDisplayTime)/1000-offset;
  const deltaMilliseconds=(pictureHostSeconds-receipt.firstLoudHostSeconds)*1000;
  assert(Number.isFinite(deltaMilliseconds),'Original output PCM and browser display common-clock measurement');
  if(name==='aligned')assert(Math.abs(deltaMilliseconds)<100,'Actual aligned output/display must pass unchanged100ms bound');
  else assert(Math.abs(deltaMilliseconds)>100&&Math.sign(deltaMilliseconds)===(name==='audio-late'?-1:1),'Actual known150ms output/display offset must fail unchanged100ms bound with correct sign');
  console.log('PASS normal element exact-app output control '+name+': '+JSON.stringify({deltaMilliseconds,pictureHostSeconds,video,receipt}));
 }
 console.log(`PASS normal HTML element output/display0/+150/-150ms calibration; original SCK hostPTS retained; no WebAudio reroute; artifacts ${owned}`);
}catch(error){if(error.unqualified){console.log('UNQUALIFIED exact-app output observer: '+error.message);process.exitCode=77;}else throw error;}finally{
 observer?.stdin.end();if(observer?.exitCode===null){await Promise.race([new Promise(resolve=>observer.once('close',resolve)),pause(2000)]);if(observer.exitCode===null)observer.kill('SIGTERM');}noise?.stdin.end();if(noise?.exitCode===null)noise.kill('SIGTERM');
 chrome?.stdin?.end();if(process.env.STREAM_CHROME_LS_LAUNCHER&&chrome?.exitCode===null)await Promise.race([new Promise(resolve=>chrome.once('close',resolve)),pause(3000)]);
 socket?.close();if(chrome?.exitCode===null){try{process.kill(-chrome.pid,'SIGTERM');}catch{}await Promise.race([new Promise(resolve=>chrome.once('close',resolve)),pause(2000)]);if(chrome.exitCode===null)try{process.kill(-chrome.pid,'SIGKILL');}catch{}}
 await new Promise(resolve=>server?server.close(resolve):resolve());
}
