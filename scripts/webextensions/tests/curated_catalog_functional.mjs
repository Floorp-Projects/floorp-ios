#!/usr/bin/env node
// Copyright (c) Floorp Contributors.
// SPDX-License-Identifier: MPL-2.0

// Functional smoke tests for every curated package.  These deliberately use a
// tiny in-process DOM rather than a browser or a fetched page: each package is
// executed with only the fixed resources committed to CuratedCatalog/Packages.
// The tests prove its declared local behavior without granting a network API.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const packageRoot = process.argv[2] || path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../firefox-ios/Floorp/WebExtensions/CuratedCatalog/Packages"
);

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
  return readFile(path.join(packageRoot, packageID, relativePath), "utf8");
}

async function run(packageID, relativePath, context) {
  vm.runInNewContext(await source(packageID, relativePath), context, {
    filename: `${packageID}/${relativePath}`,
    timeout: 1_000
  });
}

async function testSiteAppearance() {
  const document = new FakeDocument();
  await run("floorp-site-appearance", "content/appearance.js", sandbox(document));
  assert.equal(document.documentElement.dataset.floorpSiteAppearance, "1");
  assert.equal(document.documentElement.classList.contains("floorp-site-appearance"), true);
}

async function testEasyToRSS() {
  const document = new FakeDocument();
  const feed = element(document, "link");
  feed.href = "https://example.test/feed.xml";
  document.set('link[type="application/rss+xml"], link[type="application/atom+xml"]', [feed]);
  const stored = {};
  const storage = {
    get: async () => ({ ...stored }),
    set: async values => Object.assign(stored, values)
  };
  await run("thirdparty-easy-to-rss", "content/rss.js", sandbox(document, {
    location: { origin: "https://example.test" },
    browser: { storage: { local: storage } }
  }));
  await new Promise(resolve => setImmediate(resolve));
  const notice = document.body.children.find(child => child.id === "floorp-easy-rss");
  assert.ok(notice);
  assert.equal(notice.getAttribute("role"), "status");
  assert.equal(notice.children[0].href, feed.href);
  assert.equal(stored.floorpEasyToRSSLastFeedURL, feed.href);
  assert.equal(stored.floorpEasyToRSSLastPageOrigin, "https://example.test");

  const popupDocument = new FakeDocument();
  const status = element(popupDocument);
  const feedLink = element(popupDocument, "a");
  popupDocument.set("#status", status);
  popupDocument.set("#feed", feedLink);
  await run("thirdparty-easy-to-rss", "popup/popup.js", sandbox(popupDocument, {
    browser: { storage: { local: storage } }
  }));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(status.textContent, "Feed discovered on https://example.test.");
  assert.equal(feedLink.href, feed.href);
  assert.equal(feedLink.hidden, false);
}

async function testEKill() {
  const document = new FakeDocument();
  const target = element(document);
  await run("thirdparty-ekill", "content/ekill.js", sandbox(document));
  await document.dispatch("pointerover", { target });
  assert.equal(target.classList.contains("floorp-ekill-hover"), true);
  await document.dispatch("keydown", { altKey: true, shiftKey: true, key: "k" });
  assert.equal(target.classList.contains("floorp-ekill-hidden"), true);
  await document.dispatch("keydown", { altKey: true, shiftKey: true, key: "u" });
  assert.equal(target.classList.contains("floorp-ekill-hidden"), false);
}

async function testEnhancedGitHub() {
  const document = new FakeDocument();
  const link = element(document, "a");
  link.setAttribute("href", "/owner/repo/blob/main/README.md");
  document.set("a[href*='/blob/'], a[href*='/tree/']", [link]);
  await run("thirdparty-enhanced-github", "content/enhanced.js", sandbox(document));
  assert.equal(document.documentElement.dataset.floorpEnhancedGithub, "1");
  const pathLabel = link.children.find(child => child instanceof FakeElement);
  assert.equal(pathLabel.className, "floorp-github-path");
  assert.equal(pathLabel.textContent, "README.md");
}

async function testGitHubDashboard() {
  const document = new FakeDocument();
  const main = element(document, "main");
  const matching = element(document, "article");
  matching.textContent = "Floorp issue";
  const nonMatching = element(document, "article");
  nonMatching.textContent = "Other issue";
  main.selectorMap.set("article, .Box-row, .dashboard-rollup-item", [matching, nonMatching]);
  document.set("main", main);
  await run("thirdparty-github-dashboard", "content/dashboard.js", sandbox(document));
  const filter = main.children[0];
  filter.value = "floorp";
  await filter.dispatch("input");
  assert.equal(nonMatching.classList.contains("floorp-dashboard-muted"), true);
  assert.equal(matching.classList.contains("floorp-dashboard-muted"), false);
}

