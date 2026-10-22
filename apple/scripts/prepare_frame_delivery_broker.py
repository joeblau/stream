#!/usr/bin/env python3
"""Prepare actual engine/broker isolation proof; negative returns the source sample only."""
import argparse,hashlib,json,pathlib,subprocess
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=pathlib.Path)
parser.add_argument('--negative-control',action='store_true')
parser.add_argument('--sequence-negative-control',action='store_true')
parser.add_argument('--fractional-geometry',action='store_true')
args=parser.parse_args();root=pathlib.Path(__file__).resolve().parents[1]
folder=(args.output or root/'build/frame-delivery-broker-validation').resolve();folder.mkdir(parents=True,exist_ok=True)
source=(root/'StreamMac/CompositionEngine.swift').read_text()
assert source.count('guard permitsClockOperation(clockAuthority) else { return } // CLOCK_AUTHORITY_GUARD') == 2
(folder/'CompositionEngine.swift').write_text(source)
broker=(root/'StreamMac/FrameDeliveryBroker.swift').read_text()
negative='            return CompositedFrame(sampleBuffer: sample,\n                presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),'
assert broker.count(negative)==1
compiled=broker.replace(negative,negative.replace('sampleBuffer: sample,','sampleBuffer: source.sampleBuffer,')) if args.negative_control else broker
if args.sequence_negative_control:
 assert not args.negative_control
 lookup='ring.first(where: { $0.id == intent.publication })?.frame'
 assert compiled.count(lookup)==1
 compiled=compiled.replace(lookup,'ring.first(where: { $0.frame.sequence == intent.sequence })?.frame')
(folder/'FrameDeliveryBroker.swift').write_text(compiled)
clock=(root/'scripts/composition_clock_authority_harness.swift').read_text()
assert clock.count('@main enum CompositionClockAuthorityHarness')==1
(folder/'clock_cases.swift').write_text(clock.replace('@main enum CompositionClockAuthorityHarness','enum CompositionClockAuthorityHarness'))
ruby=r'''require 'yaml';require 'json';root=ARGV[0];folder=ARGV[1]
spec=YAML.load_file(File.join(root,'project.yml'));spec['name']='FrameDeliveryBroker'
spec['packages'].each_value{|p|p['path']=File.join(ENV.fetch('STREAM_VENDOR_ROOT',File.join(root,'Vendor')),File.basename(p['path'])) if p['path']}
spec['targets'].select!{|name,_|['StreamCore','StreamMac'].include?(name)};spec['schemes']={}
spec['targets'].each_value do |t|
 t['dependencies']&.reject!{|d|d['target']&&!spec['targets'].key?(d['target'])}
 t['sources'].map!{|s|s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))};t.delete('entitlements')
end
h=spec['targets'].delete('StreamMac');h['type']='tool'
h['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift','CompositionEngine.swift','FrameDeliveryBroker.swift']}
h['sources']<<File.join(folder,'CompositionEngine.swift')
h['sources']<<File.join(folder,'FrameDeliveryBroker.swift')
h['sources']<<File.join(folder,'clock_cases.swift')
h['sources']<<File.join(root,'scripts/frame_delivery_broker_harness.swift')
h['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
spec['targets']['FrameDeliveryBrokerHarness']=h
spec['schemes']['FrameDeliveryBrokerHarness']={'build'=>{'targets'=>{'FrameDeliveryBrokerHarness'=>'all'}}}
require File.join(root,'scripts/desktop_transport_fixture');StreamDesktopTransportFixture.apply(h,root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))'''
subprocess.run(['ruby','-e',ruby,str(root),str(folder)],check=True)
sha=lambda b:hashlib.sha256(b).hexdigest()
receipt={'sourceCommit':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),'negativeControl':args.negative_control,'sourceAliasChanges':1 if args.negative_control else 0,'sequenceLookupChanges':1 if args.sequence_negative_control else 0,'engineSHA256':sha(source.encode()),'brokerSHA256':sha(broker.encode()),'compiledBrokerSHA256':sha(compiled.encode()),'harnessSHA256':sha((root/'scripts/frame_delivery_broker_harness.swift').read_bytes()),'clockHarnessSHA256':sha(clock.encode()),'scope':'Actual CompositionEngine/SceneRenderer/source pool4/broker/native CVPixelBuffer and IOSurface escape/retirement. Negative changes only the returned sample from detached to original. All six unchanged real clock cases retained. No capture, network, media workload or timing benchmark.'}
(folder/('sequence-negative-source.json' if args.sequence_negative_control else 'negative-source.json'if args.negative_control else'production-source.json')).write_text(json.dumps(receipt,indent=2)+'\n')
print(folder)
