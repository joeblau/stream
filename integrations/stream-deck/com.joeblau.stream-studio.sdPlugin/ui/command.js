/* Pairing values only cross sendToPlugin, never setSettings/localStorage/logging. */
let socket, context, actionUUID;
let commands = [], settings = {}, currentProject = "", signature = "";
const element = id => document.getElementById(id);
function send(payload) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ event: "sendToPlugin", context, action: actionUUID, payload }));
}
function updateOptions() {
  const selected = settings.commandID ?? "";
  const query = element("search").value.toLowerCase(), category = element("category").value;
  const matching = commands.filter(c => (!category || c.category === category) && `${c.title} ${c.category} ${c.id}`.toLowerCase().includes(query));
  const options = [new Option("Choose a command", "")];
  for (const command of matching) {
    const option = new Option(`${command.title}${command.available ? "" : " — unavailable now"}`, command.id);
    if (command.id.startsWith("unavailable.")) option.disabled = true;
    options.push(option);
  }
  if (selected && !matching.some(c => c.id === selected)) {
    const known = commands.find(c => c.id === selected);
    options.push(new Option(known ? known.title : "Missing resource — binding retained", selected));
  }
  element("command").replaceChildren(...options); element("command").value = selected;
  const command = commands.find(c => c.id === selected);
  element("availability").textContent = command?.unavailableReason ?? (selected ? "Available" : "Choose a command to bind this key.");
  element("project").textContent = settings.projectID && settings.projectID !== currentProject ? "This key belongs to a different project. Select a command to rebind explicitly." : `Project: ${currentProject || "not connected"}`;
}
function update(payload) {
  if (payload.error) { element("error").textContent = payload.error; return; }
  element("error").textContent = "";
  element("status").textContent = payload.status ?? "Disconnected";
  currentProject = payload.projectID ?? ""; settings = payload.settings ?? settings;
  const nextCommands = payload.commands ?? [];
  const nextSignature = JSON.stringify(nextCommands);
  commands = nextCommands;
  if (nextSignature !== signature) {
    signature = nextSignature;
    const category = element("category").value;
    element("category").replaceChildren(new Option("All categories", ""), ...[...new Set(commands.map(c => c.category))].sort().map(c => new Option(c, c)));
    element("category").value = category;
  }
  updateOptions();
}
window.connectElgatoStreamDeckSocket = (port, uuid, registerEvent, _info, actionInfo) => {
  context = uuid; const info = JSON.parse(actionInfo); actionUUID = info.action; settings = info.payload.settings ?? {};
  socket = new WebSocket(`ws://127.0.0.1:${port}`);
  socket.onopen = () => { socket.send(JSON.stringify({ event: registerEvent, uuid })); send({ operation: "refresh" }); };
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.event === "sendToPropertyInspector") update(message.payload);
    if (message.event === "didReceiveSettings") { settings = message.payload.settings ?? {}; updateOptions(); }
  };
  socket.onclose = () => { element("status").textContent = "Stream Deck disconnected"; };
};
element("pair").onclick = () => {
  try { const credentials = JSON.parse(element("credentials").value); element("credentials").value = ""; send({ operation: "pair", credentials }); }
  catch { element("error").textContent = "Paste the pairing JSON from Stream Studio."; }
};
element("forget").onclick = () => send({ operation: "forget" });
element("refresh").onclick = () => send({ operation: "refresh" });
element("search").oninput = updateOptions; element("category").onchange = updateOptions;
element("command").onchange = () => { const commandID = element("command").value; if (commandID) send({ operation: "bind", commandID }); };
