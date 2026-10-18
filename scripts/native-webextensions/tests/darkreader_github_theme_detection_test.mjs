import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import vm from "node:vm";

const root = process.argv[2];
assert.ok(root, "usage: node darkreader_github_theme_detection_test.mjs <archive-root>");
const background = fs.readFileSync(path.join(root, "background/index.js"), "utf8");
const inject = fs.readFileSync(path.join(root, "inject/index.js"), "utf8");
const config = fs.readFileSync(path.join(root, "config/detector-hints.config"), "utf8");

function between(source, start, end) {
    const first = source.indexOf(start);
    assert.notEqual(first, -1, start);
    const last = source.indexOf(end, first);
    assert.notEqual(last, -1, end);
    return source.slice(first, last);
}

const parser = vm.createContext({URL});
vm.runInContext([
    between(background, "    function cachedFactory(", "    const wikiPDFPathRegexp"),
    between(background, "    function parseArray(", "    function getStringSize("),
    between(background, "    function parseSitesFixesConfig(", "    function getDomain("),
    between(background, "    function getDomain(", "    function processSiteFixesConfigBlock("),
    between(background, "    const detectorHintsCommands =", "    function formatDetectorHints("),
].join("\n"), parser);
const hints = parser.parseDetectorHints(config);
const hint = hints.find(item => item.url.includes("github.com"));
assert.ok(hint);
assert.equal(hint.target, "html");
assert.equal(hint.matchSystemDark.length, 1);
assert.equal(hint.matchSystemLight.length, 1);

vm.runInContext(`
    const CONFIG_URLs = {detectorHints: {local: "local", remote: "remote"}};
    const indexSitesFixesConfig = () => ({});
    class ConfigManager {
        static raw = {};
        static overrides = {};
        static loadConfig = async () => globalThis.fixtureConfig;
        ${between(background, "        static upgradeGitHubDetectorHints(", "        static async loadDynamicThemeFixes(")}
        ${between(background, "        static handleDetectorHints()", "        static handleDynamicThemeFixes()")}
    }
    globalThis.ConfigManager = ConfigManager;
`, parser);

const legacyGitHubHint = 'github.com\n\nTARGET\nhtml\n\nMATCH\n[data-color-mode="dark"]\n';
const unrelatedHint = 'example.com\n\nTARGET\nbody\n\nMATCH\n.custom-dark\n';
const separator = "\n================================\n\n";
const remoteConfig = unrelatedHint + separator + legacyGitHubHint + separator + unrelatedHint;
parser.fixtureConfig = remoteConfig;
await parser.ConfigManager.loadDetectorHints({local: false});
const upgradedConfig = parser.ConfigManager.DETECTOR_HINTS_RAW;
const remoteHint = parser.parseDetectorHints(upgradedConfig).find(item => item.url.includes("github.com"));
assert.equal(remoteHint.matchSystemDark.length, 1, "remote legacy hints gain dark-system matching");
assert.equal(remoteHint.matchSystemLight.length, 1, "remote legacy hints gain light-system matching");
assert.ok(upgradedConfig.startsWith(unrelatedHint + separator), "preceding remote blocks stay unchanged");
assert.ok(upgradedConfig.endsWith(separator + unrelatedHint), "following remote blocks stay unchanged");
assert.equal(parser.ConfigManager.upgradeGitHubDetectorHints(upgradedConfig), upgradedConfig, "upgrading is idempotent");

