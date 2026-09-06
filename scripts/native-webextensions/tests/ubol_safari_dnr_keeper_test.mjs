import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

if ( process.argv.length !== 3 ) {
    throw new Error(
        'usage: node ubol_safari_dnr_keeper_test.mjs <extracted-archive-root>'
    );
}

const root = resolve(process.argv[2]);
let importSerial = 0;

const clone = value => structuredClone(value);
const nextTask = ( ) => new Promise(resolveTask => setTimeout(resolveTask, 2));

function createStorageArea(data) {
    return {
        async get(keys) {
            if ( keys === null || keys === undefined ) { return clone(data); }
            if ( typeof keys === 'string' ) {
                return Object.hasOwn(data, keys) ? { [keys]: clone(data[keys]) } : {};
            }
            const out = {};
            for ( const key of keys ) {
                if ( Object.hasOwn(data, key) ) { out[key] = clone(data[key]); }
            }
            return out;
        },
        async set(values) {
            Object.assign(data, clone(values));
        },
        async remove(keys) {
            for ( const key of Array.isArray(keys) ? keys : [ keys ] ) {
                delete data[key];
            }
        },
    };
}

function createLockManager(state) {
    const tails = new Map();
    return {
        request(name, options, callback) {
            state.lockRequests.push({ name, options: clone(options) });
            const before = tails.get(name) || Promise.resolve();
            const current = before
                .catch(( ) => undefined)
                .then(async ( ) => {
                    state.activeLocks += 1;
                    try {
                        return await callback({ name, mode: options.mode });
                    } finally {
                        state.activeLocks -= 1;
                    }
                });
            tails.set(name, current.catch(( ) => undefined));
            return current;
        },
    };
}

