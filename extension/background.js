"use strict";

const NATIVE_APPLICATION_ID = "application.id";
const MAX_MESSAGE_AGE_MS = 2000;
const seenIds = new Map();
let nativePort = null;
let reconnectTimer = null;
let nativeConnected = false;

function log(...args) {
  console.log("[SafariGestureNav]", ...args);
}

function pruneSeen(now) {
  for (const [id, seenAt] of seenIds) {
    if (now - seenAt > MAX_MESSAGE_AGE_MS * 2) {
      seenIds.delete(id);
    }
  }
}

function extractPayload(message) {
  if (!message || typeof message !== "object") {
    return null;
  }
  if (message.userInfo && typeof message.userInfo === "object") {
    return message.userInfo;
  }
  if (message.message && typeof message.message === "object") {
    return message.message;
  }
  return message;
}

function isExpired(payload, now) {
  const timestamp = Number(payload.timestamp);
  if (!Number.isFinite(timestamp)) {
    return true;
  }
  return Math.abs(now - timestamp) > MAX_MESSAGE_AGE_MS;
}

function rememberId(id, now) {
  pruneSeen(now);
  if (seenIds.has(id)) {
    return false;
  }
  seenIds.set(id, now);
  return true;
}

async function focusedTab() {
  const windows = await browser.windows.getAll({ populate: true, windowTypes: ["normal"] });
  const focused = windows.find((item) => item.focused) || windows[0];
  if (!focused || !Array.isArray(focused.tabs)) {
    throw new Error("no focused Safari window");
  }
  const active = focused.tabs.find((tab) => tab.active);
  if (!active || typeof active.id !== "number") {
    throw new Error("no active tab");
  }
  return active;
}

async function navigate(action, tab) {
  if (action === "back") {
    if (typeof browser.tabs.goBack !== "function") {
      throw new Error("browser.tabs.goBack is not available");
    }
    await browser.tabs.goBack(tab.id);
    return;
  }
  if (action === "forward") {
    if (typeof browser.tabs.goForward !== "function") {
      throw new Error("browser.tabs.goForward is not available");
    }
    await browser.tabs.goForward(tab.id);
    return;
  }
  throw new Error(`unsupported action: ${action}`);
}

async function handleNavigatePayload(payload, source) {
  const now = Date.now();
  const action = payload && payload.action;
  const id = payload && String(payload.id || "");

  if (action !== "back" && action !== "forward") {
    log("ignore", source, "unsupported action");
    return { ok: false, reason: "unsupported-action" };
  }
  if (payload.execute === false) {
    log("ignore", source, "native owns navigation", id);
    return { ok: true, reason: "native-owns-navigation" };
  }
  if (!id) {
    log("ignore", source, "missing id");
    return { ok: false, reason: "missing-id" };
  }
  if (isExpired(payload, now)) {
    log("ignore", source, "expired", id);
    return { ok: false, reason: "expired" };
  }
  if (!rememberId(id, now)) {
    log("ignore", source, "duplicate", id);
    return { ok: false, reason: "duplicate" };
  }

  try {
    const tab = await focusedTab();
    await navigate(action, tab);
    log(action, "ok", "tab", tab.id, "via", source);
    return { ok: true, action, tabId: tab.id };
  } catch (error) {
    log(action, "failed", String(error), "via", source);
    return { ok: false, reason: String(error) };
  }
}

function scheduleReconnect() {
  if (reconnectTimer) {
    return;
  }
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNative();
  }, 1000);
}

function connectNative() {
  if (!browser.runtime.connectNative) {
    log("connectNative is not available");
    nativeConnected = false;
    return;
  }
  try {
    nativePort = browser.runtime.connectNative(NATIVE_APPLICATION_ID);
  } catch (error) {
    nativeConnected = false;
    log("connectNative threw", String(error));
    scheduleReconnect();
    return;
  }

  nativeConnected = true;
  nativePort.onMessage.addListener((message) => {
    const payload = extractPayload(message);
    handleNavigatePayload(payload, "port").catch((error) => {
      log("port handler failed", String(error));
    });
  });
  nativePort.onDisconnect.addListener(() => {
    nativeConnected = false;
    nativePort = null;
    const err = browser.runtime.lastError && browser.runtime.lastError.message;
    log("native port disconnected", err || "");
    scheduleReconnect();
  });
}

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const payload = extractPayload(message);
  handleNavigatePayload(payload, sender && sender.id ? `onMessage:${sender.id}` : "onMessage")
    .then((result) => sendResponse(result))
    .catch((error) => sendResponse({ ok: false, reason: String(error) }));
  return true;
});

if (browser.runtime.onMessageExternal) {
  browser.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
    const payload = extractPayload(message);
    handleNavigatePayload(payload, "onMessageExternal")
      .then((result) => sendResponse(result))
      .catch((error) => sendResponse({ ok: false, reason: String(error) }));
    return true;
  });
}

connectNative();
log("background ready", {
  goBack: typeof browser.tabs.goBack === "function",
  goForward: typeof browser.tabs.goForward === "function",
  connectNative: typeof browser.runtime.connectNative === "function"
});
