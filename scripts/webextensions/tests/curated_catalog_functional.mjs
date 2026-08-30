#!/usr/bin/env node
// Copyright (c) Floorp Contributors.
// SPDX-License-Identifier: MPL-2.0

// Functional smoke tests for every curated artifact. These deliberately use a
// tiny in-process DOM rather than a browser or a fetched page: each package is
// decoded from its fixed FWEA1 bytes and matched against catalog-input.json
// before execution. The tests prove local behavior without granting a network
// API or substituting the review source tree for the shipped artifact.

import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const catalogRoot = process.argv[2] || path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../firefox-ios/Floorp/WebExtensions/CuratedCatalog"
);
const artifactRoot = path.join(catalogRoot, "Artifacts");
const fwea1Magic = Buffer.from("FWEA1\n", "ascii");
const artifacts = new Map();

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

async function catalogRecords() {
  const records = JSON.parse(await readFile(path.join(catalogRoot, "catalog-input.json"), "utf8"));
  assert.ok(Array.isArray(records), "catalog input must be an array");
  assert.equal(records.length, 1, "the curated candidate has one record");
  return records;
}

function artifactName(record) {
  let artifactURL;
  try {
    artifactURL = new URL(record.artifactURL);
  } catch {
    assert.fail(`invalid artifact URL for ${record.extensionID}`);
  }
  return path.basename(artifactURL.pathname);
}

function decodeArtifact(data, record, filename) {
  assert.ok(data.subarray(0, fwea1Magic.length).equals(fwea1Magic), `${filename} must be FWEA1`);
  assert.ok(data.length >= fwea1Magic.length + 4, `${filename} is truncated before its inventory`);
  const headerSize = data.readUInt32BE(fwea1Magic.length);
  const headerStart = fwea1Magic.length + 4;
  const headerEnd = headerStart + headerSize;
  assert.ok(headerEnd <= data.length, `${filename} inventory exceeds artifact length`);
  const headerData = data.subarray(headerStart, headerEnd);
  const header = JSON.parse(headerData.toString("utf8"));
  assert.ok(Array.isArray(header.files) && header.files.length > 0, `${filename} has no resources`);
  assert.equal(sha256(headerData), record.resourceInventorySHA256, `${filename} inventory digest`);

  let offset = headerEnd;
  const resources = new Map();
  for (const entry of header.files) {
    assert.equal(typeof entry.path, "string", `${filename} inventory path`);
    assert.ok(Number.isSafeInteger(entry.size) && entry.size >= 0, `${filename} inventory size`);
    assert.match(entry.sha256, /^[0-9a-f]{64}$/, `${filename} inventory digest syntax`);
    assert.ok(!resources.has(entry.path), `${filename} has duplicate resource ${entry.path}`);
    const end = offset + entry.size;
    assert.ok(end <= data.length, `${filename} resource ${entry.path} exceeds artifact length`);
    const resource = data.subarray(offset, end);
    assert.equal(sha256(resource), entry.sha256, `${filename} resource digest for ${entry.path}`);
    resources.set(entry.path, resource);
    offset = end;
  }
  assert.equal(offset, data.length, `${filename} has trailing bytes`);

  const manifest = resources.get("manifest.json");
  assert.ok(manifest, `${filename} is missing manifest.json`);
  assert.equal(sha256(manifest), record.manifestSHA256, `${filename} manifest digest`);
  return resources;
}

async function artifactResources(packageID) {
  if (artifacts.has(packageID)) return artifacts.get(packageID);

  const records = await catalogRecords();
  const filename = `${packageID}.fwea1`;
  const record = records.find(candidate => artifactName(candidate) === filename);
  assert.ok(record, `${filename} must be registered in catalog-input.json`);
  const data = await readFile(path.join(artifactRoot, filename));
  assert.equal(data.length, record.artifactBytes, `${filename} byte count`);
  assert.equal(sha256(data), record.artifactSHA256, `${filename} artifact digest`);
  const resources = decodeArtifact(data, record, filename);
  artifacts.set(packageID, resources);
  return resources;
}

class ClassList {
  constructor() { this.values = new Set(); }
  add(...values) { values.forEach(value => this.values.add(value)); }
  remove(...values) { values.forEach(value => this.values.delete(value)); }
  contains(value) { return this.values.has(value); }
  toggle(value, force) {
    const shouldAdd = force === undefined ? !this.values.has(value) : Boolean(force);
    if (shouldAdd) this.values.add(value); else this.values.delete(value);
    return shouldAdd;
  }
}

