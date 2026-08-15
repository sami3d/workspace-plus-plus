const HOST = "com.saint.workspaceplusplus.chrome";
let port;
let captureTimer;

function connect() {
  if (port) return port;
  try {
    port = chrome.runtime.connectNative(HOST);
    port.onMessage.addListener(handleNativeMessage);
    port.onDisconnect.addListener(() => { port = undefined; });
  } catch (_) {
    port = undefined;
  }
  return port;
}

async function capture() {
  const windows = await chrome.windows.getAll({ populate: true, windowTypes: ["normal"] });
  const groups = await chrome.tabGroups.query({});
  const groupsByID = new Map(groups.map(group => [group.id, group]));
  const payload = {
    version: 1,
    capturedAt: new Date().toISOString(),
    windows: windows.map(window => ({
      id: String(window.id),
      title: window.tabs?.find(tab => tab.active)?.title || "",
      bounds: {
        x: window.left || 0,
        y: window.top || 0,
        width: window.width || 0,
        height: window.height || 0
      },
      mode: window.incognito ? "incognito" : "normal",
      activeTabIndex: (window.tabs?.findIndex(tab => tab.active) ?? 0) + 1,
      tabs: (window.tabs || []).map(tab => {
        const group = groupsByID.get(tab.groupId);
        return {
          id: String(tab.id),
          title: tab.title || "",
          url: tab.url || tab.pendingUrl || "",
          pinned: Boolean(tab.pinned),
          groupKey: group ? String(group.id) : null,
          groupTitle: group?.title || null,
          groupColor: group?.color || null,
          groupCollapsed: group?.collapsed ?? null
        };
      })
    }))
  };
  connect()?.postMessage({ type: "snapshot", payload });
}

function scheduleCapture() {
  clearTimeout(captureTimer);
  captureTimer = setTimeout(() => capture().catch(() => {}), 500);
}

async function restore(payload) {
  const createdWindows = [];
  for (const savedWindow of payload.windows || []) {
    const orderedTabs = [...(savedWindow.tabs || [])].sort((a, b) => a.index - b.index);
    const created = await chrome.windows.create({
      url: orderedTabs.map(tab => tab.url || "chrome://newtab/"),
      left: Math.round(savedWindow.bounds?.x || 0),
      top: Math.round(savedWindow.bounds?.y || 0),
      width: Math.max(300, Math.round(savedWindow.bounds?.width || 1000)),
      height: Math.max(200, Math.round(savedWindow.bounds?.height || 700)),
      focused: false
    });
    const tabs = (await chrome.tabs.query({ windowId: created.id })).sort((a, b) => a.index - b.index);
    for (let index = 0; index < Math.min(tabs.length, orderedTabs.length); index++) {
      await chrome.tabs.update(tabs[index].id, { pinned: Boolean(orderedTabs[index].isPinned) });
    }
    const grouped = new Map();
    for (let index = 0; index < Math.min(tabs.length, orderedTabs.length); index++) {
      const savedTab = orderedTabs[index];
      if (!savedTab.groupTitle && !savedTab.groupKey) continue;
      const key = savedTab.groupKey || `${savedTab.groupTitle}:${savedTab.groupColor}`;
      const ids = grouped.get(key) || [];
      ids.push(tabs[index].id);
      grouped.set(key, ids);
    }
    for (const [key, tabIds] of grouped) {
      const first = orderedTabs.find(tab => (tab.groupKey || `${tab.groupTitle}:${tab.groupColor}`) === key);
      const groupId = await chrome.tabs.group({ tabIds, createProperties: { windowId: created.id } });
      await chrome.tabGroups.update(groupId, {
        title: first?.groupTitle || "",
        color: first?.groupColor || "grey",
        collapsed: Boolean(first?.groupCollapsed)
      });
    }
    const active = Math.max(0, orderedTabs.findIndex(tab => tab.isActive));
    if (tabs[active]) await chrome.tabs.update(tabs[active].id, { active: true });
    createdWindows.push(created.id);
  }
  connect()?.postMessage({ type: "restoreResult", requestId: payload.requestId, ok: true, createdWindows });
  scheduleCapture();
}

function handleNativeMessage(message) {
  if (message?.type === "restore") restore(message).catch(error => {
    connect()?.postMessage({ type: "restoreResult", requestId: message.requestId, ok: false, error: String(error) });
  });
}

for (const event of [
  chrome.tabs.onCreated, chrome.tabs.onUpdated, chrome.tabs.onMoved,
  chrome.tabs.onRemoved, chrome.tabs.onAttached, chrome.tabs.onDetached,
  chrome.windows.onCreated, chrome.windows.onRemoved, chrome.windows.onBoundsChanged,
  chrome.tabGroups.onCreated, chrome.tabGroups.onUpdated, chrome.tabGroups.onMoved,
  chrome.tabGroups.onRemoved
]) event.addListener(scheduleCapture);

chrome.runtime.onStartup.addListener(scheduleCapture);
chrome.runtime.onInstalled.addListener(scheduleCapture);
chrome.action.onClicked.addListener(scheduleCapture);
chrome.alarms.create("workspace-plus-capture", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(scheduleCapture);
connect();
scheduleCapture();
setInterval(() => connect()?.postMessage({ type: "poll" }), 3000);
