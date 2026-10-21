import assert from 'node:assert/strict';
import {test} from 'node:test';
import {GuestPublicChatView} from '../../public/public-chat.js';

const negotiation='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', feed='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const state=(overrides={})=>({type:'public-chat-state',negotiation,feed,enabled:true,reset:0,seq:0,dropped:0,
  adapters:{restream:'offline',youtube:'connected',twitch:'unavailable'},sources:[{id:'abcdef123456',platform:'YouTube',state:'Chat connected'}],sourcesTruncated:false,...overrides});
const message=(seq=1,overrides={})=>({type:'public-chat-message',negotiation,feed,reset:0,seq,dropped:0,id:`message-${seq}`,source:'abcdef123456',platform:'YouTube',author:'Viewer',roles:['Member'],text:'Hello 👩🏽‍🚀 世界 {host}',timestamp:1800000000,receiptTime:false,kind:'Super Chat',truncated:false,...overrides});
function fixture() {
  class Element {
    constructor(tag){this.tag=tag;this.children=[];this.dataset={};this.value='';}
    get textContent(){return this.value+this.children.map(value=>value.textContent).join('');}
    set textContent(value){this.value=value;this.children=[];}
    set innerHTML(_){assert.fail('Public provider text used HTML');}
    append(...values){for(const value of values){value.parent=this;this.children.push(value);}}
    replaceChildren(...values){this.children=[];this.value='';this.append(...values);}
    get firstElementChild(){return this.children[0];}
    remove(){const index=this.parent.children.indexOf(this);this.parent.children.splice(index,1);}
  }
  const f={now:10000,timers:new Map(),next:0};
  f.messages=new Element('div');f.status=new Element('p');f.sources=new Element('p');
  f.view=new GuestPublicChatView({...f,document:{createElement:tag=>new Element(tag)},clock:()=>f.now,
    interval:callback=>{const token=++f.next;f.timers.set(token,callback);return token;},cancel:token=>f.timers.delete(token)});
  f.advance=ms=>{f.now+=ms;for(const callback of f.timers.values())callback();};
  f.view.reset(negotiation);return f;
}

test('read-only public feed accepts bounded text only after current host opt-in and stays separate from private controls',()=>{
  const f=fixture();f.view.receive(message());assert.equal(f.messages.children.length,0);
  assert.equal(f.view.receive({type:'private-message',negotiation,id:feed,text:'private'}),false);
  f.view.receive(state());f.view.receive(message(1,{text:'<img src="https://never-fetch.invalid"> {host} 👋'}));
  assert.equal(f.messages.children.length,1);assert.equal(f.messages.children[0].children[1].textContent,'<img src="https://never-fetch.invalid"> {host} 👋');
  assert(f.sources.textContent.includes('youtube: connected'));assert(f.sources.textContent.includes('twitch: unavailable'));
  const current=f.messages.textContent;
  for(const value of [message(2,{negotiation:feed}),message(2,{feed:negotiation}),message(2,{text:'x'.repeat(513)}),message(2,{author:'x'.repeat(65)}),message(2,{kind:'Reaction'}),message(2,{timestamp:NaN}),message(2,{roles:['Admin']}),{...message(2),html:'<script>'}])f.view.receive(value);
  assert.equal(f.messages.textContent,current);
});

test('bounded guest history preserves Unicode/clipping disclosure and rejects sequence/reset replays',()=>{
  const f=fixture();f.view.receive(state());
  for(let seq=1;seq<=40;seq++){
    f.advance(400);if(seq%5===0)f.view.receive(state({seq:seq-1,dropped:2}));
    f.view.receive(message(seq,{text:seq===40?'𐐷'.repeat(128):`Public ${seq}`,truncated:seq===40,dropped:2}));
  }
  assert.equal(f.messages.children.length,32);assert.equal(f.messages.children[0].dataset.id,'message-9');
  assert.equal(f.messages.children.at(-1).children[1].textContent,'𐐷'.repeat(128));assert(f.messages.children.at(-1).textContent.includes('clipped'));
  assert(f.status.textContent.includes('2 messages omitted'));
  f.advance(1000);f.view.receive(state({reset:1,seq:40}));assert.equal(f.messages.children.length,0);
  f.view.receive(message(41));assert.equal(f.messages.children.length,0);
  f.view.receive(message(41,{reset:1}));assert.equal(f.messages.children.length,1);
  f.view.receive(message(40,{reset:1}));assert.equal(f.messages.children.length,1);
});

test('lost OFF notification becomes stale and clears without replay; old enabled/off controls cannot affect a replacement feed',()=>{
  const f=fixture();f.view.receive(state());f.view.receive(message());
  f.advance(6501);assert.equal(f.messages.children.length,0);assert(f.status.textContent.includes('stale'));assert.equal(f.timers.size,0);
  f.view.receive(message(2));assert.equal(f.messages.children.length,0);
  f.view.receive(state({seq:10}));f.view.receive(message(9));assert.equal(f.messages.children.length,0);
  f.view.receive(message(11));assert.equal(f.messages.children.length,1);
  f.advance(1000);f.view.receive(state({enabled:false,seq:11}));assert.equal(f.messages.children.length,0);
  f.view.receive(state({seq:11}));f.view.receive(message(12));assert.equal(f.messages.children.length,0);
  const next='cccccccc-cccc-4ccc-8ccc-cccccccccccc';f.view.receive(state({feed:next}));f.view.receive(message(1,{feed:next}));
  f.view.receive(state({enabled:false}));assert.equal(f.messages.children.length,1);assert.equal(f.status.dataset.active,'true');
  f.view.reset();assert.equal(f.messages.children.length,0);assert.equal(f.timers.size,0);
  f.view.reset(feed);f.view.receive(state());f.view.receive(message());assert.equal(f.messages.children.length,0);
});

test('delayed public frame cannot revive stale history when the browser timer has not fired',()=>{
  const f=fixture();f.view.receive(state());f.view.receive(message());
  f.now+=6501; // Simulate a suspended/throttled tab without running its timer.
  assert.equal(f.messages.children.length,1);
  f.view.receive(message(2));
  assert.equal(f.messages.children.length,0);assert.equal(f.status.dataset.active,'false');
  assert(f.status.textContent.includes('stale'));assert.equal(f.timers.size,0);
  f.view.receive(state({seq:10}));f.view.receive(message(9));
  assert.equal(f.messages.children.length,0);
  f.view.receive(message(11));assert.equal(f.messages.children.length,1);
});

test('public inbound flood remains bounded while OFF always clears',()=>{
  const f=fixture();f.view.receive(state());for(let seq=1;seq<1000;seq++)f.view.receive(message(seq));
  assert(f.messages.children.length<=8);f.view.receive(state({enabled:false}));assert.equal(f.messages.children.length,0);
});

test('default browser timers retain their global receiver and are cancelled on Off',()=>{
  const previousInterval=globalThis.setInterval,previousCancel=globalThis.clearInterval;
  let started=0,cancelled=0;
  try {
    globalThis.setInterval=function(){assert.equal(this,globalThis);started++;return 123;};
    globalThis.clearInterval=function(token){assert.equal(this,globalThis);assert.equal(token,123);cancelled++;};
    const f=fixture();
    const view=new GuestPublicChatView({messages:f.messages,status:f.status,sources:f.sources,document:{createElement:()=>assert.fail('No messages expected')}});
    view.reset(negotiation);view.receive(state());assert.equal(started,1);
    view.receive(state({enabled:false}));assert.equal(cancelled,1);
  } finally {globalThis.setInterval=previousInterval;globalThis.clearInterval=previousCancel;}
});