function createEnvironment({
    safari = true,
    withLocks = true,
    maxRules = 5000,
    limitMode = 'doubled-store',
    initialDynamicRules = [],
    initialSessionRules = [],
    promiseOnlyDNR = false,
} = {}) {
    const state = {
        dynamicRules: clone(initialDynamicRules),
        sessionRules: clone(initialSessionRules),
        enabledRulesets: [],
        localStorage: {},
        sessionStorage: {},
        activeUpdates: 0,
        activeLocks: 0,
        maxActiveUpdates: 0,
        emptyTransitions: [],
        lockRequests: [],
        nativeCalls: [],
        updates: [],
    };

    const ruleUpdate = async (storageType, options) => {
        state.activeUpdates += 1;
        state.maxActiveUpdates = Math.max(
            state.maxActiveUpdates,
            state.activeUpdates
        );
        const event = {
            storageType,
            options: clone(options),
            dynamicBefore: clone(state.dynamicRules),
            sessionBefore: clone(state.sessionRules),
            outcome: 'pending',
        };
        state.updates.push(event);
        try {
            await nextTask();
            const property = `${storageType}Rules`;
            const otherProperty = storageType === 'dynamic'
                ? 'sessionRules'
                : 'dynamicRules';
            const removeIds = new Set(options.removeRuleIds || []);
            const current = state[property];
            const retained = current.filter(rule => removeIds.has(rule.id) === false);
            const next = retained.slice();
            for ( const rule of options.addRules || [] ) {
                if ( next.some(existing => existing.id === rule.id) ) {
                    throw new Error(`duplicate ${storageType} rule ID ${rule.id}`);
                }
                next.push(clone(rule));
            }
            const exceedsLimit = limitMode === 'doubled-store'
                ? current.length + next.length > maxRules
                : next.length + state[otherProperty].length > maxRules;
            if ( exceedsLimit ) {
                throw new Error(
                    `Failed to add ${storageType} rules. Maximum number of ` +
                    'dynamic and session rules exceeded.'
                );
            }
            if ( retained.length === 0 && retained.length !== current.length ) {
                state.emptyTransitions.push(storageType);
            }
            state[property] = next;
            event.outcome = 'resolved';
        } catch(reason) {
            event.outcome = 'rejected';
            throw reason;
        } finally {
            state.activeUpdates -= 1;
        }
    };

    const staticUpdate = async options => {
        state.activeUpdates += 1;
        state.maxActiveUpdates = Math.max(
            state.maxActiveUpdates,
            state.activeUpdates
        );
        const event = {
            storageType: 'static',
            options: clone(options),
            dynamicBefore: clone(state.dynamicRules),
            sessionBefore: clone(state.sessionRules),
            outcome: 'pending',
        };
        state.updates.push(event);
        try {
            await nextTask();
            const enabled = new Set(state.enabledRulesets);
            for ( const id of options.disableRulesetIds || [] ) { enabled.delete(id); }
            for ( const id of options.enableRulesetIds || [] ) { enabled.add(id); }
            state.enabledRulesets = Array.from(enabled);
            event.outcome = 'resolved';
        } finally {
            state.activeUpdates -= 1;
        }
    };

    const runtime = {
        lastError: undefined,
        getURL(path) {
            const scheme = safari ? 'safari-web-extension:' : 'moz-extension:';
            return `${scheme}//test/${path}`;
        },
    };
    const dnr = {
        MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
        MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: maxRules,
        getDynamicRules(...args) {
            state.nativeCalls.push({ method: 'getDynamicRules', args });
            if ( promiseOnlyDNR ) {
                const ruleIds = args[0]?.ruleIds;
                const rules = Array.isArray(ruleIds)
                    ? state.dynamicRules.filter(rule => ruleIds.includes(rule.id))
                    : state.dynamicRules;
                return Promise.resolve(clone(rules));
            }
            const callback = args.at(-1);
            queueMicrotask(( ) => callback(clone(state.dynamicRules)));
        },
        getSessionRules(...args) {
            state.nativeCalls.push({ method: 'getSessionRules', args });
            if ( promiseOnlyDNR ) {
                const ruleIds = args[0]?.ruleIds;
                const rules = Array.isArray(ruleIds)
                    ? state.sessionRules.filter(rule => ruleIds.includes(rule.id))
                    : state.sessionRules;
                return Promise.resolve(clone(rules));
            }
            const callback = args.at(-1);
            queueMicrotask(( ) => callback(clone(state.sessionRules)));
        },
        getEnabledRulesets(...args) {
            state.nativeCalls.push({ method: 'getEnabledRulesets', args });
            if ( promiseOnlyDNR ) {
                return Promise.resolve(clone(state.enabledRulesets));
            }
            const callback = args.at(-1);
            queueMicrotask(( ) => callback(clone(state.enabledRulesets)));
        },
        updateDynamicRules(options) {
            state.nativeCalls.push({ method: 'updateDynamicRules', args: [ options ] });
            return ruleUpdate('dynamic', options);
        },
        updateSessionRules(options) {
            state.nativeCalls.push({ method: 'updateSessionRules', args: [ options ] });
            return ruleUpdate('session', options);
        },
        updateEnabledRulesets(options) {
            state.nativeCalls.push({ method: 'updateEnabledRulesets', args: [ options ] });
            return staticUpdate(options);
        },
        async getMatchedRules(...args) {
            state.nativeCalls.push({ method: 'getMatchedRules', args });
            state.matchedReadWasLocked = state.activeLocks !== 0;
            return clone(state.matchedRules || { rulesMatchedInfo: [] });
        },
        async isRegexSupported() {
            return { isSupported: true };
        },
        async setExtensionActionOptions() {},
    };
    const focusListeners = [];
    const browser = {
        runtime,
        declarativeNetRequest: dnr,
        storage: {
            local: createStorageArea(state.localStorage),
            session: createStorageArea(state.sessionStorage),
        },
        windows: {
            WINDOW_ID_NONE: -1,
            onFocusChanged: {
                addListener(listener) { focusListeners.push(listener); },
            },
            async get(windowId) { return { id: windowId, incognito: false }; },
            async getAll() { return []; },
        },
    };
    const navigator = withLocks ? { locks: createLockManager(state) } : {};
    return { browser, navigator, state };
}

async function importCompat(environment, label) {
    globalThis.self = {
        browser: environment.browser,
        navigator: environment.navigator,
    };
    const url = pathToFileURL(resolve(root, 'js/ext-compat.js'));
    url.searchParams.set('keeper-test', `${label}-${importSerial++}`);
    return import(url.href);
}

