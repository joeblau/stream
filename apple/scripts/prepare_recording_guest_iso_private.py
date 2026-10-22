#!/usr/bin/env python3
"""Prepare actual full Mac source graph for the owned guest ISO handoff proof."""
import argparse, hashlib, json, pathlib, subprocess
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--core-framework-dir',type=pathlib.Path,required=True);a=p.parse_args()
apple=pathlib.Path(__file__).resolve().parents[1];folder=a.output.resolve()
subprocess.run(['python3',str(apple/'scripts/prepare_frame_delivery_broker.py'),'--output',str(folder)],check=True)
project=json.loads((folder/'project.json').read_text());project['name']='RecordingGuestISOPrivate';project['targets'].pop('StreamCore');target=project['targets'].pop('FrameDeliveryBrokerHarness')
target['dependencies']=[{'framework':str(a.core_framework_dir.resolve()/'StreamCore.framework'),'embed':False} if d.get('target')=='StreamCore' else d for d in target['dependencies']]
target['sources']=[v for v in target['sources'] if v not in [str(apple/'scripts/frame_delivery_broker_harness.swift'),str(folder/'clock_cases.swift')]]
target['sources'].append(str(apple/'scripts/recording_guest_iso_private_harness.swift'));target['settings']['base'].update(ARCHS='arm64',ONLY_ACTIVE_ARCH='YES')
project['targets']['RecordingGuestISOPrivateHarness']=target;project['schemes']={'RecordingGuestISOPrivateHarness':{'build':{'targets':{'RecordingGuestISOPrivateHarness':'all'}}}}
(folder/'project.json').write_text(json.dumps(project,indent=2)+'\n')
paths=[apple/'StreamMac'/v for v in ['RecordingVideoSourceFactory.swift','RecordingFrameDelivery.swift','IsolatedVideoTypes.swift','IsolatedVideoRecorder.swift','IsolatedRecordingTypes.swift','ProgramRecordingSession.swift','RecordingPreferences.swift','RecordingChatPaint.swift','GuestVideoFrameStore.swift','GuestMediaReceipts.swift','SceneRenderer.swift','FrameDeliveryConverter.swift','RawVideoResourceCoordinator.swift','LayerGraph.swift']]
paths += [apple/'StreamCore/RawVideoResourceBudget.swift',apple/'scripts/recording_guest_iso_private_harness.swift',pathlib.Path(__file__).resolve(),a.core_framework_dir.resolve()/'StreamCore.framework/StreamCore']
receipt={'sourceCommit':subprocess.check_output(['git','-C',str(apple),'rev-parse','HEAD'],text=True).strip(),'scope':'Actual full Mac graph compiled as arm64 tool; runtime only actual guest Factory/ISO worker/writer/decoder plus owned store/leases/BGRA/timeline. No Receiver/RTC/capture/mixer/StudioRuntime/StreamController.','sourceHashes':{str(v.resolve()):hashlib.sha256(v.read_bytes()).hexdigest() for v in paths}}
(folder/'iso-source-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
