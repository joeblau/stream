import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { StudioClient, type Capability, type Snapshot } from "../src/studio-client.ts";
import { feedback } from "../src/feedback.ts";

const state = (): Snapshot => ({ projectID: randomUUID(), revision: 1, stream: "idle", recording: "idle", preview: "active",
  pendingStagedEdits: false, layerVisibility: {}, macroProgress: {phase:"idle",stepIndex:0,totalSteps:0,message:""} });
const wait = async (check:()=>boolean) => { for(let i=0;i<500;i++){if(check())return;await new Promise(resolve=>setTimeout(resolve,10));}assert.fail("IPC fixture timed out"); };

test("configured guest slots, profile requests and provider readings use authoritative feedback",()=>{
  const snapshot=state(),slot=randomUUID(),destination=randomUUID(),project=randomUUID(),profile=randomUUID();
  snapshot.guestSlots=[{id:slot,name:"Ada",media:"ready",membership:"backstage",muted:true,solo:false}];
  snapshot.showProfiles={projectID:randomUUID(),profileID:randomUUID(),canSelect:false,requestedProjectID:project,requestedProfileID:profile};
  snapshot.audience={observedAt:1000,liveSeconds:3661,health:"reconnecting",readings:[{destinationID:destination,name:"One",count:0,readAt:999,freshness:"current"}],presetDelivery:{}};
  const commands=new Map<string,Capability>();
  const read=(id:string,scope?:"studio"|"project")=>{
    commands.set(id,{id,title:"Controller",category:"Interaction",available:true,scope});
    return feedback({commandID:id,projectID:snapshot.projectID},"Connected",snapshot,commands,1000);
  };
  assert.equal(read(`guest.slot.${slot}.mute`).badge,"MUTED");
  snapshot.guestSlots[0].solo=true;assert.equal(read(`guest.slot.${slot}.solo`).badge,"MONITOR SOLO");
  assert.equal(read(`show.${project}.profile.${profile}.select`,"studio").badge,"REQUESTED");
  snapshot.showProfiles.projectID=project;snapshot.showProfiles.profileID=profile;
  assert.equal(read(`show.${project}.profile.${profile}.select`,"studio").badge,"CURRENT");
  assert.equal(read(`audience.${destination}.viewers`).badge,"0 VIEWERS","zero must remain distinct from unknown");
  snapshot.audience.readings[0].count=undefined;snapshot.audience.readings[0].freshness="unavailable";
  assert.equal(read(`audience.${destination}.viewers`).badge,"UNAVAILABLE");
  snapshot.audience.readings[0].count=23;snapshot.audience.readings[0].freshness="current";snapshot.audience.readings[0].readAt=939;
  assert.equal(read(`audience.${destination}.viewers`).badge,"EXPIRED","old provider readings cannot masquerade as current");
  assert.equal(read("audience.liveTime").badge,"1:01:01");assert.equal(read("audience.health").badge,"RECONNECTING");
  snapshot.audience.readings.push({destinationID:randomUUID(),name:"Other provider",count:900,readAt:1000,freshness:"current"});
  assert.equal(read("audience.viewers").badge,"2 SOURCES","counts from services must never be silently summed");
  assert.equal(feedback({commandID:"audience.viewers",projectID:snapshot.projectID},"Connected",snapshot,commands,1006).title,"Stale\nFeedback");
  snapshot.guestSlots=[];assert.equal(read(`guest.slot.${slot}.mute`).title,"Missing\nSlot");
});

test("real IPC client carries current authority, keeps profile scope explicit and only refreshes read-only controls",async()=>{
  const snapshot=state(),session=randomUUID(),slot=randomUUID(),project=randomUUID(),profile=randomUUID();
  const guest=`guest.slot.${slot}.mute`,show=`show.${project}.profile.${profile}.select`;
  let authority="a".repeat(64),calls:any[]=[],connections=0;
  const sockets=new Set<net.Socket>();
  const commands=():Capability[]=>[
    {id:guest,title:"Mute configured Ada",category:"Guests",available:true,authority,bindingIntent:"configuredSlot"},
    {id:show,title:"Select show profile",category:"Show Profiles",available:true,scope:"studio",authority:"runtime-source"},
    {id:"audience.viewers",title:"Viewers",category:"Audience",available:true,kind:"feedback"},
    {id:"audio.microphone.mute",title:"Mic",category:"Audio",available:true,scope:"studio"}
  ];
  const server=net.createServer(socket=>{
    connections++;sockets.add(socket);socket.on("close",()=>sockets.delete(socket));let buffer="";
    socket.on("data",data=>{
      buffer+=data.toString();let newline:number;
      while((newline=buffer.indexOf("\n"))>=0){
        const request=JSON.parse(buffer.slice(0,newline));buffer=buffer.slice(newline+1);calls.push(request);
        const reply=(value:unknown)=>socket.write(JSON.stringify(value)+"\n");
        const base={version:1,id:request.id,sessionID:session};
        if(request.type==="authenticate")reply({...base,type:"authenticated",snapshot});
        else if(request.type==="subscribe"||request.type==="snapshot")reply({...base,type:"snapshot",snapshot});
        else if(request.type==="capabilities")reply({...base,type:"capabilities",commands:commands(),totalCommands:4});
        else if(request.type==="command")reply({...base,type:"result",snapshot,result:{succeeded:request.commandID!==guest||request.authority===authority}});
      }
    });
  });
  server.listen(0,"127.0.0.1");await once(server,"listening");
  const client=new StudioClient();
  try{
    client.configure({version:1,clientID:randomUUID(),token:"b".repeat(64),port:(server.address() as net.AddressInfo).port});
    await wait(()=>client.status==="Connected");
    await Promise.all([client.execute(guest,snapshot.projectID),client.execute(guest,snapshot.projectID)]);
    assert.equal(calls.filter(value=>value.type==="command"&&value.commandID===guest).length,2,"multiple bindings share one session without replay");
    assert(calls.filter(value=>value.commandID===guest).every(value=>value.authority==="a".repeat(64)));
    authority="c".repeat(64);
    await assert.rejects(client.execute(guest,snapshot.projectID),/rejected/);
    await client.refreshCatalog();await client.execute(guest,snapshot.projectID);
    assert.equal(calls.at(-1).authority,authority,"fresh deliberate configured-slot press uses the replacement's advertised authority");
    const mutations=calls.filter(value=>value.type==="command").length;
    const response=await client.execute("audience.viewers",snapshot.projectID);
    assert.equal(response.type,"snapshot");assert.equal(calls.filter(value=>value.type==="command").length,mutations);
    await client.execute(show,"a-different-source-profile");
    await assert.rejects(client.execute("audio.microphone.mute","a-different-source-profile"),/configured project/);
    const beforeReconnect=calls.filter(value=>value.type==="command").length;
    for(const socket of sockets)socket.destroy();
    await wait(()=>connections>=2&&client.status==="Connected");
    assert.equal(calls.filter(value=>value.type==="command").length,beforeReconnect,"reconnect must never replay any mutation or profile switch");
    await client.execute(guest,snapshot.projectID);
  } finally {client.close();for(const socket of sockets)socket.destroy();await new Promise<void>(resolve=>server.close(()=>resolve()));}
});
