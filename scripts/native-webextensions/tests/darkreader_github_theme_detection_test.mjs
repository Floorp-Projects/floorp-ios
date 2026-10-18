import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
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

const parser = vm.createContext({});
vm.runInContext([
    between(background, "    function parseArray(", "    function getStringSize("),
    between(background, "    function parseSitesFixesConfig(", "    function getDomain("),
    between(background, "    const detectorHintsCommands =", "    function formatDetectorHints("),
].join("\n"), parser);
const hints = parser.parseDetectorHints(config);
const hint = hints.find(item => item.url.includes("github.com"));
assert.ok(hint);
assert.equal(hint.target, "html");
assert.equal(hint.matchSystemDark.length, 1);
assert.equal(hint.matchSystemLight.length, 1);

const detector = between(inject, "    let hintTargetObserver;", "    function cachedFactory(");

function createDetector(attributes, systemDark) {
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
    sandbox.detectUsingHint(hint, () => { detections += 1; });
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
                }, systemDark);
                assert.equal(detector.detections, Number(expected), JSON.stringify({
                    systemDark, colorMode, lightTheme, darkTheme,
                }));
                detector.stop();
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

console.log("Dark Reader GitHub theme detection tests passed");
