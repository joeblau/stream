// Fixture-only consumption path. Chromium clones srcObject tracks for
// HTMLMediaElement.captureStream, so it cannot observe element presentation.
export const renderedReturnWorklet = `
class RenderedReturnCue extends AudioWorkletProcessor {
  constructor(){super();this.cue=undefined;this.revision=0;this.frames=0;this.peak=0;this.port.onmessage=e=>{if(e.data?.type==='reset'){this.cue=undefined;this.revision=e.data.revision;this.frames=0;this.peak=0;}};}
  process(inputs,outputs){
    const channels=inputs[0],out=outputs[0];
    this.frames+=out[0]?.length??128;
    if(!channels?.length){if(this.frames%1024===0)this.port.postMessage({revision:this.revision,cueContextSeconds:this.cue,frames:this.frames,peak:this.peak,inputChannels:0});return true;}
    for(const channel of channels)for(const sample of channel)this.peak=Math.max(this.peak,Math.abs(sample));
    if(this.frames%1024===0)this.port.postMessage({revision:this.revision,cueContextSeconds:this.cue,frames:this.frames,peak:this.peak,inputChannels:channels.length});
    for(let side=0;side<out.length;side++)out[side].set(channels[Math.min(side,channels.length-1)]);
    if(this.cue===undefined){for(let i=0;i<channels[0].length;i++)if(channels.some(c=>Math.abs(c[i])>.025)){
      this.cue=(currentFrame+i)/sampleRate;this.port.postMessage({revision:this.revision,cueContextSeconds:this.cue});break;
    }}
    return true;
  }
}
registerProcessor('stream-rendered-return-cue',RenderedReturnCue);`;

// The returned recorder stream is instrumented element→WebAudio audio and
// rVFC→canvas video. It intentionally changes the audio consumer. It proves
// this path only, never physical output or untouched HTMLMediaElement playback.
export const installRenderedReturnOracle = String.raw`async function(element){
  const context=new AudioContext({sampleRate:48000});await context.resume();
  await context.audioWorklet.addModule('/fixture-rendered-return-cue.js');
  const source=context.createMediaElementSource(element),meter=new AudioWorkletNode(context,'stream-rendered-return-cue',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[2]}),destination=context.createMediaStreamDestination();
  source.connect(meter);meter.connect(destination);meter.connect(context.destination);
  const canvas=document.createElement('canvas');canvas.width=element.videoWidth;canvas.height=element.videoHeight;
  const draw=canvas.getContext('2d'),video=canvas.captureStream(0).getVideoTracks()[0];
  const rawTrack=element.srcObject?.getAudioTracks?.()[0],rawSource=rawTrack?context.createMediaStreamSource(new MediaStream([rawTrack])):undefined,rawMeter=new AudioWorkletNode(context,'stream-rendered-return-cue',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[2]}),silent=context.createGain();silent.gain.value=0;rawSource?.connect(rawMeter);rawMeter.connect(silent).connect(context.destination);
  const value={context,source,meter,destination,video,rawSource,rawMeter,revision:0,audioCue:undefined,rawAudioCue:undefined,videoCue:undefined,frames:0,maxCallbackDisplayDifference:0};
  meter.port.onmessage=e=>{if(e.data.revision===value.revision){value.audioCue=e.data.cueContextSeconds;value.elementPCM=e.data;}};
  rawMeter.port.onmessage=e=>{if(e.data.revision===value.revision){value.rawAudioCue=e.data.cueContextSeconds;value.rawPCM=e.data;}};
  let callback,stopped=false;
  const observe=(now,metadata)=>{
    if(stopped)return;
    draw.drawImage(element,0,0,canvas.width,canvas.height);
    const p=draw.getImageData(canvas.width/2,canvas.height/2,1,1).data;
    value.frames++;value.maxCallbackDisplayDifference=Math.max(value.maxCallbackDisplayDifference,Math.abs(now-metadata.expectedDisplayTime));
    if(p[0]>200&&p[1]>200&&p[2]>200&&value.videoCue===undefined)value.videoCue={callbackNow:now,expectedDisplayTime:metadata.expectedDisplayTime,mediaTime:metadata.mediaTime};
    video.requestFrame();callback=element.requestVideoFrameCallback(observe);
  };
  callback=element.requestVideoFrameCallback(observe);
  value.stream=new MediaStream([video,...destination.stream.getAudioTracks()]);
  value.reset=()=>{value.audioCue=undefined;value.rawAudioCue=undefined;value.videoCue=undefined;const command={type:'reset',revision:++value.revision};meter.port.postMessage(command);rawMeter.port.postMessage(command);};
  value.measure=()=>{const stamp=context.getOutputTimestamp(),audio=value.audioCue===undefined?undefined:stamp.performanceTime+(value.audioCue-stamp.contextTime)*1000;return{elementPCM:value.elementPCM,rawPCM:value.rawPCM,rawAudioMilliseconds:value.rawAudioCue===undefined?undefined:stamp.performanceTime+(value.rawAudioCue-stamp.contextTime)*1000,video:value.videoCue,audioMilliseconds:audio,deltaMilliseconds:value.videoCue?.expectedDisplayTime-audio,callbackDeltaMilliseconds:value.videoCue?.callbackNow-audio,frames:value.frames,maxCallbackDisplayDifference:value.maxCallbackDisplayDifference,baseLatency:context.baseLatency,outputLatency:context.outputLatency};};
  value.stop=async()=>{stopped=true;element.cancelVideoFrameCallback(callback);video.stop();destination.stream.getTracks().forEach(t=>t.stop());source.disconnect();meter.disconnect();rawSource?.disconnect();rawMeter.disconnect();await context.close();};
  return value;
}`;