for (const preserved of [
    legacyGitHubHint.replace("github.com", "github.com\ngist.github.com"),
    legacyGitHubHint.replace('[data-color-mode="dark"]', ".different-dark-selector"),
    legacyGitHubHint + "\nNO DARK THEME\n",
    legacyGitHubHint + "\nMATCH SYSTEM DARK\n.custom-system-theme\n",
    legacyGitHubHint + "\nCUSTOM FUTURE\n.keep-this\n",
]) {
    assert.equal(parser.ConfigManager.upgradeGitHubDetectorHints(preserved), preserved, "custom and future hints are preserved");
}
// Upstream config blob c39a1a998cf010c09f32305bbc63b6a0ca9c9f7b has no GitHub rule.
const onlineConfig = fs.readFileSync(fileURLToPath(new URL("fixtures/darkreader-online-detector-hints.config", import.meta.url)), "utf8");
assert.ok(!parser.parseDetectorHints(onlineConfig).some(item => item.url.includes("github.com")));
parser.fixtureConfig = onlineConfig;
await parser.ConfigManager.loadDetectorHints({local: false});
const missingGitHubConfig = parser.ConfigManager.DETECTOR_HINTS_RAW;
assert.ok(missingGitHubConfig.startsWith(onlineConfig.trimEnd()), "unrelated downloaded hints are retained");
const missingGitHubHint = parser.parseDetectorHints(missingGitHubConfig).find(item => item.url.includes("github.com"));
assert.ok(missingGitHubHint, "remote configs without GitHub retain the Floorp fallback");
assert.equal(missingGitHubHint.matchSystemDark.length, 1);
assert.equal(missingGitHubHint.matchSystemLight.length, 1);
assert.equal(parser.ConfigManager.upgradeGitHubDetectorHints(missingGitHubConfig), missingGitHubConfig, "fallback insertion is idempotent");
for (const custom of [
    unrelatedHint + separator + legacyGitHubHint.replace('[data-color-mode="dark"]', ".custom-selector"),
    legacyGitHubHint.replace("github.com", "github.com/settings"),
    legacyGitHubHint.replace("github.com", "*"),
]) {
    assert.equal(parser.ConfigManager.upgradeGitHubDetectorHints(custom), custom, "custom matching rules take precedence over the fallback");
}
const crlfHint = legacyGitHubHint.replaceAll("\n", "\r\n");
const upgradedCRLF = parser.ConfigManager.upgradeGitHubDetectorHints(crlfHint);
assert.equal(parser.parseDetectorHints(upgradedCRLF)[0].matchSystemDark.length, 1, "CRLF remote hints are recognized");
assert.ok(!upgradedCRLF.replaceAll("\r\n", "").includes("\n"), "remote CRLF formatting is retained");

parser.fixtureConfig = legacyGitHubHint;
await parser.ConfigManager.loadDetectorHints({local: true});
assert.equal(parser.ConfigManager.DETECTOR_HINTS_RAW, legacyGitHubHint, "local input is not rewritten by the remote upgrade");
parser.ConfigManager.overrides.detectorHints = legacyGitHubHint;
await parser.ConfigManager.loadDetectorHints({local: false});
assert.equal(parser.ConfigManager.DETECTOR_HINTS_RAW, legacyGitHubHint, "DevTools overrides keep precedence without rewriting");
assert.equal(parser.ConfigManager.overrides.detectorHints, legacyGitHubHint, "the override itself is unchanged");
assert.equal(parser.parseDetectorHints(parser.ConfigManager.raw.detectorHints)[0].matchSystemDark.length, 1);

const detector = between(inject, "    let hintTargetObserver;", "    function cachedFactory(");

function createDetector(attributes, systemDark, selectedHint = hint) {
    const observers = [];
    let detections = 0;
    const target = {
        matches(selectors) {
            return selectors.split(",").some(selector => {
                const conditions = [...selector.matchAll(/\[([^\]=^]+)(\^?=)"([^"]*)"\]/g)];
                assert.ok(conditions.length > 0, selector);
                return conditions.every(([, key, operator, value]) => operator === "="
                    ? attributes[key] === value
                    : attributes[key]?.startsWith(value));
            });
        },
    };
    const sandbox = vm.createContext({
        isSystemDarkModeEnabled: () => systemDark,
        document: {
            querySelector(selector) {
                assert.equal(selector, "html");
                return target;
            },
            documentElement: {},
        },
        MutationObserver: class {
            constructor(callback) {
                this.callback = callback;
                observers.push(this);
            }
            observe() { this.active = true; }
            disconnect() { this.active = false; }
        },
    });
    vm.runInContext(detector, sandbox);
    sandbox.detectUsingHint(selectedHint, () => { detections += 1; });
    return {
        get detections() { return detections; },
        mutate(next) {
            Object.assign(attributes, next);
            for (const observer of observers.filter(item => item.active)) {
                observer.callback([]);
            }
        },
        stop() { sandbox.stopDetectingUsingHint(); },
    };
}

for (const selectedHint of [hint, remoteHint, missingGitHubHint]) {
    for (const systemDark of [false, true]) {
        for (const colorMode of ["auto", "light", "dark"]) {
            for (const lightTheme of ["light", "dark", "dark_dimmed"]) {
                for (const darkTheme of ["light", "dark", "dark_high_contrast"]) {
                    const activeTheme = colorMode === "auto"
                        ? (systemDark ? darkTheme : lightTheme)
                        : colorMode;
                    const expected = activeTheme.startsWith("dark");
                    const detector = createDetector({
                        "data-color-mode": colorMode,
                        "data-light-theme": lightTheme,
                        "data-dark-theme": darkTheme,
                    }, systemDark, selectedHint);
                    assert.equal(detector.detections, Number(expected), JSON.stringify({
                        systemDark, colorMode, lightTheme, darkTheme,
                    }));
                    detector.stop();
                }
            }
        }
    }
}

