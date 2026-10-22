/* Pairing values only cross sendToPlugin, never setSettings/localStorage/logging. */
let socket, context, actionUUID;
let commands = [], settings = {}, currentProject = "", signature = "";
let mode = "key", currentStatus = "Disconnected", settingsSignature;
let draftCommandID, draftSourceID;
const element = id => document.getElementById(id);
function send(payload) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ event: "sendToPlugin", context, action: actionUUID, payload }));
}
function resourceType(command) {
  const declared = command.target?.kind;
  if (["scene", "source", "overlay", "guest", "destination", "profile"].includes(declared)) return declared;
  const id = command.id;
  if (/^(?:destination)\./.test(id)) return "destination";
  if (/^(?:guest|guestSlot|guestslot)\.|^interview\.(?:guest|slot)\./i.test(id)) return "guest";
  if (/^(?:profile|showProfile|project)\.|^show\.[^.]+\.profile\./i.test(id)) return "profile";
  if (/^overlay\./.test(id)) return "overlay";
  if (/^source\.|^scene\.[^.]+\.layer\.|^audio\.(?:input|source)\./.test(id)) return "source";
  if (/^scene\./.test(id)) return "scene";
  return "";
}
function sourceOptions(command) {
  if (command?.argument !== "source" || !["camera", "screen"].includes(command.sourceKind)) return [];
  return commands.flatMap(candidate => {
    const match = /^source\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.effects\.bypass$/i.exec(candidate.id);
    return match && candidate.sourceKind === command.sourceKind ? [{ id: match[1], name: candidate.title.replace(/^.*? — /, ""), available: candidate.sourceAvailable !== false }] : [];
  });
}
function updateOptions() {
  const selected = draftCommandID ?? settings.commandID ?? "";
  const query = element("search").value.toLowerCase(), category = element("category").value, resource = element("resource-type").value;
  const matching = commands.filter(c => (!category || c.category === category) && (!resource || resourceType(c) === resource)
    && `${c.title} ${c.category} ${c.id}`.toLowerCase().includes(query));
  const options = [new Option("Choose a command", "")];
  for (const command of matching) {
    const option = new Option(`${command.title}${command.available ? "" : " — unavailable now"}`, command.id);
    if (command.id.startsWith("unavailable.")) option.disabled = true;
    options.push(option);
  }
  if (selected && !matching.some(c => c.id === selected)) {
    const known = commands.find(c => c.id === selected);
    const retained = new Option(known ? known.title : "Missing resource — binding retained", selected);
    retained.disabled = !known || known.id.startsWith("unavailable.");
    options.push(retained);
  }
  element("command").replaceChildren(...options); element("command").value = selected;
  element("command").disabled = currentStatus !== "Connected" || !currentProject;
  const command = commands.find(c => c.id === selected);
  element("value-options").hidden = mode !== "key" || command?.kind !== "value";
  element("page-options").hidden = mode !== "key" || command?.argument !== "page";
  element("marker-options").hidden = mode !== "key" || command?.argument !== "text";
  element("level-options").hidden = mode !== "level";
  element("selector-options").hidden = mode !== "selector";
  element("source-options").hidden = mode !== "key" || command?.argument !== "source";
  const sources = sourceOptions(command);
  const selectedSource = draftSourceID ?? (selected === settings.commandID ? settings.text ?? "" : "");
  const sourceRows = [new Option("Choose a source", ""), ...sources.map(source => {
    const option = new Option(source.name + (source.available ? "" : " — disconnected"), source.id); option.disabled = !source.available; return option;
  })];
  if (selectedSource && !sources.some(source => source.id === selectedSource)) {
    const missing = new Option("Missing or different-kind source — binding retained", selectedSource); missing.disabled = true; sourceRows.push(missing);
  }
  element("source").replaceChildren(...sourceRows); element("source").value = selectedSource;
  element("confirmation").hidden = command?.requiresConfirmation !== true;
  // Only a fresh descriptor can widen display scope; settings never carry authority.
  const studioScoped = currentStatus === "Connected" && command?.scope === "studio";
  const differentProject = settings.projectID && settings.projectID !== currentProject && !studioScoped;
  element("binding").textContent = settings.commandID ? `Binding: ${settings.commandID}` : "No resource is bound.";
  element("availability").textContent = currentStatus !== "Connected" ? "Connect to Stream Studio to check the bound resource."
    : differentProject ? "This binding cannot run in the current project."
    : selected && !command ? "Missing resource — select another resource to rebind explicitly."
    : command?.argument === "source" && !sources.some(source => source.id === selectedSource) ? selectedSource
      ? "Missing or different-kind source — select another configured source to rebind explicitly."
      : "Choose a configured source, then apply the source binding."
    : command?.argument === "source" && sources.some(source => source.id === selectedSource && !source.available)
      ? "Source disconnected — reconnect the device or explicitly choose another configured source."
    : command?.unavailableReason ?? (command ? command.kind === "feedback" ? "Display only — pressing refreshes authoritative studio state." : command.available ? "Available" : "Unavailable now" : "Choose a command to bind this control.");
  element("project").textContent = studioScoped ? "Current show’s saved profiles — available across profiles in this show."
    : differentProject ? "This key belongs to a different project. Select a command to rebind explicitly." : `Project: ${currentProject || "not connected"}`;
  for (const id of ["apply-value", "apply-step", "apply-page", "apply-marker", "apply-source"]) {
    element(id).disabled = currentStatus !== "Connected" || !currentProject || !command || command.id.startsWith("unavailable.");
  }
}
function hydrateSettings() {
  const nextSignature = JSON.stringify(settings);
  if (nextSignature === settingsSignature) return;
  settingsSignature = nextSignature;
  draftCommandID = undefined; draftSourceID = undefined;
  element("error").textContent = "";
  element("value").value = String((settings.value ?? 0.5) * 200);
  element("step").value = String((settings.step ?? 0.01) * 200);
  element("page").value = String((settings.page ?? 0) + 1);
  element("marker").value = settings.text ?? "";
  element("selector-category").value = settings.category ?? "Scenes";
}
function update(payload) {
  if (payload.error) { element("error").textContent = payload.error; return; }
  currentStatus = payload.status ?? "Disconnected";
  element("status").textContent = currentStatus;
  currentProject = payload.projectID ?? ""; settings = payload.settings ?? settings; mode = payload.mode ?? mode;
  // Live snapshots can arrive while an operator types a page or marker.
  // Only acknowledged binding changes replace those in-progress edits.
  hydrateSettings();
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
  socket?.close();
  const connection = new WebSocket(`ws://127.0.0.1:${port}`); socket = connection;
  commands = []; signature = ""; currentProject = ""; settingsSignature = undefined;
  mode = actionUUID.endsWith(".level") ? "level" : actionUUID.endsWith(".selector") ? "selector" : "key";
  currentStatus = "Connecting to Stream Deck…"; element("status").textContent = currentStatus;
  hydrateSettings(); updateOptions();
  connection.onopen = () => {
    if (socket !== connection) return;
    connection.send(JSON.stringify({ event: registerEvent, uuid })); send({ operation: "refresh" });
  };
  connection.onmessage = event => {
    if (socket !== connection) return;
    let message;
    try { message = JSON.parse(event.data); } catch { element("error").textContent = "Stream Deck sent an unreadable update. Refresh the studio catalog."; return; }
    if (message.context !== undefined && message.context !== context) return;
    if (message.event === "sendToPropertyInspector" && message.payload) update(message.payload);
    if (message.event === "didReceiveSettings" && message.payload) { settings = message.payload.settings ?? {}; hydrateSettings(); updateOptions(); }
  };
  connection.onclose = () => {
    if (socket !== connection) return;
    currentStatus = "Stream Deck disconnected"; element("status").textContent = currentStatus; updateOptions();
  };
};
element("pair").onclick = () => {
  try { const credentials = JSON.parse(element("credentials").value); element("credentials").value = ""; send({ operation: "pair", credentials }); }
  catch { element("error").textContent = "Paste the pairing JSON from Stream Studio."; }
};
element("forget").onclick = () => send({ operation: "forget" });
element("refresh").onclick = () => send({ operation: "refresh" });
element("search").oninput = updateOptions; element("category").onchange = updateOptions; element("resource-type").onchange = updateOptions;
function bindSelected() {
  if (currentStatus !== "Connected" || !currentProject) {
    element("error").textContent = "Connect to Stream Studio before changing this binding.";
    return;
  }
  const commandID = element("command").value;
  if (!commandID) return;
  const command = commands.find(c => c.id === commandID);
  if (!command || command.id.startsWith("unavailable.")) {
    element("error").textContent = "Choose a supported resource from the current studio catalog.";
    return;
  }
  const value = Number(element("value").value), step = Number(element("step").value), page = Number(element("page").value);
  const marker = element("marker").value;
  const source = element("source").value;
  if (mode === "key" && command.argument === "source" && !sourceOptions(command).some(candidate => candidate.id === source && candidate.available)) {
    element("error").textContent = "Choose a configured source of the required kind before applying this binding."; return;
  }
  if (mode === "level" && (!element("step").value.trim() || !Number.isFinite(step) || step < 0.2 || step > 50)) {
    element("error").textContent = "Dial step needs a number from 0.2 to 50 percent per tick."; return;
  }
  if (mode === "key" && command.kind === "value" && (!element("value").value.trim() || !Number.isFinite(value) || value < 0 || value > 200)) {
    element("error").textContent = "Gain needs a number from 0 to 200 percent."; return;
  }
  if (mode === "key" && command.argument === "page" && (!element("page").value.trim() || !Number.isSafeInteger(page) || page < 1 || page > 100001)) {
    element("error").textContent = "PDF page needs a whole number from 1 to 100001."; return;
  }
  if (mode === "key" && command.argument === "text" && marker && (!marker.trim() || new TextEncoder().encode(marker).length > 512)) {
    element("error").textContent = "Marker text needs 1–512 UTF-8 bytes, or leave it empty."; return;
  }
  element("error").textContent = "";
  send({ operation: "bind", commandID,
    ...(mode === "level" ? { step: Number(element("step").value) / 200 } : {}),
    ...(mode === "selector" ? { category: element("selector-category").value } : {}),
    ...(mode === "key" && command?.kind === "value" ? { value: Number(element("value").value) / 200 } : {}),
    ...(mode === "key" && command?.argument === "page" ? { page: Number(element("page").value) - 1 } : {}),
    ...(mode === "key" && command?.argument === "source" ? { text: source } : {}),
    ...(mode === "key" && command?.argument === "text" && element("marker").value ? { text: element("marker").value } : {}) });
}
element("command").onchange = () => {
  draftCommandID = element("command").value; draftSourceID = undefined;
  element("error").textContent = "";
  updateOptions();
  if (commands.find(command => command.id === draftCommandID)?.argument !== "source") bindSelected();
};
element("source").onchange = () => { draftSourceID = element("source").value; element("error").textContent = ""; updateOptions(); };
element("apply-source").onclick = bindSelected;
element("apply-value").onclick = bindSelected; element("apply-step").onclick = bindSelected;
element("apply-page").onclick = bindSelected; element("apply-marker").onclick = bindSelected;
element("selector-category").onchange = () => send({ operation: "selector-category", category: element("selector-category").value });