const hasRule = (rules, id) => rules.some(rule => rule.id === id);
const countRule = (rules, id) => rules.filter(rule => rule.id === id).length;

const safari = createEnvironment();
const firstRealm = await importCompat(safari, 'safari-first');
const secondRealm = await importCompat(safari, 'safari-second');
const keeperId = firstRealm.safariDNRKeeperRuleId;
assert.equal(keeperId, 7000000);
assert.equal(firstRealm.safariDNRKeeperRuleCount, 2);
assert.equal(firstRealm.safariDNRPublicRuleLimit, 4998);
assert.equal(firstRealm.safariDNRPublicRuleLimitPerStore, 2499);
assert.equal(firstRealm.dnr.MAX_NUMBER_OF_REGEX_RULES, 2499);
const rulesetManagerSource = await readFile(
    resolve(root, 'js/ruleset-manager.js'),
    'utf8'
);
const reservedBandStarts = new Map([
    'SPECIAL_RULES_REALM',
    'TRUSTED_DIRECTIVE_BASE_RULE_ID',
    'USER_RULES_BASE_RULE_ID',
].map(name => {
    const match = rulesetManagerSource.match(
        new RegExp(`const ${name} = (\\d+);`)
    );
    assert(match, `missing ${name}`);
    return [ name, Number.parseInt(match[1], 10) ];
}));
assert(keeperId > reservedBandStarts.get('SPECIAL_RULES_REALM'));
assert(keeperId < reservedBandStarts.get('TRUSTED_DIRECTIVE_BASE_RULE_ID'));
assert(keeperId < reservedBandStarts.get('USER_RULES_BASE_RULE_ID'));

const dynamicRule = {
    id: 1,
    priority: 1,
    action: { type: 'block' },
    condition: { urlFilter: 'dynamic.example' },
};
const sessionRule = {
    id: 2,
    priority: 1,
    action: { type: 'allow' },
    condition: { urlFilter: 'session.example' },
};

await Promise.all([
    firstRealm.dnr.updateDynamicRules({ addRules: [ dynamicRule ] }),
    secondRealm.dnr.updateSessionRules({ addRules: [ sessionRule ] }),
    secondRealm.dnr.updateEnabledRulesets({ enableRulesetIds: [ 'main' ] }),
]);

assert.equal(safari.state.maxActiveUpdates, 1, 'Safari DNR updates must serialize');
assert.equal(countRule(safari.state.dynamicRules, keeperId), 1);
assert.equal(countRule(safari.state.sessionRules, keeperId), 1);
assert(hasRule(safari.state.dynamicRules, dynamicRule.id));
assert(hasRule(safari.state.sessionRules, sessionRule.id));
assert.deepEqual(safari.state.emptyTransitions, []);
assert(safari.state.lockRequests.length >= 3);
assert(safari.state.lockRequests.every(request =>
    request.name === 'floorp.ubol.safari-dnr.v1' &&
    request.options.mode === 'exclusive'
));

const staticMutation = safari.state.updates.find(event =>
    event.storageType === 'static'
);
assert(staticMutation, 'the static ruleset mutation must run');
assert(hasRule(staticMutation.dynamicBefore, keeperId));
assert(hasRule(staticMutation.sessionBefore, keeperId));

assert.deepEqual(await firstRealm.dnr.getDynamicRules(), [ dynamicRule ]);
assert.deepEqual(await firstRealm.dnr.getSessionRules(), [ sessionRule ]);
assert.deepEqual(
    await firstRealm.dnr.getDynamicRules({ ruleIds: [ keeperId ] }),
    []
);
assert.deepEqual(
    await firstRealm.dnr.getSessionRules({ ruleIds: [ keeperId ] }),
    []
);