{
    const detector = createDetector({"data-color-mode": "auto"}, true);
    assert.equal(detector.detections, 0, "missing theme attributes are not proof of a dark theme");
    detector.mutate({"data-dark-theme": "dark_dimmed"});
    assert.equal(detector.detections, 1, "late GitHub theme attributes are observed");
    detector.mutate({"data-dark-theme": "dark"});
    assert.equal(detector.detections, 1, "successful detection disconnects its observer");
}

async function createContentLifecycle(systemDark, selectedHint = hint, engine = "ADD_CSS_FILTER") {
    const attributes = {
        "data-color-mode": "auto",
        "data-light-theme": "light",
        "data-dark-theme": "dark_dimmed",
    };
    const originalAttributes = {...attributes};
    const observers = [];
    const mediaListeners = new Set();
    const messages = [];
    let styleApplied = false;
    let svgApplied = false;
    let dynamicApplied = false;
    let hostEnabled = false;
    let enabled = true;
    let detectDarkTheme = true;
    let contentListener;
    let backgroundListener;
    const media = {
        matches: systemDark,
        addEventListener(type, callback) {
            assert.equal(type, "change");
            mediaListeners.add(callback);
        },
        removeEventListener(type, callback) {
            assert.equal(type, "change");
            mediaListeners.delete(callback);
        },
    };
    const target = {
        matches(selectors) {
            return selectors.split(",").some(selector => {
                const conditions = [...selector.matchAll(/\[([^\]=^]+)(\^?=)"([^\"]*)"\]/g)];
                return conditions.every(([, key, operator, value]) => operator === "="
                    ? attributes[key] === value
                    : attributes[key]?.startsWith(value));
            });
        },
    };
    const enums = between(inject, "    var MessageTypeUItoBG;", "    function hexify(");
    const sender = {
        tab: {id: 1, url: "https://github.com/"},
        frameId: 0,
        documentId: "test-document",
        url: "https://github.com/",
    };
    const bg = vm.createContext({
        StateManager: class {
            loadState() { return Promise.resolve(); }
            saveState() {}
        },
        logWarn() {},
        isPanel: () => false,
        IconManager: {setIcon() {}},
        chrome: {
            runtime: {onMessage: {addListener(listener) { backgroundListener = listener; }}},
            tabs: {
                onRemoved: {addListener() {}},
                sendMessage(tabId, message) {
                    assert.equal(tabId, 1);
                    return Promise.resolve().then(() => contentListener(message));
                },
            },
        },
    });
    vm.runInContext([
        enums,
        between(background, "    var DocumentState;", "    const proposedHighlights"),
        "globalThis.TabManager = TabManager; globalThis.messageTypes = {MessageTypeBGtoCS, MessageTypeCStoBG};",
    ].join("\n"), bg);
    const {MessageTypeBGtoCS, MessageTypeCStoBG} = bg.messageTypes;
    bg.TabManager.init({
        onColorSchemeChange() {}, // The user's automation mode is not SYSTEM.
        getConnectionMessage: async () => enabled ? {
            type: MessageTypeBGtoCS[engine],
            data: {css: "filter", theme: {}, detectDarkTheme, detectorHints: [selectedHint]},
        } : {type: MessageTypeBGtoCS.CLEAN_UP},
    });
    const content = vm.createContext({
        matchMedia: () => media,
        document: {querySelector: () => target, documentElement: {}},
        window: null,
        MutationObserver: class {
            constructor(callback) { this.callback = callback; observers.push(this); }
            observe() { this.active = true; }
            disconnect() { this.active = false; }
        },
        chrome: {runtime: {
            sendMessage(message) {
                messages.push(message);
                backgroundListener(message, sender, () => {});
                return Promise.resolve();
            },
            onMessage: {addListener(listener) { contentListener = listener; }},
        }},
        generateUID: () => "test-script",
        addEventListener() {},
        removeEventListener() {},
        logInfoCollapsed() {},
        cleanDynamicThemeCache() {},
        createOrUpdateStyle() { styleApplied = true; },
        removeStyle() { styleApplied = false; },
        createOrUpdateSVGFilter() { svgApplied = true; },
        removeSVGFilter() { svgApplied = false; },
        createOrUpdateDynamicTheme() { dynamicApplied = true; },
        removeDynamicTheme() { dynamicApplied = false; },
        writeEnabledForHost(value) { hostEnabled = value; },
    });
    content.window = {top: null};
    content.window.top = content.window;
    vm.runInContext([
        enums,
        between(inject, "    let query = null;", "    var MessageTypeUItoBG;"),
        between(inject, "    let observer$1;", "    function cachedFactory("),
        inject.slice(inject.indexOf("    let unloaded = false;"), inject.lastIndexOf("})();")),
        "globalThis.finishCleanup = cleanup;",
    ].join("\n"), content);
    const flush = async () => {
        for (let i = 0; i < 12; i += 1) {
            await Promise.resolve();
        }
    };
    await flush();
    return {
        async changeSystem(next) {
            media.matches = next;
            for (const listener of mediaListeners) { listener({matches: next}); }
            await flush();
            assert.deepEqual(attributes, originalAttributes, "OS changes leave GitHub attributes unchanged");
        },
        async setEnabled(value) {
            enabled = value;
            await contentListener({
                type: MessageTypeBGtoCS.CLEAN_UP,
                scriptId: "test-script",
            });
        },
        async disableDetection() {
            detectDarkTheme = false;
            await contentListener({
                type: MessageTypeBGtoCS[engine], scriptId: "test-script",
                data: {css: "filter", theme: {}, detectDarkTheme, detectorHints: [selectedHint]},
            });
        },
        assertTheme(expected) {
            assert.equal(styleApplied || dynamicApplied, expected, `theme applied for ${engine}`);
            assert.equal(svgApplied, expected && engine === "ADD_SVG_FILTER");
            assert.equal(hostEnabled, expected, "host enabled marker follows the actual theme");
            assert.equal(bg.TabManager.tabs[1][0].darkThemeDetected, !expected, "background detection state is refreshed");
        },
        get connections() { return messages.filter(m => m.type === MessageTypeCStoBG.DOCUMENT_CONNECT).length; },
        get themeApplied() { return styleApplied || svgApplied || dynamicApplied || hostEnabled; },
        get activeObservers() { return observers.filter(observer => observer.active).length; },
        get mediaListeners() { return mediaListeners.size; },
        cleanup() { content.finishCleanup(); },
    };
}