async function testMinimalTwitter() {
  const document = new FakeDocument();
  const focus = element(document, "input");
  document.activeElement = focus;
  await run("thirdparty-minimal-twitter", "content/minimal.js", sandbox(document));
  await document.dispatch("keydown", { key: "Escape" });
  assert.equal(document.documentElement.dataset.floorpMinimalTwitter, "1");
  assert.equal(focus.blurred, true);
}

async function testMediumReadingLayout() {
  const document = new FakeDocument();
  const article = element(document, "article");
  document.set("article", [article]);
  await run("thirdparty-mmra", "content/reading.js", sandbox(document));
  assert.equal(document.documentElement.dataset.floorpMediumReadingLayout, "1");
  assert.equal(article.getAttribute("data-floorp-readable"), "true");
}

async function testRefinedHackerNews() {
  const document = new FakeDocument();
  const first = element(document, "a");
  const second = element(document, "a");
  first.textContent = "First story";
  second.textContent = "Second story";
  document.set(".titleline > a", [first, second]);
  await run("thirdparty-refined-hacker-news", "content/refined.js", sandbox(document));
  assert.equal(first.dataset.floorpHnRank, "1");
  assert.equal(second.getAttribute("aria-label"), "2. Second story");
  await document.dispatch("keydown", { key: "j", target: null });
  assert.equal(first.focused, true);
}

async function testRefinedTwitter() {
  const document = new FakeDocument();
  const tweet = element(document);
  document.set('[data-testid="tweet"]', [tweet]);
  await run("thirdparty-refined-twitter", "content/refined.js", sandbox(document));
  assert.equal(tweet.getAttribute("data-floorp-refined"), "true");
}

async function testScrollToTop() {
  const document = new FakeDocument();
  let scrollY = 0;
  let scrollTarget = null;
  const context = sandbox(document, {
    window: { scrollTo: options => { scrollTarget = options; } }
  });
  Object.defineProperty(context.window, "scrollY", { get: () => scrollY });
  await run("thirdparty-scrolltotop", "content/scroll.js", context);
  const button = document.body.children.find(child => child.id === "floorp-scroll-to-top");
  assert.ok(button);
  assert.equal(button.hidden, true);
  scrollY = 400;
  await context.__dispatchGlobal("scroll");
  assert.equal(button.hidden, false);
  await button.dispatch("click");
  assert.equal(scrollTarget.top, 0);
  assert.equal(scrollTarget.behavior, "smooth");
}

async function testUsefulForks() {
  const document = new FakeDocument();
  const container = element(document, "main");
  const heading = element(document, "h1");
  heading.textContent = "Forks";
  heading.parentElement = container;
  const included = element(document, "li");
  included.textContent = "Floorp fork";
  const excluded = element(document, "li");
  excluded.textContent = "Other fork";
  const link = element(document, "a");
  included.selectorMap.set("a[href*='/']", [link]);
  excluded.selectorMap.set("a[href*='/']", [link]);
  document.set("h1, h2", [heading]);
  document.set("li, .Box-row", [included, excluded]);
  await run("thirdparty-useful-forks", "content/forks.js", sandbox(document));
  const filter = container.children[0];
  filter.value = "floorp";
  await filter.dispatch("input");
  assert.equal(excluded.classList.contains("floorp-useful-forks-hidden"), true);
  assert.equal(included.classList.contains("floorp-useful-forks-hidden"), false);
}

async function testTrackingTokenStripper() {
  const document = new FakeDocument();
  const link = element(document, "a");
  link.href = "https://example.test/path?utm_source=test&ok=1";
  document.set("a[href]", [link]);
  let replacement = null;
  const stored = {};
  const storage = {
    get: async () => ({ ...stored }),
    set: async values => Object.assign(stored, values)
  };
  const context = sandbox(document, {
    location: {
      href: "https://example.test/?gclid=abc&ok=1",
      origin: "https://example.test"
    },
    history: { state: null, replaceState: (_state, _title, next) => { replacement = next; } },
    browser: { storage: { local: storage } }
  });
  await run("thirdparty-utm-stripper", "content/stripper.js", context);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(replacement, "https://example.test/?ok=1");
  assert.equal(link.href, "https://example.test/path?ok=1");
  assert.equal(stored.floorpTrackingTokenStripperCount, 2);
  assert.equal(stored.floorpTrackingTokenStripperLastURL, "https://example.test");

  const popupDocument = new FakeDocument();
  const status = element(popupDocument);
  const reset = element(popupDocument, "button");
  popupDocument.set("#status", status);
  popupDocument.set("#reset", reset);
  await run("thirdparty-utm-stripper", "popup/popup.js", sandbox(popupDocument, {
    browser: { storage: { local: storage } }
  }));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(status.textContent, "2 tracking tokens removed locally. Last site: https://example.test.");
  await reset.dispatch("click");
  assert.equal(stored.floorpTrackingTokenStripperCount, 0);
  assert.equal(status.textContent, "No tracking tokens removed in this profile yet.");
}