safari.state.matchedRules = {
    rulesMatchedInfo: [
        { rule: { ruleId: keeperId, rulesetId: '_dynamic' }, timeStamp: 1 },
        { rule: { ruleId: keeperId, rulesetId: '_session' }, timeStamp: 2 },
        { rule: { ruleId: keeperId, rulesetId: 'static-rules' }, timeStamp: 3 },
        { rule: { ruleId: 1, rulesetId: '_dynamic' }, timeStamp: 4 },
    ],
};
const matched = await firstRealm.dnr.getMatchedRules();
assert.equal(safari.state.matchedReadWasLocked, true);
assert.deepEqual(
    matched.rulesMatchedInfo.map(info => [ info.rule.ruleId, info.rule.rulesetId ]),
    [ [ 1, '_dynamic' ] ]
);

const updatesBeforeCollision = safari.state.updates.length;
await assert.rejects(
    firstRealm.dnr.updateDynamicRules({ removeRuleIds: [ keeperId ] }),
    /keeper rule cannot be removed/
);
await assert.rejects(
    firstRealm.dnr.updateDynamicRules({
        addRules: [ { ...dynamicRule, id: keeperId } ],
    }),
    /keeper rule ID is reserved/
);
await assert.rejects(
    firstRealm.dnr.updateSessionRules({ removeRuleIds: [ keeperId ] }),
    /keeper rule cannot be removed/
);
await assert.rejects(
    firstRealm.dnr.updateSessionRules({
        addRules: [ { ...sessionRule, id: keeperId } ],
    }),
    /keeper rule ID is reserved/
);
assert.equal(safari.state.updates.length, updatesBeforeCollision);

await Promise.all([
    firstRealm.dnr.updateDynamicRules({ removeRuleIds: [ dynamicRule.id ] }),
    secondRealm.dnr.updateSessionRules({ removeRuleIds: [ sessionRule.id ] }),
]);
assert.deepEqual(
    safari.state.dynamicRules.map(rule => rule.id),
    [ keeperId ]
);
assert.deepEqual(
    safari.state.sessionRules.map(rule => rule.id),
    [ keeperId ]
);
assert.deepEqual(safari.state.emptyTransitions, []);

safari.state.dynamicRules = [ {
    id: keeperId,
    priority: 1,
    action: { type: 'allow' },
    condition: { urlFilter: 'collision.example' },
} ];
await assert.rejects(
    firstRealm.dnr.getDynamicRules(),
    /dynamic DNR keeper rule ID collision/
);
const staticUpdatesBeforeCollision = safari.state.updates.filter(event =>
    event.storageType === 'static'
).length;
await assert.rejects(
    firstRealm.dnr.updateEnabledRulesets({ enableRulesetIds: [ 'other' ] }),
    /dynamic DNR keeper rule ID collision/
);
assert.equal(
    safari.state.updates.filter(event => event.storageType === 'static').length,
    staticUpdatesBeforeCollision,
    'a keeper collision must abort before static mutation'
);

const unlockedSafari = createEnvironment({ withLocks: false });
const unlockedFirst = await importCompat(unlockedSafari, 'unlocked-first');
const unlockedSecond = await importCompat(unlockedSafari, 'unlocked-second');
await Promise.all([
    unlockedFirst.dnr.updateDynamicRules({}),
    unlockedSecond.dnr.updateDynamicRules({}),
]);
assert.equal(countRule(unlockedSafari.state.dynamicRules, keeperId), 1);
assert.equal(
    unlockedSafari.state.updates.filter(event =>
        event.storageType === 'dynamic' && event.outcome === 'rejected'
    ).length,
    1,
    'simultaneous first-use must converge after a duplicate-ID race'
);
assert.equal(unlockedSafari.state.lockRequests.length, 0);

const legacyDynamicRules = [ 101, 102, 103, 104 ].map(id => ({
    ...dynamicRule,
    id,
    condition: { urlFilter: `legacy-dynamic-${id}.example` },
}));
const legacySessionRules = [ 201, 202 ].map(id => ({
    ...sessionRule,
    id,
    condition: { urlFilter: `legacy-session-${id}.example` },
}));

