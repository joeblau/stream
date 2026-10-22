#!/usr/bin/env python3
"""Prepare actual-engine mailbox retirement proof; negative removes only removal closes."""
import argparse,hashlib,json,pathlib,subprocess
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=pathlib.Path)
parser.add_argument('--negative-control',action='store_true')
args=parser.parse_args();root=pathlib.Path(__file__).resolve().parents[1]
folder=(args.output or root/'build/composition-mailbox-retirement-validation').resolve();folder.mkdir(parents=True,exist_ok=True)
source=(root/'StreamMac/CompositionEngine.swift').read_text()
closes='        primary?.close()\n        secondary?.close()\n        clean?.close()'
assert source.count(closes)==1
compiled=source.replace(closes,'        // Negative control: only three removal close calls omitted.')if args.negative_control else source
(folder/'CompositionEngine.swift').write_text(compiled)
clock=(root/'scripts/composition_clock_authority_harness.swift').read_text()
assert clock.count('@main enum CompositionClockAuthorityHarness')==1
clock=clock.replace('@main enum CompositionClockAuthorityHarness','enum CompositionClockAuthorityHarness')
(folder/'clock_cases.swift').write_text(clock)
ruby=r'''require 'yaml';require 'json';root=ARGV[0];folder=ARGV[1]
spec=YAML.load_file(File.join(root,'project.yml'));spec['name']='CompositionMailboxRetirement'
spec['packages'].each_value{|p|p['path']=File.join(ENV.fetch('STREAM_VENDOR_ROOT',File.join(root,'Vendor')),File.basename(p['path'])) if p['path']}
spec['targets'].select!{|name,_|['StreamCore','StreamMac'].include?(name)};spec['schemes']={}
spec['targets'].each_value do |t|
 t['dependencies']&.reject!{|d|d['target']&&!spec['targets'].key?(d['target'])}
 t['sources'].map!{|s|s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))};t.delete('entitlements')
end
h=spec['targets'].delete('StreamMac');h['type']='tool'
h['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift','CompositionEngine.swift']}
h['sources']<<File.join(folder,'CompositionEngine.swift')
h['sources']<<File.join(folder,'clock_cases.swift')
h['sources']<<File.join(root,'scripts/composition_mailbox_retirement_harness.swift')
h['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
spec['targets']['CompositionMailboxRetirementHarness']=h
spec['schemes']['CompositionMailboxRetirementHarness']={'build'=>{'targets'=>{'CompositionMailboxRetirementHarness'=>'all'}}}
require File.join(root,'scripts/desktop_transport_fixture');StreamDesktopTransportFixture.apply(h,root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))'''
subprocess.run(['ruby','-e',ruby,str(root),str(folder)],check=True)
sha=lambda b:hashlib.sha256(b).hexdigest()
receipt={'sourceCommit':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),'negativeControl':args.negative_control,'removalCloseCallsRemoved':3 if args.negative_control else 0,'sourceSHA256':sha(source.encode()),'compiledEngineSHA256':sha(compiled.encode()),'harnessSHA256':sha((root/'scripts/composition_mailbox_retirement_harness.swift').read_bytes()),'clockHarnessSHA256':sha((root/'scripts/composition_clock_authority_harness.swift').read_bytes()),'compiledClockCasesSHA256':sha(clock.encode()),'scope':'Actual CompositionEngine/SceneRenderer/pool4/mailbox callbacks with owned16px shape. Deterministic semaphore/continuation ownership gates, no media/capture/timing benchmark. Six unchanged actual clock cases included after only removing their @main entry annotation.'}
(folder/('negative-source.json'if args.negative_control else'production-source.json')).write_text(json.dumps(receipt,indent=2)+'\n')
print(folder)