async function testWebSearchNavigator() {
  const document = new FakeDocument();
  const first = element(document, "a");
  const second = element(document, "a");
  first.textContent = "First result";
  second.textContent = "Second result";
  document.set("#search a[href], #b_results a[href], [data-testid=results-list] a[href]", [first, second]);
  await run("thirdparty-web-search-navigator", "content/navigator.js", sandbox(document));
  await document.dispatch("keydown", { key: "j", target: null });
  assert.equal(first.classList.contains("floorp-search-selected"), true);
  assert.equal(first.focused, true);
}

async function testTrackerBlockLite() {
  const rules = JSON.parse(await source("floorp-tracker-block-lite", "rules/static.json"));
  assert.ok(rules.length > 0);
  assert.ok(rules.every(rule => rule.action?.type === "block"));
  assert.ok(rules.every(rule => typeof rule.condition?.urlFilter === "string"));
}

async function testVeryGoodAdBlock() {
  const rules = JSON.parse(await source("thirdparty-very-good-adblock", "rules/static.json"));
  assert.equal(rules.length, 16);
  assert.ok(rules.every(rule => rule.action?.type === "block"));
  assert.ok(rules.every(rule => rule.priority === 1));
  assert.ok(rules.every(rule => Array.isArray(rule.condition?.resourceTypes)));
  assert.ok(rules.every(rule => rule.condition.resourceTypes.every(type =>
    ["script", "image", "stylesheet", "xmlhttprequest"].includes(type)
  )));
}

async function testSessionTimer() {
  const document = new FakeDocument();
  let messageListener = null;
  let alarmListener = null;
  const stored = {};
  const created = [];
  const background = sandbox(document, {
    browser: {
      runtime: { onMessage: { addListener: listener => { messageListener = listener; } } },
      storage: { local: { set: async values => Object.assign(stored, values) } },
      alarms: {
        create: async (...arguments_) => created.push(arguments_),
        onAlarm: { addListener: listener => { alarmListener = listener; } }
      }
    }
  });
  await run("floorp-session-timer", "background/service-worker.js", background);
  const response = await messageListener({ type: "floorp-session-timer-start", minutes: 200 });
  assert.equal(response.scheduled, true);
  assert.equal(response.minutes, 120);
  assert.equal(stored.minutes, 120);
  assert.equal(created[0][0], "floorp-session-timer");
  assert.equal(created[0][1].delayInMinutes, 120);
  await alarmListener({ name: "floorp-session-timer" });
  assert.equal(typeof stored.completedAt, "number");

  const popupDocument = new FakeDocument();
  const start = element(popupDocument, "button");
  const minutes = element(popupDocument, "input");
  const status = element(popupDocument);
  minutes.value = "25";
  popupDocument.set("#start", start);
  popupDocument.set("#minutes", minutes);
  popupDocument.set("#status", status);
  await run("floorp-session-timer", "popup/popup.js", sandbox(popupDocument, {
    browser: { runtime: { sendMessage: async message => ({ scheduled: true, minutes: Number(message.minutes) }) } }
  }));
  await start.dispatch("click");
  assert.equal(status.textContent, "Timer started for 25 minutes.");

  const optionsDocument = new FakeDocument();
  const quiet = element(optionsDocument, "input");
  optionsDocument.set("#quiet", quiet);
  let savedQuiet = null;
  await run("floorp-session-timer", "options/options.js", sandbox(optionsDocument, {
    browser: {
      storage: {
        local: {
          get: async () => ({ quiet: true }),
          set: async values => { savedQuiet = values.quiet; }
        }
      }
    }
  }));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(quiet.checked, true);
  quiet.checked = false;
  await quiet.dispatch("change");
  assert.equal(savedQuiet, false);
}

await Promise.all([
  testSiteAppearance(),
  testEasyToRSS(),
  testEKill(),
  testEnhancedGitHub(),
  testGitHubDashboard(),
  testMinimalTwitter(),
  testMediumReadingLayout(),
  testRefinedHackerNews(),
  testRefinedTwitter(),
  testScrollToTop(),
  testUsefulForks(),
  testTrackingTokenStripper(),
  testWebSearchNavigator(),
  testTrackerBlockLite(),
  testVeryGoodAdBlock(),
  testSessionTimer()
]);

process.stdout.write(JSON.stringify({ status: "ok", adoptedPackages: 16 }) + "\n");