const freshCapacitySafari = createEnvironment({ maxRules: 6 });
const freshCapacityCompat = await importCompat(
    freshCapacitySafari,
    'fresh-capacity'
);
assert.equal(freshCapacityCompat.safariDNRPublicRuleLimit, 4);
assert.equal(freshCapacityCompat.safariDNRPublicRuleLimitPerStore, 2);
await freshCapacityCompat.dnr.updateDynamicRules({
    addRules: legacyDynamicRules.slice(0, 2),
});
await freshCapacityCompat.dnr.updateSessionRules({
    addRules: legacySessionRules,
});
assert.equal(countRule(freshCapacitySafari.state.dynamicRules, keeperId), 1);
assert.equal(countRule(freshCapacitySafari.state.sessionRules, keeperId), 1);
await freshCapacityCompat.dnr.updateDynamicRules({
    removeRuleIds: [ 101 ],
    addRules: [ {
        ...dynamicRule,
        id: 101,
        condition: { urlFilter: 'fresh-replacement.example' },
    } ],
});
await freshCapacityCompat.dnr.updateDynamicRules({
    removeRuleIds: [ 102 ],
});
await freshCapacityCompat.dnr.updateDynamicRules({
    addRules: [ legacyDynamicRules[1] ],
});
const freshCapacityBeforeRejectedAdd = clone(
    freshCapacitySafari.state.dynamicRules
);
const freshCapacityUpdatesBeforeRejectedAdd =
    freshCapacitySafari.state.updates.length;
await assert.rejects(
    freshCapacityCompat.dnr.updateDynamicRules({
        addRules: [ { ...dynamicRule, id: 105 } ],
    }),
    /at most 2 public dynamic rules/
);
assert.equal(
    freshCapacitySafari.state.updates.length,
    freshCapacityUpdatesBeforeRejectedAdd,
    'an over-limit fresh update must fail before any native mutation'
);
assert.deepEqual(
    freshCapacitySafari.state.dynamicRules,
    freshCapacityBeforeRejectedAdd
);
assert.deepEqual(freshCapacitySafari.state.emptyTransitions, []);

const capacitySafari = createEnvironment({
    maxRules: 6,
    initialDynamicRules: legacyDynamicRules,
    initialSessionRules: legacySessionRules,
});
const capacityCompat = await importCompat(capacitySafari, 'capacity');
assert.equal(capacityCompat.safariDNRPublicRuleLimit, 4);
assert.equal(capacityCompat.safariDNRPublicRuleLimitPerStore, 2);
assert.deepEqual(
    (await capacityCompat.dnr.getDynamicRules()).map(rule => rule.id),
    [ 101, 102, 103, 104 ],
    'a full legacy store must remain readable while keeper installation defers'
);
assert.deepEqual(
    (await capacityCompat.dnr.getSessionRules()).map(rule => rule.id),
    [ 201, 202 ]
);
assert.equal(hasRule(capacitySafari.state.dynamicRules, keeperId), false);
assert.equal(hasRule(capacitySafari.state.sessionRules, keeperId), false);
const capacityUpdatesBeforeNoop = capacitySafari.state.updates.length;
await capacityCompat.dnr.updateDynamicRules({
    addRules: [],
    removeRuleIds: [],
});
assert.equal(
    capacitySafari.state.updates.length,
    capacityUpdatesBeforeNoop,
    'an over-capacity legacy no-op must not reach native storage'
);

await capacityCompat.dnr.updateEnabledRulesets({
    enableRulesetIds: [ 'legacy-static' ],
});
assert.deepEqual(capacitySafari.state.enabledRulesets, [ 'legacy-static' ]);
assert.equal(
    hasRule(capacitySafari.state.dynamicRules, keeperId),
    false,
    'a static-only update may defer keepers at confirmed native capacity'
);

const fullStateBeforeRejectedAdd = clone(capacitySafari.state.dynamicRules);
await assert.rejects(
    capacityCompat.dnr.updateDynamicRules({
        addRules: [ { ...dynamicRule, id: 105 } ],
    }),
    /capacity reserves 2 hidden keeper slots/
);
assert.deepEqual(capacitySafari.state.dynamicRules, fullStateBeforeRejectedAdd);