class FakeElement {
  constructor(tagName = "div", document = null) {
    this.tagName = tagName.toUpperCase();
    this.ownerDocument = document;
    this.attributes = new Map();
    this.dataset = {};
    this.classList = new ClassList();
    this.children = [];
    this.eventListeners = new Map();
    this.textContent = "";
    this.href = "";
    this.id = "";
    this.className = "";
    this.type = "";
    this.placeholder = "";
    this.hidden = false;
    this.value = "";
    this.checked = false;
    this.parentElement = null;
    this.offsetParent = {};
    this.focused = false;
    this.blurred = false;
    this.selectorMap = new Map();
  }

  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  hasAttribute(name) { return this.attributes.has(name); }
  append(...nodes) {
    for (const node of nodes) {
      if (node instanceof FakeElement) node.parentElement = this;
      this.children.push(node);
    }
  }
  prepend(...nodes) {
    for (const node of nodes.reverse()) {
      if (node instanceof FakeElement) node.parentElement = this;
      this.children.unshift(node);
    }
  }
  addEventListener(type, callback) {
    const callbacks = this.eventListeners.get(type) ?? [];
    callbacks.push(callback);
    this.eventListeners.set(type, callbacks);
  }
  async dispatch(type, event = {}) {
    const callbacks = this.eventListeners.get(type) ?? [];
    for (const callback of callbacks) await callback({
      target: this,
      preventDefault() { this.defaultPrevented = true; },
      ...event
    });
  }
  querySelector(selector) { return this.selectorMap.get(selector)?.[0] ?? null; }
  querySelectorAll(selector) { return this.selectorMap.get(selector) ?? []; }
  focus() {
    this.focused = true;
    if (this.ownerDocument) this.ownerDocument.activeElement = this;
  }
  blur() { this.blurred = true; }
}

class FakeInput extends FakeElement {
  constructor(document) { super("input", document); }
}

class FakeTextarea extends FakeElement {
  constructor(document) { super("textarea", document); }
}

class FakeDocument {
  constructor() {
    this.selectorMap = new Map();
    this.documentElement = new FakeElement("html", this);
    this.body = new FakeElement("body", this);
    this.eventListeners = new Map();
    this.activeElement = null;
  }
  set(selector, nodes) { this.selectorMap.set(selector, Array.isArray(nodes) ? nodes : [nodes]); }
  querySelector(selector) { return this.selectorMap.get(selector)?.[0] ?? null; }
  querySelectorAll(selector) { return this.selectorMap.get(selector) ?? []; }
  createElement(tagName) {
    return tagName === "input" ? new FakeInput(this) : new FakeElement(tagName, this);
  }
  addEventListener(type, callback) {
    const callbacks = this.eventListeners.get(type) ?? [];
    callbacks.push(callback);
    this.eventListeners.set(type, callbacks);
  }
  async dispatch(type, event = {}) {
    const callbacks = this.eventListeners.get(type) ?? [];
    for (const callback of callbacks) await callback({
      preventDefault() { this.defaultPrevented = true; },
      ...event
    });
  }
}

function element(document, tagName = "div") {
  return tagName === "input" ? new FakeInput(document) : new FakeElement(tagName, document);
}

function sandbox(document, overrides = {}) {
  const globalListeners = new Map();
  class MutationObserver {
    constructor(callback) { this.callback = callback; }
    observe() { /* The package calls its initial synchronisation explicitly. */ }
  }
  const context = {
    document,
    Element: FakeElement,
    HTMLInputElement: FakeInput,
    HTMLTextAreaElement: FakeTextarea,
    Node: { ELEMENT_NODE: 1 },
    MutationObserver,
    URL,
    console,
    setTimeout,
    addEventListener(type, callback) {
      const callbacks = globalListeners.get(type) ?? [];
      callbacks.push(callback);
      globalListeners.set(type, callbacks);
    },
    __dispatchGlobal: async (type, event = {}) => {
      for (const callback of globalListeners.get(type) ?? []) await callback(event);
    },
    ...overrides
  };
  context.globalThis = context;
  return context;
}

async function source(packageID, relativePath) {
  const resource = (await artifactResources(packageID)).get(relativePath);
  assert.ok(resource, `${packageID} is missing ${relativePath} in its immutable artifact`);
  return resource.toString("utf8");
}

async function run(packageID, relativePath, context) {
  vm.runInNewContext(await source(packageID, relativePath), context, {
    filename: `${packageID}/${relativePath}`,
    timeout: 1_000
  });
}

