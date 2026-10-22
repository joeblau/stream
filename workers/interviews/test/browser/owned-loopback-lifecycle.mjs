import fs from 'node:fs/promises';
import {writeFileSync} from 'node:fs';

// No asynchronous completion can undo an abort, including during cleanup or
// receipt publication. Signal listeners stay installed until process exit.
export function createLoopbackTerminal(artifact,{processTarget=process,writeSync=writeFileSync}={}) {
  let result,reason,published=false;
  const encode=()=>JSON.stringify(result,null,2)+'\n';
  const latch=()=>{
    if(reason){
      processTarget.exitCode=77;
      if(result){result.result='UNQUALIFIED';result.reason=reason;result.failureSnapshot??={status:'unavailable',reason:'owned-abort'};}
    }
  };
  return {
    get abortReason(){return reason;},
    bind(value){result=value;latch();},
    abort(signal){reason??='owned-signal-'+signal;latch();if(published)writeSync(artifact,encode(),{mode:0o600});},
    complete(){if(reason)latch();else result.result='DIAGNOSTIC_COMPLETE';},
    async publish(write=fs.writeFile){
      latch();
      await write(artifact,encode(),{mode:0o600});
      published=true;
      // A signal may have arrived while the serialized earlier value was
      // being written. A later signal also rewrites synchronously in abort.
      latch();if(reason)writeSync(artifact,encode(),{mode:0o600});
    }
  };
}

export async function removeOwnedLoopbackDirectory(directory,expected,{filesystem=fs,uid=process.getuid()}={}) {
  let info;
  try{info=await filesystem.lstat(directory,{bigint:true});}
  catch(error){if(error.code==='ENOENT')return 'absent';throw error;}
  if(!info.isDirectory()||info.uid!==BigInt(uid)||info.dev.toString()!==expected.device||info.ino.toString()!==expected.inode)
    return 'incarnation-mismatch';
  // No intervening asynchronous operation between the identity check and
  // removal. Never resolve a replacement symlink to a different directory.
  await filesystem.rm(directory,{recursive:true,force:true,maxRetries:5,retryDelay:100});
  return 'removed';
}