await capacityCompat.dnr.updateDynamicRules({
    removeRuleIds: [ 101, 102, 103 ],
});
assert.deepEqual(
    (await capacityCompat.dnr.getDynamicRules()).map(rule => rule.id),
    [ 104 ]
);
assert.deepEqual(
    (await capacityCompat.dnr.getSessionRules()).map(rule => rule.id),
    [ 201, 202 ]
);
assert.equal(countRule(capacitySafari.state.dynamicRules, keeperId), 1);
assert.equal(countRule(capacitySafari.state.sessionRules, keeperId), 1);
assert.deepEqual(
    capacitySafari.state.emptyTransitions,
    [],
    'capacity migration must not transiently empty either native store'
);

const stagedSafari = createEnvironment({
    maxRules: 4,
    initialDynamicRules: legacyDynamicRules.slice(0, 2),
    initialSessionRules: legacySessionRules,
});
const stagedCompat = await importCompat(stagedSafari, 'staged-capacity');
await stagedCompat.dnr.updateDynamicRules({ removeRuleIds: [ 101 ] });
assert.deepEqual(stagedSafari.state.dynamicRules.map(rule => rule.id), [ 102 ]);
assert.equal(
    hasRule(stagedSafari.state.dynamicRules, keeperId),
    false,
    'a safe explicit removal may drain a pre-reservation store in stages'
);
assert.deepEqual(
    (await stagedCompat.dnr.getDynamicRules()).map(rule => rule.id),
    [ 102 ]
);
assert.equal(hasRule(stagedSafari.state.dynamicRules, keeperId), true);
assert.equal(hasRule(stagedSafari.state.sessionRules, keeperId), false);
await stagedCompat.dnr.updateDynamicRules({ removeRuleIds: [ 102 ] });
assert.deepEqual(await stagedCompat.dnr.getDynamicRules(), []);
assert.deepEqual(
    (await stagedCompat.dnr.getSessionRules()).map(rule => rule.id),
    [ 201, 202 ]
);
assert.equal(hasRule(stagedSafari.state.sessionRules, keeperId), false);
await stagedCompat.dnr.updateSessionRules({ removeRuleIds: [ 201 ] });
assert.equal(hasRule(stagedSafari.state.sessionRules, keeperId), true);
assert.deepEqual(stagedSafari.state.emptyTransitions, []);

const unanchoredSafari = createEnvironment({
    maxRules: 4,
    initialDynamicRules: legacyDynamicRules.slice(0, 2),
    initialSessionRules: legacySessionRules,
});
const unanchoredCompat = await importCompat(
    unanchoredSafari,
    'unanchored-capacity'
);
await assert.rejects(
    unanchoredCompat.dnr.updateDynamicRules({
        removeRuleIds: [ 101, 102 ],
    }),
    /cannot delete the last unguarded rule/
);
assert.deepEqual(
    unanchoredSafari.state.dynamicRules.map(rule => rule.id),
    [ 101, 102 ]
);
assert.deepEqual(unanchoredSafari.state.emptyTransitions, []);

const doubledLimitSafari = createEnvironment({
    maxRules: 6,
    limitMode: 'doubled-store',
    initialDynamicRules: legacyDynamicRules,
});
const doubledLimitCompat = await importCompat(
    doubledLimitSafari,
    'doubled-store-capacity'
);
assert.deepEqual(
    (await doubledLimitCompat.dnr.getDynamicRules()).map(rule => rule.id),
    [ 101, 102, 103, 104 ],
    'Safari 26 target-store count regression must not quarantine reads'
);
await doubledLimitCompat.dnr.updateEnabledRulesets({
    enableRulesetIds: [ 'doubled-limit-static' ],
});
assert.deepEqual(
    doubledLimitSafari.state.enabledRulesets,
    [ 'doubled-limit-static' ],
    'the unavoidable Safari 26 capacity state must not quarantine static DNR'
);
const doubledLimitBeforeRejectedDrain = clone(
    doubledLimitSafari.state.dynamicRules
);
await assert.rejects(
    doubledLimitCompat.dnr.updateDynamicRules({ removeRuleIds: [ 101 ] }),
    /at most 2 public dynamic rules/
);
assert.deepEqual(
    doubledLimitSafari.state.dynamicRules,
    doubledLimitBeforeRejectedDrain,
    'native quota rejection must preserve every legacy protection rule'
);
assert.deepEqual(doubledLimitSafari.state.emptyTransitions, []);
await doubledLimitCompat.dnr.updateDynamicRules({
    removeRuleIds: [ 101, 102, 103 ],
});
assert.deepEqual(
    (await doubledLimitCompat.dnr.getDynamicRules()).map(rule => rule.id),
    [ 104 ]
);
assert.equal(hasRule(doubledLimitSafari.state.dynamicRules, keeperId), true);
assert.equal(hasRule(doubledLimitSafari.state.sessionRules, keeperId), true);
assert.deepEqual(doubledLimitSafari.state.emptyTransitions, []);

