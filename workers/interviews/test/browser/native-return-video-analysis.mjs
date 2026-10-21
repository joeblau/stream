import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';

function run(binary,args,binaryOutput=false){
  const result=spawnSync(binary,args,{encoding:binaryOutput?undefined:'utf8',maxBuffer:4*1024*1024,timeout:10000});
  assert(result.status===0&&!result.error,`Owned ${binary} media analysis failed`);return result.stdout;
}
export function analyzeReturnAV(file){
  const frames=kind=>JSON.parse(run('ffprobe',['-v','error','-select_streams',`${kind}:0`,'-show_frames','-show_entries','frame=best_effort_timestamp_time,nb_samples','-of','json',file])).frames;
  const video=frames('v'),audio=frames('a');
  const pixels=run('ffmpeg',['-v','error','-i',file,'-map','0:v:0','-vf','scale=1:1:flags=area','-pix_fmt','rgb24','-fps_mode','passthrough','-f','rawvideo','pipe:1'],true);
  assert(pixels.length===video.length*3&&video.length>=10,'Actual decoded return video frame count');
  const white=video.findIndex((_,i)=>pixels[i*3]>200&&pixels[i*3+1]>200&&pixels[i*3+2]>200);
  assert(white>0&&pixels[0]<8&&pixels[1]<8&&pixels[2]<8,'Actual return recording starts black and later turns white');
  const pcm=run('ffmpeg',['-v','error','-i',file,'-map','0:a:0','-ac','2','-ar','48000','-f','f32le','pipe:1'],true);
  const samples=audio.reduce((sum,f)=>sum+Number(f.nb_samples),0);
  assert(pcm.length===samples*8&&samples>=48000,'Actual decoded return PCM counts');
  let offset=0,tone;
  for(const frame of audio){
    const count=Number(frame.nb_samples);
    for(let i=0;i<count&&tone===undefined;i++)if(Math.max(Math.abs(pcm.readFloatLE((offset+i)*8)),Math.abs(pcm.readFloatLE((offset+i)*8+4)))>.025)tone=Number(frame.best_effort_timestamp_time)+i/48000;
    offset+=count;
  }
  const flash=Number(video[white].best_effort_timestamp_time);
  assert(tone!==undefined&&tone>.1&&flash>.1,'Recorded actual decoded return has distinct silent/black baseline and tone/flash cues');
  const delta=flash-tone;
  assert(Math.abs(delta)<.1,`Decoded captured-track flash/tone delta ${delta}s exceeds100ms`);
  return{videoFrames:video.length,audioFrames:samples,flashSeconds:flash,toneSeconds:tone,deltaSeconds:delta,maximumDeltaSeconds:.1};
}