for (const selectedHint of [hint, remoteHint, missingGitHubHint]) {
    for (const engine of ["ADD_CSS_FILTER", "ADD_STATIC_THEME", "ADD_SVG_FILTER", "ADD_DYNAMIC_THEME"]) {
        for (const initialSystemDark of [false, true]) {
            const lifecycle = await createContentLifecycle(initialSystemDark, selectedHint, engine);
            lifecycle.assertTheme(!initialSystemDark);
            for (const next of [!initialSystemDark, initialSystemDark, !initialSystemDark]) {
                await lifecycle.changeSystem(next);
                lifecycle.assertTheme(!next);
            }
            lifecycle.cleanup();
            assert.equal(lifecycle.activeObservers, 0, "full cleanup disconnects hint observers");
            assert.equal(lifecycle.mediaListeners, 0, "full cleanup removes the media-query listener");
            const connections = lifecycle.connections;
            await lifecycle.changeSystem(initialSystemDark);
            assert.equal(lifecycle.connections, connections, "unloaded content cannot reconnect");
        }
    }
}

{
    const lifecycle = await createContentLifecycle(false);
    await lifecycle.setEnabled(false);
    await lifecycle.changeSystem(true);
    await lifecycle.changeSystem(false);
    assert.equal(lifecycle.themeApplied, false, "OS changes cannot override a disabled extension");
    assert.equal(lifecycle.activeObservers, 0, "disabled settings remain authoritative after OS changes");
    lifecycle.cleanup();
}
{
    const lifecycle = await createContentLifecycle(false);
    await lifecycle.disableDetection();
    const connections = lifecycle.connections;
    await lifecycle.changeSystem(true);
    assert.equal(lifecycle.connections, connections, "disabling detection stops hint-driven reconnects");
    assert.equal(lifecycle.activeObservers, 0, "disabling detection disconnects previous hint observers");
    lifecycle.cleanup();
}
{
    const customHint = parser.parseDetectorHints(legacyGitHubHint)[0];
    const lifecycle = await createContentLifecycle(false, customHint);
    const connections = lifecycle.connections;
    await lifecycle.changeSystem(true);
    assert.equal(lifecycle.connections, connections, "custom hints without system selectors keep their lifecycle");
    lifecycle.cleanup();
}

console.log("Dark Reader GitHub theme detection tests passed");