const nonSafari = createEnvironment({
    safari: false,
    promiseOnlyDNR: true,
});
const firefoxCompat = await importCompat(nonSafari, 'non-safari');
assert.deepEqual(await firefoxCompat.dnr.getDynamicRules(), []);
assert.deepEqual(await firefoxCompat.dnr.getSessionRules(), []);
assert.equal(firefoxCompat.safariDNRPublicRuleLimit, 5000);
assert.equal(firefoxCompat.safariDNRPublicRuleLimitPerStore, 5000);
assert.equal(firefoxCompat.dnr.MAX_NUMBER_OF_REGEX_RULES, 5000);
const nonSafariUpdate = {
    addRules: [ { ...dynamicRule, id: keeperId } ],
};
await firefoxCompat.dnr.updateDynamicRules(nonSafariUpdate);
assert.equal(
    nonSafari.state.nativeCalls.find(call =>
        call.method === 'updateDynamicRules'
    ).args[0],
    nonSafariUpdate,
    'non-Safari updates must retain native Promise pass-through semantics'
);
const nonSafariFilter = { ruleIds: [ keeperId ] };
assert.equal(
    hasRule(await firefoxCompat.dnr.getDynamicRules(nonSafariFilter), keeperId),
    true
);
assert.equal(
    nonSafari.state.nativeCalls.filter(call =>
        call.method === 'getDynamicRules'
    ).at(-1).args[0],
    nonSafariFilter,
    'non-Safari reads must retain native Promise arguments'
);
await firefoxCompat.dnr.updateDynamicRules({ removeRuleIds: [ keeperId ] });
assert.deepEqual(await firefoxCompat.dnr.getDynamicRules(), []);
const nonSafariSessionUpdate = { addRules: [ sessionRule ] };
await firefoxCompat.dnr.updateSessionRules(nonSafariSessionUpdate);
assert.equal(
    nonSafari.state.nativeCalls.find(call =>
        call.method === 'updateSessionRules'
    ).args[0],
    nonSafariSessionUpdate
);
const nonSafariSessionFilter = { ruleIds: [ sessionRule.id ] };
assert.deepEqual(
    await firefoxCompat.dnr.getSessionRules(nonSafariSessionFilter),
    [ sessionRule ]
);
assert.equal(
    nonSafari.state.nativeCalls.filter(call =>
        call.method === 'getSessionRules'
    ).at(-1).args[0],
    nonSafariSessionFilter
);
await firefoxCompat.dnr.updateSessionRules({
    removeRuleIds: [ sessionRule.id ],
});
const enabledOptions = { enableRulesetIds: [ 'main' ] };
await firefoxCompat.dnr.updateEnabledRulesets(enabledOptions);
assert.equal(
    nonSafari.state.nativeCalls.find(call =>
        call.method === 'updateEnabledRulesets'
    ).args[0],
    enabledOptions
);
assert.deepEqual(await firefoxCompat.dnr.getEnabledRulesets(), [ 'main' ]);
assert.equal(
    nonSafari.state.nativeCalls.filter(call =>
        call.method === 'getEnabledRulesets'
    ).at(-1).args.length,
    0,
    'non-Safari enabled-ruleset reads must use the native no-argument Promise'
);
assert.deepEqual(nonSafari.state.sessionRules, []);
assert.equal(nonSafari.state.lockRequests.length, 0);

console.log('Safari DNR keeper tests passed');
