import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const compatPath = process.argv[2];
if (!compatPath) {
    throw new Error("usage: node darkreader_floorp_compat_test.mjs <floorp-compat.js>");
}

function createMockStorage(initial = {}, failures = {}) {
    const records = {
        local: {...(initial.local || {})},
        sync: {...(initial.sync || {})}
    };
    const calls = [];
    const runtime = {
        id: "darkreader-test",
        lastError: null
    };
    const nextFailure = (key) => {
        const queue = failures[key] || [];
        return queue.length > 0 ? queue.shift() : null;
    };
    const invoke = (key, callback, value) => {
        const failure = nextFailure(key);
        queueMicrotask(() => {
            runtime.lastError = failure ? {message: failure} : null;
            callback(value);
            runtime.lastError = null;
        });
    };
    const area = (name) => ({
        get(keys, callback) {
            calls.push(`${name}.get`);
            let result;
            if (keys === null) {
                result = {...records[name]};
            } else if (typeof keys === "string") {
                result = Object.hasOwn(records[name], keys)
                    ? {[keys]: records[name][keys]}
                    : {};
            } else if (Array.isArray(keys)) {
                result = Object.fromEntries(
                    keys
                        .filter((key) => Object.hasOwn(records[name], key))
                        .map((key) => [key, records[name][key]])
                );
            } else {
                result = {...keys, ...records[name]};
            }
            invoke(`${name}.get`, callback, result);
        },
        set(values, callback) {
            calls.push(`${name}.set`);
            const failure = nextFailure(`${name}.set`);
            queueMicrotask(() => {
                runtime.lastError = failure ? {message: failure} : null;
                if (!failure) {
                    Object.assign(records[name], values);
                }
                callback();
                runtime.lastError = null;
            });
        },
        remove(keys, callback) {
            calls.push(`${name}.remove`);
            const failure = nextFailure(`${name}.remove`);
            queueMicrotask(() => {
                runtime.lastError = failure ? {message: failure} : null;
                if (!failure) {
                    for (const key of Array.isArray(keys) ? keys : [keys]) {
                        delete records[name][key];
                    }
                }
                callback();
                runtime.lastError = null;
            });
        }
    });
    return {
        api: {
            runtime,
            storage: {local: area("local"), sync: area("sync")}
        },
        records,
        calls
    };
}

const bootstrap = createMockStorage();
const context = {
    chrome: bootstrap.api,
    console,
    setTimeout,
    clearTimeout
};
context.globalThis = context;
vm.createContext(context);
vm.runInContext(fs.readFileSync(compatPath, "utf8"), context, {
    filename: compatPath
});
const createCompat = context.floorpCreateDarkReaderCompat;
assert.equal(typeof createCompat, "function");

{
    const mock = createMockStorage(
        {local: {enabled: false}},
        {"local.set": ["Unknown Error", null]}
    );
    const delays = [];
    const compat = createCompat(mock.api, {
        retryDelays: [1, 2, 3, 4],
        setTimeoutFn(callback, milliseconds) {
            delays.push(milliseconds);
            queueMicrotask(callback);
            return 1;
        },
        clearTimeoutFn() {}
    });
    const [loaded, concurrent] = await Promise.all([
        compat.get("local", {enabled: true}),
        compat.get("local", {enabled: true})
    ]);
    assert.equal(loaded.enabled, false);
    assert.equal(concurrent.enabled, false);
    assert.equal(Object.hasOwn(loaded, compat.sentinelKey), false);
    assert.deepEqual(delays, [1]);
    assert.equal(mock.calls.filter((call) => call === "local.set").length, 2);
}

{
    const mock = createMockStorage(
        {},
        {"local.get": ["Local/SyncStorage.db is unavailable"]}
    );
    const compat = createCompat(mock.api, {retryDelays: []});
    await assert.rejects(
        compat.get("local", {enabled: true}),
        /Local\/SyncStorage\.db is unavailable/
    );
    assert.equal(mock.calls.filter((call) => call === "local.get").length, 1);
}

{
    const mock = createMockStorage(
        {},
        {
            "local.set": [
                null,
                "unknown error",
                "unknown error",
                "unknown error",
                "unknown error",
                "unknown error",
                null
            ]
        }
    );
    const compat = createCompat(mock.api, {
        retryDelays: [0, 0, 0, 0],
        setTimeoutFn(callback) {
            queueMicrotask(callback);
            return 1;
        },
        clearTimeoutFn() {}
    });
    await assert.rejects(compat.set("local", {enabled: false}), /unknown error/i);
    await compat.set("local", {enabled: true});
    assert.equal(mock.records.local.enabled, true);
}

{
    const mock = createMockStorage();
    const compat = createCompat(mock.api);
    let first = true;
    const save = compat.createFlushableDebounce(60_000, async (settings) => {
        if (first) {
            first = false;
            throw new Error("injected write failure");
        }
        await compat.set("local", {settings});
    });

    const failed = save({enabled: false});
    await assert.rejects(save.flush(), /injected write failure/);
    await assert.rejects(failed, /injected write failure/);

    const persisted = save({enabled: true});
    await save.flush();
    await persisted;

    const coldCompat = createCompat(mock.api);
    const cold = await coldCompat.get("local", {settings: null});
    assert.equal(cold.settings.enabled, true);
}

{
    const compat = createCompat(createMockStorage().api);
    const mutations = compat.createRecoveringQueue();
    await assert.rejects(
        mutations.enqueue(async () => {
            throw new Error("first mutation failed");
        }),
        /first mutation failed/
    );
    await mutations.enqueue(async () => "second mutation persisted");
    await mutations.flush();
    assert.equal(mutations.getLastError(), null);
    assert.equal(compat.equal({b: 2, a: [1]}, {a: [1], b: 2}), true);
    assert.equal(compat.equal({enabled: true}, {enabled: false}), false);
}

console.log("Dark Reader Floorp compatibility tests passed");
