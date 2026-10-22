// Diagnostic only. Returns original API promises; never stores arguments,
// candidate/description objects, identifiers, error messages or timestamps.
export function createLoopbackSignalJournal(getPhase) {
  const phases=['not-started','create-offer','sender-local-description','receiver-remote-description',
    'receiver-pending-candidates','create-answer','receiver-local-description','sender-remote-description',
    'sender-pending-candidates','connection-wait','measuring','collecting-stats',
    'remote-track-before-html','remote-track-before-webaudio','remote-track-connected'];
  const select=(value,allowed)=>allowed.includes(value)?value:'unknown';
  const phase=()=>select(getPhase(),phases);
  const sides=['sender','receiver'],operations=['create-offer','create-answer','set-local-description','set-remote-description','add-ice-candidate'];
  const errors=['Error','OperationError','InvalidStateError','TypeError','NotSupportedError','NotAllowedError','AbortError','NetworkError','SyntaxError'];
  const bounded=n=>Math.min(1000000,n+1);
  let generation=0,active=false,sequence=0,events=[],droppedEvents=0,staleSettlements=0,counts=[];
  const record=event=>{sequence=bounded(sequence);if(events.length<64)events.push({sequence,generation,...event});else droppedEvents=bounded(droppedEvents);return sequence;};
  const key=(side,operation)=>counts.find(row=>row.side===side&&row.operation===operation);
  return {
    begin(){generation=bounded(generation);active=true;events=[];droppedEvents=0;counts=sides.flatMap(side=>operations.map(operation=>({side,operation,invoked:0,started:0,completed:0,rejected:0,inFlight:0})));},
    retire(){active=false;},
    note(side,kind){if(active)record({side:select(side,sides),kind:select(kind,['candidate-emitted','candidate-queued','candidate-end']),phase:phase()});},
    observe(side,operation,action){
      const owner=generation,owned=active,row=owned?key(side,operation):undefined,startPhase=phase();
      const invocation=owned?record({side:select(side,sides),operation:select(operation,operations),kind:'invoke',phase:startPhase}):0;
      if(row){row.invoked=bounded(row.invoked);row.started=bounded(row.started);row.inFlight=bounded(row.inFlight);}
      if(owned)record({side:select(side,sides),operation:select(operation,operations),kind:'start',phase:startPhase,invocation});
      const settle=(kind,error)=>{
        if(!owned||!active||generation!==owner){staleSettlements=bounded(staleSettlements);return;}
        if(row){row.inFlight=Math.max(0,row.inFlight-1);row[kind==='complete'?'completed':'rejected']=bounded(row[kind==='complete'?'completed':'rejected']);}
        record({side:select(side,sides),operation:select(operation,operations),kind,phase:startPhase,settlementPhase:phase(),invocation,
          ...(kind==='reject'?{error:select(error?.name,errors)}:{})});
      };
      let result;
      try{result=action();}catch(error){settle('reject',error);throw error;}
      // Observe without replacing the native promise or adding an await/drain.
      // The observer callbacks cannot reject their discarded child promise.
      if(result&&typeof result.then==='function')result.then(()=>settle('complete'),error=>settle('reject',error));
      else settle('complete');
      return result;
    },
    snapshot(){return {generation,active,sequence,staleSettlements,droppedEvents,
      counts:counts.map(row=>({...row})),events:events.map(row=>({...row}))};}
  };
}
