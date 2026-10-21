// Read-only public provider text. This module never sends a control message,
// fetches media, uses HTML, or shares the operator's private conversation.
const bytes = value => typeof value === 'string' ? new TextEncoder().encode(value).length : Infinity;
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const uint = value => Number.isInteger(value) && value >= 0 && value <= 0xffffffff;
const kinds = ['Text','Emotes','Super Chat','Super Sticker','Membership','Milestone','Gift'];
const roles = ['Owner','Moderator','Member','Verified','VIP','Bot'];
const adapters = ['restream','youtube','twitch'];
const states = ['connected','connecting','offline','failed','unavailable'];

export class GuestPublicChatView {
  constructor({messages,status,sources,document,clock=()=>performance.now(),
    interval=(callback,ms)=>globalThis.setInterval(callback,ms),cancel=token=>globalThis.clearInterval(token)}) {
    Object.assign(this,{messages,status,sources,document,clock,interval,cancel});this.reset();
  }
  reset(negotiation) {
    if(this.timer!==undefined)this.cancel(this.timer);this.timer=undefined;
    Object.assign(this,{negotiation,feed:undefined,active:false,revision:0,sequence:0,observed:0,dropped:0,lastState:0,closedFeeds:[],history:[],rateStart:0,incoming:0});
    this.messages.replaceChildren();this.sources.textContent='';
    this.status.textContent='Public chat is not shared by the host.';this.status.dataset.active='false';
  }
  clear() { this.history.length=0;this.messages.replaceChildren(); }
  stopTimer() { if(this.timer!==undefined)this.cancel(this.timer);this.timer=undefined; }
  remember(feed) { if(!this.closedFeeds.includes(feed)){this.closedFeeds.push(feed);if(this.closedFeeds.length>8)this.closedFeeds.shift();} }
  expire() {
    if(this.active && this.clock()-this.lastState>6500) {
      this.active=false;this.sequence=Math.max(this.sequence,this.observed);this.clear();
      this.stopTimer();
      this.status.textContent='Public chat is stale or unavailable. Waiting for a fresh host state.';this.status.dataset.active='false';this.sources.textContent='';
    }
  }
  describe() {
    this.status.textContent=`Public chat shared. New messages only. ${this.dropped ? `${this.dropped} messages omitted by format, rate or connection limits.` : 'No omitted messages reported.'}`;
    this.status.dataset.active='true';
  }
  receive(value) {
    if(typeof value?.type!=='string' || !value.type.startsWith('public-chat-'))return false;
    // Timers can pause in background tabs. Admission must check freshness too;
    // only a fresh host state can resume a stale feed.
    this.expire();
    if(!this.negotiation || value.negotiation!==this.negotiation || !uuid(value.feed) || !uint(value.reset) || !uint(value.seq) || !uint(value.dropped))return true;
    try { if(bytes(JSON.stringify(value))>1024)return true; } catch { return true; }
    const now=this.clock();if(now-this.rateStart>=1000){this.rateStart=now;this.incoming=0;}
    if(!(value.type==='public-chat-state' && value.enabled===false) && this.incoming++>=8)return true;
    if(value.type==='public-chat-state') {
      if(Object.keys(value).length!==10 || typeof value.enabled!=='boolean' || typeof value.sourcesTruncated!=='boolean' || !Array.isArray(value.sources) || value.sources.length>4 ||
        !value.adapters || Array.isArray(value.adapters) || typeof value.adapters!=='object' || Object.keys(value.adapters).some(key=>!adapters.includes(key)) || Object.values(value.adapters).some(state=>!states.includes(state)) ||
        value.sources.some(source=>!source || Object.keys(source).length!==3 || !/^[0-9a-f]{12}$/.test(source.id??'') || bytes(source.platform)>32 || bytes(source.state)>64))return true;
      if(!value.enabled) {
        this.remember(value.feed);
        if(this.feed===value.feed || this.feed===undefined){this.active=false;this.clear();this.stopTimer();this.sources.textContent='';this.status.textContent='The host stopped sharing public chat.';this.status.dataset.active='false';}
        return true;
      }
      if(this.closedFeeds.includes(value.feed) || this.feed===value.feed && value.reset<this.revision)return true;
      const resuming=!this.active;
      if(this.feed!==value.feed){if(this.feed)this.remember(this.feed);this.clear();this.feed=value.feed;this.revision=value.reset;this.sequence=0;this.observed=0;}
      if(value.reset>this.revision){this.clear();this.revision=value.reset;}
      if(resuming)this.sequence=Math.max(this.sequence,value.seq);
      this.active=true;this.lastState=now;this.observed=Math.max(this.observed,value.seq);this.dropped=value.dropped;this.describe();
      const summary=Object.entries(value.adapters).map(([name,state])=>`${name}: ${state}`);
      summary.push(...value.sources.map(source=>`${source.platform} destination ${source.id}: ${source.state}`));
      if(value.sourcesTruncated)summary.push('Additional destination status details omitted.');
      this.sources.textContent=summary.join(' · ');
      this.timer??=this.interval(()=>this.expire(),500);return true;
    }
    if(value.type!=='public-chat-message' || Object.keys(value).length!==16 || !this.active || this.feed!==value.feed || value.reset<this.revision || value.seq<=this.sequence ||
      bytes(value.id)>128 || !/^[a-zA-Z0-9-]+$/.test(value.id??'') || !/^[0-9a-f]{12}$/.test(value.source??'') || bytes(value.platform)>32 || bytes(value.author)>64 || bytes(value.text)>512 ||
      !Array.isArray(value.roles) || value.roles.length>6 || value.roles.some(role=>!roles.includes(role)) || !kinds.includes(value.kind) ||
      !Number.isFinite(value.timestamp) || value.timestamp<=0 || value.timestamp>=253402300800 || typeof value.receiptTime!=='boolean' || typeof value.truncated!=='boolean')return true;
    if(value.reset>this.revision){this.clear();this.revision=value.reset;}
    this.sequence=value.seq;this.observed=Math.max(this.observed,value.seq);this.dropped=value.dropped;this.describe();
    if(this.history.includes(value.id))return true;
    if(this.history.length>=32){this.history.shift();this.messages.firstElementChild?.remove();}
    const row=this.document.createElement('article'),header=this.document.createElement('strong'),body=this.document.createElement('p'),metadata=this.document.createElement('small');
    row.dataset.id=value.id;row.dataset.sequence=String(value.seq);row.dataset.truncated=String(value.truncated);
    header.textContent=`${value.author} · ${value.platform}`;body.textContent=value.text;
    metadata.textContent=`${value.kind} · ${value.roles.join(', ')} · ${new Date(value.timestamp*1000).toLocaleTimeString()}${value.receiptTime?' (received time)':''}${value.truncated?' · Text or metadata clipped to the guest feed limit.':''}`;
    row.append(header,body,metadata);this.messages.append(row);this.history.push(value.id);return true;
  }
}
