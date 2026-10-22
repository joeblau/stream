// Diagnostic-only, self-contained so the exact function can run inside the
// owned browser. Never return SDP, IDs, addresses, error text or raw samples.
export async function captureLoopbackFailure({phase, peers=[], contexts=[], track, player,
  senderPCM, receiverPCM, iceErrors=[]}) {
  const number=value=>typeof value==='number'&&Number.isFinite(value)&&value>=0&&value<=Number.MAX_SAFE_INTEGER?value:undefined;
  const choice=(value,allowed)=>allowed.includes(value)?value:'unknown';
  const fields=(value,names)=>Object.fromEntries(names.flatMap(name=>{
    const n=number(value?.[name]);return n===undefined?[]:[[name,n]];
  }));
  const pcm=value=>({available:Boolean(value),...fields(value,['frames','rate','windows']),
    channels:(Array.isArray(value?.channels)?value.channels:[]).slice(0,2).map(channel=>({
      ...fields(channel,['rms']),amplitudes:(Array.isArray(channel?.amplitudes)?channel.amplitudes:[])
        .slice(0,4).map(value=>number(value)??null)}))});
  const phases=['not-started','sender-context','receiver-context','create-offer','sender-local-description',
    'receiver-remote-description','create-answer','receiver-local-description','sender-remote-description',
    'receiver-pending-candidates','sender-pending-candidates','connection-wait','measuring','collecting-stats',
    'remote-track-before-html','remote-track-before-webaudio','remote-track-connected',
    ...['sender','receiver'].flatMap(side=>['constructor','resume','worklet','ready'].map(step=>side+'-'+step))];
  const ownedPeers=peers.slice(0,2);
  // Freeze synchronous evidence before awaiting a possibly stalled getStats.
  const value={phase:choice(phase,phases),peers:ownedPeers.map(peer=>({
    connection:choice(peer.connectionState,['new','connecting','connected','disconnected','failed','closed']),
    iceConnection:choice(peer.iceConnectionState,['new','checking','connected','completed','disconnected','failed','closed']),
    iceGathering:choice(peer.iceGatheringState,['new','gathering','complete']),
    signaling:choice(peer.signalingState,['stable','have-local-offer','have-remote-offer','have-local-pranswer','have-remote-pranswer','closed']),
    localCandidateCount:Math.min(128,(peer.localDescription?.sdp?.match(/^a=candidate:/gm)||[]).length),
    remoteCandidateCount:Math.min(128,(peer.remoteDescription?.sdp?.match(/^a=candidate:/gm)||[]).length)
  })),contexts:contexts.slice(0,2).map(context=>({
    state:choice(context.state,['suspended','running','closed','interrupted']),
    nullSink:context.sinkId?.type==='none',...fields(context,['sampleRate','currentTime'])
  })),track:track?{enabled:track.enabled===true,muted:track.muted===true,
    readyState:choice(track.readyState,['live','ended'])}:null,
  html:player?{muted:player.muted===true,paused:player.paused===true,...fields(player,['readyState','currentTime'])}:null,
  senderPCM:pcm(senderPCM),receiverPCM:pcm(receiverPCM),
  iceErrors:iceErrors.slice(0,8).map(error=>({
    side:choice(error.side,['sender','receiver']),
    name:choice(error.name,['Error','OperationError','InvalidStateError','TypeError','NotSupportedError','NotAllowedError','AbortError','NetworkError']),
    ...fields(error,['code'])
  }))};
  const candidateType=value=>choice(value,['host','srflx','prflx','relay']);
  const completed=ownedPeers.map(()=>({status:'timeout'}));
  let timer;
  const requests=ownedPeers.map(async(peer,index)=>{
    try {
      const report=await peer.getStats(),result={status:'available',outbound:[],inbound:[],playout:[],transport:[]};
      let inspected=0;
      for(const row of report.values()){
        if(++inspected>256)break;
        const codec=report.get(row.codecId);
        const audio={codec:codec?.mimeType==='audio/opus'?'audio/opus':'other',...fields(codec,['clockRate','channels','payloadType'])};
        if(row.type==='outbound-rtp'&&row.kind==='audio'&&result.outbound.length<2)
          result.outbound.push({...audio,...fields(row,['packetsSent','bytesSent'])});
        if(row.type==='inbound-rtp'&&row.kind==='audio'&&result.inbound.length<2)
          result.inbound.push({...audio,...fields(row,['packetsReceived','bytesReceived','packetsLost','jitterBufferEmittedCount',
            'jitterBufferDelay','totalSamplesReceived','totalSamplesDuration','totalAudioEnergy','concealedSamples'])});
        if(row.type==='media-playout'&&result.playout.length<2)
          result.playout.push({kind:choice(row.kind,['audio','video']),...fields(row,['synthesizedSamplesDuration',
            'synthesizedSamplesEvents','totalSamplesDuration','totalPlayoutDelay','totalSamplesCount'])});
        if(row.type==='transport'&&row.selectedCandidatePairId&&result.transport.length<2){
          const pair=report.get(row.selectedCandidatePairId);
          result.transport.push({state:choice(pair?.state,['frozen','waiting','in-progress','failed','succeeded']),
            local:candidateType(report.get(pair?.localCandidateId)?.candidateType),
            remote:candidateType(report.get(pair?.remoteCandidateId)?.candidateType)});
        }
      }
      completed[index]=result;
    }catch{completed[index]={status:'unavailable'};}
  });
  try {
    // Failure-only receipt budget, not additional initialization/measurement
    // time. A late API result cannot rescue acceptance or delay peer cleanup.
    await Promise.race([Promise.all(requests),new Promise(resolve=>{timer=setTimeout(resolve,500);})]);
  }finally{clearTimeout(timer);}
  return {...value,stats:completed.slice()};
}
