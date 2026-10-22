// Diagnostic-only, self-contained so the exact function can run inside the
// owned browser. Never return SDP, IDs, addresses, error text or raw samples.
export async function captureLoopbackFailure({phase, peers=[], contexts=[], track, player,
  senderPCM, receiverPCM, iceErrors=[], signaling}) {
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
  const signalNames=['create-offer','create-answer','set-local-description','set-remote-description','add-ice-candidate'];
  const signalSnapshot=signaling?{
    ...fields(signaling,['generation','sequence','staleSettlements','droppedEvents']),active:signaling.active===true,
    counts:(Array.isArray(signaling.counts)?signaling.counts:[]).slice(0,10).map(row=>({
      side:choice(row.side,['sender','receiver']),operation:choice(row.operation,signalNames),
      ...fields(row,['invoked','started','completed','rejected','inFlight'])})),
    events:(Array.isArray(signaling.events)?signaling.events:[]).slice(0,64).map(row=>({
      ...fields(row,['sequence','generation','invocation']),side:choice(row.side,['sender','receiver']),
      kind:choice(row.kind,['invoke','start','complete','reject','candidate-emitted','candidate-queued','candidate-end']),
      phase:choice(row.phase,phases),
      ...(row.operation?{operation:choice(row.operation,signalNames)}:{}),
      ...(row.settlementPhase?{settlementPhase:choice(row.settlementPhase,phases)}:{}),
      ...(row.error?{error:choice(row.error,['Error','OperationError','InvalidStateError','TypeError','NotSupportedError','NotAllowedError','AbortError','NetworkError','SyntaxError'])}:{})
    })),inputTruncated:(signaling.counts?.length>10)||(signaling.events?.length>64)
  }:undefined;
  const ownedPeers=peers.slice(0,2);
  const description=value=>value?choice(value.type,['offer','pranswer','answer','rollback']):'absent';
  // Freeze synchronous evidence before awaiting a possibly stalled getStats.
  const value={phase:choice(phase,phases),signaling:signalSnapshot,peers:ownedPeers.map(peer=>({
    connection:choice(peer.connectionState,['new','connecting','connected','disconnected','failed','closed']),
    iceConnection:choice(peer.iceConnectionState,['new','checking','connected','completed','disconnected','failed','closed']),
    iceGathering:choice(peer.iceGatheringState,['new','gathering','complete']),
    signaling:choice(peer.signalingState,['stable','have-local-offer','have-remote-offer','have-local-pranswer','have-remote-pranswer','closed']),
    descriptions:{local:description(peer.localDescription),remote:description(peer.remoteDescription),
      currentLocal:description(peer.currentLocalDescription),currentRemote:description(peer.currentRemoteDescription),
      pendingLocal:description(peer.pendingLocalDescription),pendingRemote:description(peer.pendingRemoteDescription)},
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
  const pairState=value=>choice(value,['frozen','waiting','in-progress','failed','succeeded']);
  const candidate=value=>({type:candidateType(value?.candidateType),protocol:choice(value?.protocol,['udp','tcp']),
    tcpType:choice(value?.tcpType,['active','passive','so'])});
  const candidateCounts=()=>({count:0,types:{host:0,srflx:0,prflx:0,relay:0,unknown:0},
    protocols:{udp:0,tcp:0,unknown:0}});
  const completed=ownedPeers.map(()=>({status:'timeout'}));
  let timer;
  const requests=ownedPeers.map(async(peer,index)=>{
    try {
      const report=await peer.getStats(),result={status:'available',outbound:[],inbound:[],playout:[],transport:[],pairs:[],
        candidates:{local:candidateCounts(),remote:candidateCounts()},rowsInspected:0,rowsTruncated:false,
        countsAreLowerBounds:false,transportCount:0,pairCount:0,transportRowsTruncated:false,pairRowsTruncated:false};
      const rows=[];
      for(const row of report.values()){if(rows.length===256){result.rowsTruncated=true;result.countsAreLowerBounds=true;break;}rows.push(row);}
      result.rowsInspected=rows.length;
      const selected=new Set(rows.filter(row=>row.type==='transport'&&row.selectedCandidatePairId).map(row=>row.selectedCandidatePairId));
      for(const row of rows){
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
        if(row.type==='local-candidate'||row.type==='remote-candidate'){
          const counts=result.candidates[row.type==='local-candidate'?'local':'remote'];
          counts.count++;counts.types[candidateType(row.candidateType)]++;counts.protocols[choice(row.protocol,['udp','tcp'])]++;
        }
        if(row.type==='candidate-pair'){
          result.pairCount++;
          if(result.pairs.length<8)result.pairs.push({state:pairState(row.state),...(typeof row.nominated==='boolean'?{nominated:row.nominated}:{}),
            referencedAsSelected:selected.has(row.id),local:candidate(report.get(row.localCandidateId)),remote:candidate(report.get(row.remoteCandidateId)),
            ...fields(row,['requestsSent','requestsReceived','responsesSent','responsesReceived','consentRequestsSent',
              'packetsSent','packetsReceived','bytesSent','bytesReceived','currentRoundTripTime','totalRoundTripTime'])});
          else result.pairRowsTruncated=true;
        }
        if(row.type==='transport'){
          result.transportCount++;
          if(result.transport.length>=2){result.transportRowsTruncated=true;continue;}
          const referenced=report.get(row.selectedCandidatePairId),pair=referenced?.type==='candidate-pair'?referenced:undefined;
          result.transport.push({dtlsState:choice(row.dtlsState,['new','connecting','connected','closed','failed']),
            iceState:choice(row.iceState,['new','checking','connected','completed','disconnected','failed','closed']),
            iceRole:choice(row.iceRole,['unknown','controlling','controlled']),dtlsRole:choice(row.dtlsRole,['unknown','client','server']),
            selectedCandidatePairReference:Boolean(row.selectedCandidatePairId),selectedPairResolved:Boolean(pair),
            ...fields(row,['packetsSent','packetsReceived','bytesSent','bytesReceived','selectedCandidatePairChanges']),
            ...(pair?{state:pairState(pair.state),local:candidateType(report.get(pair.localCandidateId)?.candidateType),
              remote:candidateType(report.get(pair.remoteCandidateId)?.candidateType)}:{})});
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