async function testDarkReader() {
  const resources = await artifactResources("thirdparty-darkreader");
  const manifest = JSON.parse((await source("thirdparty-darkreader", "manifest.json")));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.background.service_worker, "background/index.js");
  assert.deepEqual(manifest.permissions, ["alarms", "fontSettings", "scripting", "storage"]);
  assert.deepEqual(manifest.host_permissions, ["*://*/*"]);
  assert.equal(manifest.optional_permissions, undefined);
  assert.equal(manifest.commands, undefined);

  const document = new FakeDocument();
  await run("thirdparty-darkreader", "inject/fallback.js", sandbox(document, {
    HTMLHtmlElement: FakeElement,
    matchMedia: () => ({matches: true}),
    sessionStorage: {getItem: () => null}
  }));
  const fallback = document.documentElement.children.find(child =>
    child.classList.contains("darkreader--fallback")
  );
  assert.ok(fallback, "Dark Reader installs its initial dark fallback");
  assert.match(fallback.textContent, /background-color: #181a1b/);

  const background = await source("thirdparty-darkreader", "background/index.js");
  assert.match(background, /const NEWS_URL = "data:application\/json,%5B%5D"/);
  assert.match(background, /const CONFIG_URL_BASE = "\.\.\/config"/);
  for (const config of [
    "color-schemes.drconf",
    "dark-sites.config",
    "detector-hints.config",
    "dynamic-theme-fixes.config",
    "inversion-fixes.config",
    "static-themes.config"
  ]) {
    assert.ok(resources.has(`config/${config}`), `Dark Reader has local ${config}`);
  }

  // Boot the shipped service worker with the supported Chrome-compatible API
  // surface. This catches an unconditional use of an unavailable namespace
  // before a user installs the curated artifact; it intentionally omits
  // optional context menus, commands, windows, and remote network access.
  const stores = {local: {}, sync: {}};
  const makeEvent = () => ({addListener() {}, removeListener() {}});
  const storageArea = name => ({
    QUOTA_BYTES_PER_ITEM: 8 * 1024,
    get(keys, callback) {
      const values = stores[name];
      let result;
      if (keys == null) result = {...values};
      else if (Array.isArray(keys)) {
        result = Object.fromEntries(keys.filter(key => key in values).map(key => [key, values[key]]));
      } else if (typeof keys === "string") {
        result = keys in values ? {[keys]: values[key]} : {};
      } else {
        result = Object.fromEntries(Object.entries(keys).map(([key, fallback]) => [
          key,
          key in values ? values[key] : fallback
        ]));
      }
      callback?.(result);
    },
    set(values, callback) { Object.assign(stores[name], values); callback?.(); },
    remove(keys, callback) {
      for (const key of Array.isArray(keys) ? keys : [keys]) delete stores[name][key];
      callback?.();
    },
    onChanged: makeEvent()
  });
  const fetched = [];
  const backgroundContext = {
    URL,
    URLSearchParams,
    TextEncoder,
    TextDecoder,
    crypto: webcrypto,
    console: {log() {}, warn() {}, error() {}},
    setInterval() { return 1; },
    clearInterval() {},
    setTimeout,
    clearTimeout,
    performance: {now: () => Date.now()},
    navigator: {language: "en-US", userAgent: "Floorp iOS", platform: "iPhone"},
    location: {
      protocol: "floorp-extension:",
      origin: "floorp-extension://floorp.thirdparty.darkreader"
    },
    fetch: async url => {
      fetched.push(String(url));
      return {ok: true, text: async () => "", json: async () => []};
    },
    chrome: {
      storage: {local: storageArea("local"), sync: storageArea("sync")},
      runtime: {
        id: "floorp.thirdparty.darkreader",
        getPlatformInfo: () => Promise.resolve({os: "ios"}),
        getURL: (resource = "") =>
          `floorp-extension://floorp.thirdparty.darkreader/${String(resource).split("/").filter(Boolean).join("/")}`,
        getManifest: () => ({version: "4.9.129"}),
        setUninstallURL() {},
        onStartup: makeEvent(),
        onInstalled: makeEvent(),
        onMessage: makeEvent(),
        sendMessage() {}
      },
      permissions: {contains(_details, callback) { callback(false); }},
      alarms: {onAlarm: makeEvent(), create() {}, clear() {}},
      action: {setIcon() {}, setBadgeBackgroundColor() {}, setBadgeText() {}},
      tabs: {
        onRemoved: makeEvent(),
        query(_query, callback) { callback([]); },
        get() {}, sendMessage() {}, create() {}, update() {}
      },
      scripting: {executeScript() {}},
      i18n: {getMessage: () => "", getUILanguage: () => "en"},
      extension: {isAllowedFileSchemeAccess(callback) { callback(false); }}
    }
  };
  backgroundContext.globalThis = backgroundContext;
  const backgroundFailures = [];
  const captureRejection = reason => backgroundFailures.push(reason);
  process.on("unhandledRejection", captureRejection);
  try {
    await run("thirdparty-darkreader", "background/index.js", backgroundContext);
    await new Promise(resolve => setTimeout(resolve, 30));
  } finally {
    process.removeListener("unhandledRejection", captureRejection);
  }
  assert.deepEqual(backgroundFailures, [], "Dark Reader service worker starts with supported MV3 APIs");
  assert.ok(Object.keys(stores.local).length > 0, "Dark Reader initializes device-local settings");
  assert.ok(Object.keys(stores.sync).length > 0, "Dark Reader initializes device-local sync compatibility settings");
  assert.ok(
    fetched.every(url => url.startsWith("../config/") || url.startsWith("data:")),
    "Dark Reader service worker fetches only bundled configuration or local data URLs"
  );
}

await testDarkReader();

assert.equal(artifacts.size, 1, "every catalog artifact must execute one functional smoke path");
process.stdout.write(JSON.stringify({ status: "ok", adoptedArtifacts: 1 }) + "\n");
