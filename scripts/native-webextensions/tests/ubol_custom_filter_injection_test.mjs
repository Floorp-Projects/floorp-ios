import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 9 ) {
    throw new Error(
        'usage: node ubol_custom_filter_injection_test.mjs ' +
        '<background.js> <filter-manager.js> <css-user.js> <css-api.js> ' +
        '<css-procedural-api.js> <css-user-idle-prelude.js> ' +
        '<css-user-idle.js>'
    );
}

const [
    backgroundPath,
    filterManagerPath,
    cssUserPath,
    cssAPIPath,
    proceduralAPIPath,
    idlePreludePath,
    idleMarkerPath,
] = process.argv.slice(2);
const [
    backgroundSource,
    filterManagerSource,
    cssUserSource,
    cssAPISource,
    proceduralAPISource,
    idlePreludeSource,
    idleMarkerSource,
] =
    await Promise.all([
        readFile(backgroundPath, 'utf8'),
        readFile(filterManagerPath, 'utf8'),
        readFile(cssUserPath, 'utf8'),
        readFile(cssAPIPath, 'utf8'),
        readFile(proceduralAPIPath, 'utf8'),
        readFile(idlePreludePath, 'utf8'),
        readFile(idleMarkerPath, 'utf8'),
    ]);

function extractBackgroundMessagePath(source) {
    const startMarker = 'const CUSTOM_FILTER_MESSAGE_SCHEMA = 1;';
    const endMarker = '\n/' + '*'.repeat(78) + '/\n\nfunction onCommand';
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, 'background custom-filter helpers must exist');
    assert.notEqual(end, -1, 'background onMessage boundary must exist');
    return source.slice(start, end);
}

function loadFilterManager(options = {}) {
    const calls = {
        executeScript: [],
        insertCSS: [],
        localRemove: [],
        localRead: [],
        localWrite: [],
    };
    const localStorage = options.localStorage;
    const sandbox = {
        browser: {
            scripting: {
                executeScript(details) {
                    calls.executeScript.push(structuredClone(details));
                    if ( options.executeScript ) {
                        return options.executeScript(details);
                    }
                    return Promise.resolve([ { documentId: 'executed-document' } ]);
                },
                insertCSS(details) {
                    calls.insertCSS.push(structuredClone(details));
                    if ( options.insertCSS ) {
                        return options.insertCSS(details);
                    }
                    return Promise.resolve();
                },
            },
        },
        localKeys: async ( ) => localStorage === undefined
            ? options.localKeys ?? []
            : Object.keys(localStorage),
        localRead: async key => {
            calls.localRead.push(key);
            return localStorage === undefined
                ? options.localRead?.(key)
                : structuredClone(localStorage[key]);
        },
        localRemove: async key => {
            calls.localRemove.push(structuredClone(key));
            if ( localStorage === undefined ) { return; }
            for ( const name of Array.isArray(key) ? key : [ key ] ) {
                delete localStorage[name];
            }
        },
        localWrite: async (key, value) => {
            calls.localWrite.push(structuredClone({ key, value }));
            if ( localStorage !== undefined ) {
                localStorage[key] = structuredClone(value);
            }
        },
        intersectHostnameIters: options.intersectHostnameIters ?? (( ) => []),
        isScriptlet: selector => selector.startsWith('+js('),
        matchesFromHostnames: options.matchesFromHostnames ??
            (hostnames => Array.from(hostnames)),
        subtractHostnameIters: ( ) => [],
        ubolErr() {},
    };
    sandbox.self = sandbox;
    const withoutImports = filterManagerSource.replace(
        /^import\b[\s\S]*?;\s*/gm,
        ''
    );
    const executable = withoutImports.replace(/^export\s+/gm, '');
    const context = vm.createContext(sandbox);
    vm.runInContext(
        `${executable}\n` +
        `self.__filterManager = {` +
        `assertSuccessfulScriptInjection,` +
        `committedCustomFilterMutationSnapshot,` +
        `committedSettingsRestoreSnapshot,` +
        `customFilterStorageKeys,customFiltersFromSnapshot,` +
        `customFilteringEnabledFromStorageSnapshot,injectCustomFilters,` +
        `mutateCustomFiltersAtomically,recoverCustomFilterMutation,` +
        `registerCustomFilters,replaceAllCustomFiltersAtomically,` +
        `replaceCustomFiltersAtomically};`,
        context,
        { filename: 'js/filter-manager.js' }
    );
    return { api: sandbox.__filterManager, calls, localStorage, sandbox };
}

const filter = loadFilterManager({
    localRead: ( ) => [ '#live-uncommitted' ],
});
assert.deepEqual(
    Array.from(filter.api.customFilterStorageKeys('www.example.test')),
    [ 'site.www.example.test', 'site.example.test', 'site.test' ]
);
const inherited = filter.api.customFiltersFromSnapshot('www.example.test', {
    'site.www.example.test': [ '#www' ],
    'site.example.test': [ '#parent' ],
    'site.test': [ '#tld' ],
});
assert.deepEqual(Array.from(inherited), [ '#parent', '#tld', '#www' ]);
assert.throws(
    ( ) => filter.api.customFiltersFromSnapshot('example.test', {
        'site.example.test': [ '#valid', 41 ],
    }),
    /Invalid custom-filter selector snapshot/
);

const proceduralRegistration = loadFilterManager({
    localKeys: [ 'site.example.test' ],
    localRead: ( ) => [ '#plain', '{"selector":"#procedural"}' ],
});
const proceduralRegistrationContext = {
    filteringModeDetails: {
        none: new Set(),
        basic: new Set(),
        optimal: new Set([ 'all-urls' ]),
        complete: new Set(),
    },
    toAdd: [],
};
await proceduralRegistration.api.registerCustomFilters(
    proceduralRegistrationContext
);
assert.deepEqual(
    Array.from(proceduralRegistrationContext.toAdd[0].js),
    [
        '/js/scripting/css-api.js',
        '/js/scripting/css-procedural-api.js',
        '/js/scripting/css-user.js',
    ],
    'procedural custom filters must preload their API in css-user isolated world'
);
assert.equal(proceduralRegistrationContext.toAdd[0].id, 'css-user');
assert.equal(proceduralRegistrationContext.toAdd[0].runAt, 'document_start');
assert.equal(proceduralRegistrationContext.toAdd[1].id, 'css-user-idle');
assert.equal(proceduralRegistrationContext.toAdd[1].runAt, 'document_idle');
assert.deepEqual(
    Array.from(proceduralRegistrationContext.toAdd[1].js),
    [
        '/js/scripting/css-user-idle-prelude.js',
        '/js/scripting/css-api.js',
        '/js/scripting/css-procedural-api.js',
        '/js/scripting/css-user-idle.js',
        '/js/scripting/css-user.js',
    ],
    'the idle marker must run immediately before css-user after API preloads'
);
assert.equal(proceduralRegistrationContext.toAdd[1].allFrames, true);
assert.equal(
    proceduralRegistrationContext.toAdd[1].matchOriginAsFallback,
    true
);

const plainRegistration = loadFilterManager({
    localKeys: [ 'site.example.test' ],
    localRead: ( ) => [ '#plain-only' ],
});
const plainRegistrationContext = {
    filteringModeDetails: proceduralRegistrationContext.filteringModeDetails,
    toAdd: [],
};
await plainRegistration.api.registerCustomFilters(plainRegistrationContext);
assert.deepEqual(
    Array.from(plainRegistrationContext.toAdd[0].js),
    [ '/js/scripting/css-user.js' ],
    'plain-only custom filters must not pay the procedural API startup cost'
);
assert.deepEqual(
    Array.from(plainRegistrationContext.toAdd[1].js),
    [
        '/js/scripting/css-user-idle-prelude.js',
        '/js/scripting/css-api.js',
        '/js/scripting/css-user-idle.js',
        '/js/scripting/css-user.js',
    ]
);

const inheritedProceduralRegistration = loadFilterManager({
    localKeys: [ 'site.child.example.test', 'site.example.test' ],
    localRead: key => key === 'site.example.test'
        ? [ '{"selector":"#inherited-procedural"}' ]
        : [ '#child-plain' ],
    intersectHostnameIters: hostnames => Array.from(hostnames).filter(
        hostname => hostname === 'child.example.test'
    ),
});
const inheritedProceduralRegistrationContext = {
    filteringModeDetails: {
        none: new Set([ 'all-urls' ]),
        basic: new Set(),
        optimal: new Set([ 'child.example.test' ]),
        complete: new Set(),
    },
    toAdd: [],
};
await inheritedProceduralRegistration.api.registerCustomFilters(
    inheritedProceduralRegistrationContext
);
assert.deepEqual(
    Array.from(inheritedProceduralRegistrationContext.toAdd[0].js),
    [
        '/js/scripting/css-api.js',
        '/js/scripting/css-procedural-api.js',
        '/js/scripting/css-user.js',
    ],
    'inherited procedural filters must preload for a selected child hostname'
);
assert.deepEqual(
    Array.from(inheritedProceduralRegistrationContext.toAdd[1].js),
    [
        '/js/scripting/css-user-idle-prelude.js',
        '/js/scripting/css-api.js',
        '/js/scripting/css-procedural-api.js',
        '/js/scripting/css-user-idle.js',
        '/js/scripting/css-user.js',
    ]
);

const journalUnionRegistration = loadFilterManager();
const journalUnionContext = {
    filteringModeDetails: proceduralRegistrationContext.filteringModeDetails,
    localStorageSnapshot: {
        'site.target.test': [ '#target' ],
        'floorp.settingsRestoreJournal.v1': {
            version: 1,
            id: 'settings-union',
            phase: 'applying',
            beforeLocal: {
                'site.before.test': [ '{"selector":"#before"}' ],
            },
        },
        'floorp.customFilterMutationJournal.v1': {
            version: 1,
            id: 'mutation-union',
            phase: 'rollingBack',
            beforeLocal: {
                'site.mutation.test': [ '#mutation' ],
            },
        },
    },
    toAdd: [],
};
await journalUnionRegistration.api.registerCustomFilters(journalUnionContext);
assert.equal(journalUnionContext.toAdd.length, 2);
assert.equal(journalUnionContext.toAdd[0].excludeMatches, undefined);
assert.deepEqual(
    Array.from(journalUnionContext.toAdd[0].matches).sort(),
    [ 'before.test', 'mutation.test', 'target.test' ]
);
assert.deepEqual(
    Array.from(journalUnionContext.toAdd[1].js),
    [
        '/js/scripting/css-user-idle-prelude.js',
        '/js/scripting/css-api.js',
        '/js/scripting/css-procedural-api.js',
        '/js/scripting/css-user-idle.js',
        '/js/scripting/css-user.js',
    ],
    'active journals must preserve before/live roots and procedural preload'
);

const optimalModes = {
    none: [],
    basic: [],
    optimal: [ 'all-urls' ],
    complete: [],
};
const defaultNoneChildOptimal = {
    none: [ 'all-urls' ],
    basic: [],
    optimal: [ 'child.example.test' ],
    complete: [],
};
assert.equal(
    filter.api.customFilteringEnabledFromStorageSnapshot(
        { filteringModeDetails: defaultNoneChildOptimal },
        'child.example.test'
    ),
    true
);
assert.equal(
    filter.api.customFilteringEnabledFromStorageSnapshot(
        { filteringModeDetails: defaultNoneChildOptimal },
        'sibling.example.test'
    ),
    false
);
assert.equal(
    filter.api.customFilteringEnabledFromStorageSnapshot({
        filteringModeDetails: optimalModes,
        'admin.noFiltering': { data: [ 'child.example.test' ] },
    }, 'child.example.test'),
    false
);
assert.equal(
    filter.api.customFilteringEnabledFromStorageSnapshot({
        filteringModeDetails: optimalModes,
        'admin.noFiltering': { data: [ '*' ] },
    }, 'unrelated.example'),
    false,
    'administrator wildcard no-filtering must cover every hostname'
);
assert.equal(
    filter.api.customFilteringEnabledFromStorageSnapshot({
        filteringModeDetails: {
            none: [ 'sub.example.com', 'other.net' ],
            basic: [],
            optimal: [ 'all-urls' ],
            complete: [ 'example.com' ],
        },
        'admin.noFiltering': { data: [ 'all-urls' ] },
    }, 'sub.example.com'),
    true,
    'an administrator all-urls override must clear stale target-mode sites'
);
assert.equal(
    filter.api.customFilteringEnabledFromStorageSnapshot({
        filteringModeDetails: {
            none: [ 'all-urls' ],
            basic: [],
            optimal: [],
            complete: [],
        },
        'admin.defaultFiltering': { data: 'optimal' },
    }, 'child.example.test'),
    true
);

const documentTarget = { tabId: 7, documentIds: [ 'document-seven' ] };
const committedSnapshot = {
    'site.example.test': [ '#committed', '{"raw":"procedural"}' ],
};
const injected = await filter.api.injectCustomFilters(
    documentTarget,
    'example.test',
    committedSnapshot
);
assert.deepEqual(Array.from(injected.plainSelectors), [ '#committed' ]);
assert.deepEqual(
    Array.from(injected.proceduralSelectors),
    [ '{"raw":"procedural"}' ]
);
assert.deepEqual(filter.calls.localRead, []);
assert.deepEqual(filter.calls.insertCSS[0].target, documentTarget);
assert.deepEqual(
    filter.calls.executeScript,
    [],
    'the selector acknowledgement must not depend on dynamic injection into ' +
    'an origin-fallback frame'
);

const insertFailure = loadFilterManager({
    insertCSS: ( ) => Promise.reject(new Error('insert rejected')),
});
await assert.rejects(
    insertFailure.api.injectCustomFilters(
        documentTarget,
        'example.test',
        { 'site.example.test': [ '#plain' ] }
    ),
    /insert rejected/
);

const originFallbackProcedural = loadFilterManager({
    executeScript: ( ) => {
        throw new Error('dynamic injection must not run');
    },
});
const originFallbackDetails = await originFallbackProcedural.api.injectCustomFilters(
    documentTarget,
    'example.test',
    { 'site.example.test': [ '{"raw":"procedural"}' ] }
);
assert.deepEqual(
    Array.from(originFallbackDetails.proceduralSelectors),
    [ '{"raw":"procedural"}' ]
);
assert.deepEqual(originFallbackProcedural.calls.executeScript, []);

const committedTransactionStorage = {
    'site.before.test': [ '#before' ],
};
const committedTransaction = loadFilterManager({
    localStorage: committedTransactionStorage,
});
const committedRegistrationStates = [];
const committedMutation = await committedTransaction.api
    .replaceAllCustomFiltersAtomically(
        [ [ 'after.test', [ '#after' ] ] ],
        async ( ) => {
            committedRegistrationStates.push(
                structuredClone(committedTransactionStorage)
            );
        }
    );
assert.equal(committedMutation, true);
assert.deepEqual(committedTransactionStorage, {
    'site.after.test': [ '#after' ],
});
assert.equal(committedRegistrationStates.length, 2);
assert.equal(
    committedRegistrationStates[0][
        'floorp.customFilterMutationJournal.v1'
    ].phase,
    'applying'
);
assert.deepEqual(
    committedRegistrationStates[0][
        'floorp.customFilterMutationJournal.v1'
    ].beforeLocal,
    { 'site.before.test': [ '#before' ] }
);
assert.equal(
    committedRegistrationStates[1][
        'floorp.customFilterMutationJournal.v1'
    ],
    undefined
);

const rolledBackTransactionStorage = {
    'site.before.test': [ '#before' ],
};
const rolledBackTransaction = loadFilterManager({
    localStorage: rolledBackTransactionStorage,
});
const rollbackRegistrationStates = [];
let rejectTargetRegistration = true;
await assert.rejects(
    rolledBackTransaction.api.replaceAllCustomFiltersAtomically(
        [ [ 'after.test', [ '#after' ] ] ],
        async ( ) => {
            rollbackRegistrationStates.push(
                structuredClone(rolledBackTransactionStorage)
            );
            if ( rejectTargetRegistration ) {
                rejectTargetRegistration = false;
                throw new Error('registration failed');
            }
        }
    ),
    /registration failed/
);
assert.deepEqual(rolledBackTransactionStorage, {
    'site.before.test': [ '#before' ],
});
assert.equal(rollbackRegistrationStates.length, 3);
assert.equal(
    rollbackRegistrationStates[1][
        'floorp.customFilterMutationJournal.v1'
    ].phase,
    'rollingBack'
);
assert.equal(
    rollbackRegistrationStates[2][
        'floorp.customFilterMutationJournal.v1'
    ],
    undefined
);

const narrowFailureStorage = {
    'site.before.test': [ '#before' ],
};
const narrowFailure = loadFilterManager({ localStorage: narrowFailureStorage });
let narrowAttempts = 0;
assert.equal(
    await narrowFailure.api.replaceAllCustomFiltersAtomically(
        [ [ 'after.test', [ '#after' ] ] ],
        async ( ) => {
            narrowAttempts += 1;
            if ( narrowAttempts === 2 ) {
                throw new Error('redundant narrow failed');
            }
        }
    ),
    true
);
assert.equal(narrowAttempts, 2);
assert.deepEqual(narrowFailureStorage, {
    'site.after.test': [ '#after' ],
});

const interruptedMutationStorage = {
    'site.partial.test': [ '#partial' ],
    'floorp.customFilterMutationJournal.v1': {
        version: 1,
        id: 'interrupted-custom-filter-write',
        phase: 'applying',
        beforeLocal: {
            'site.committed.test': [ '#committed' ],
        },
    },
};
const interruptedMutation = loadFilterManager({
    localStorage: interruptedMutationStorage,
});
assert.equal(
    await interruptedMutation.api.recoverCustomFilterMutation(),
    true
);
assert.deepEqual(interruptedMutationStorage, {
    'site.committed.test': [ '#committed' ],
});

function loadBackground(options = {}) {
    const calls = {
        ensureFullyInitialized: 0,
        executeScript: [],
        injectCustomFilters: [],
        insertCSS: [],
        localRead: [],
        localSnapshot: 0,
        localSnapshotArguments: [],
        removeCSS: [],
    };
    const never = new Promise(( ) => {});
    const sandbox = {
        assertSuccessfulScriptInjection:
            filter.sandbox.assertSuccessfulScriptInjection ||
            filter.api.assertSuccessfulScriptInjection,
        browser: {
            scripting: {
                executeScript(details) {
                    calls.executeScript.push(structuredClone(details));
                    return Promise.resolve(
                        options.executeResults ?? [ { documentId: 'executed' } ]
                    );
                },
                insertCSS(details) {
                    calls.insertCSS.push(structuredClone(details));
                    return Promise.resolve();
                },
                removeCSS(details) {
                    calls.removeCSS.push(structuredClone(details));
                    return Promise.resolve();
                },
            },
        },
        ensureFullyInitialized() {
            calls.ensureFullyInitialized += 1;
            return never;
        },
        getEnabledRulesets: async ( ) => [],
        injectCustomFilters(target, hostname, storageSnapshot) {
            calls.injectCustomFilters.push({
                target: structuredClone(target),
                hostname,
                storageSnapshot: storageSnapshot === undefined
                    ? undefined
                    : structuredClone(storageSnapshot),
            });
            if ( options.injectCustomFilters ) {
                return options.injectCustomFilters(
                    target,
                    hostname,
                    storageSnapshot
                );
            }
            return Promise.resolve({
                plainSelectors: [ '#background' ],
                proceduralSelectors: [],
            });
        },
        customFilterStorageKeys: filter.api.customFilterStorageKeys,
        customFilterModeStorageKeys: [
            'filteringModeDetails',
            'admin.defaultFiltering',
            'admin.noFiltering',
        ],
        customFilterMutationJournalKey:
            'floorp.customFilterMutationJournal.v1',
        committedCustomFilterMutationSnapshot:
            filter.api.committedCustomFilterMutationSnapshot,
        committedSettingsRestoreSnapshot:
            filter.api.committedSettingsRestoreSnapshot,
        customFilteringEnabledFromStorageSnapshot:
            filter.api.customFilteringEnabledFromStorageSnapshot,
        localRead(key) {
            calls.localRead.push(key);
            return Promise.resolve(options.journal);
        },
        localSnapshot(excludedKeys, requestedKeys) {
            calls.localSnapshot += 1;
            calls.localSnapshotArguments.push(structuredClone({
                excludedKeys,
                requestedKeys,
            }));
            if ( options.localSnapshot ) {
                return Promise.resolve(options.localSnapshot(
                    excludedKeys,
                    requestedKeys
                ));
            }
            if ( options.localState ) {
                return Promise.resolve(structuredClone(options.localState));
            }
            if ( options.journal ) {
                return Promise.resolve({
                    'floorp.settingsRestoreJournal.v1': structuredClone(
                        options.journal
                    ),
                    'site.example.test': [ '#live-uncommitted' ],
                });
            }
            return Promise.resolve({});
        },
        SETTINGS_RESTORE_JOURNAL_KEY: 'floorp.settingsRestoreJournal.v1',
        ubolErr() {},
        URL,
    };
    sandbox.self = sandbox;
    const context = vm.createContext(sandbox);
    vm.runInContext(
        `${extractBackgroundMessagePath(backgroundSource)}\n` +
        `self.__onMessage = onMessage;`,
        context,
        { filename: 'js/background.js' }
    );
    return { calls, onMessage: sandbox.__onMessage };
}

const sender = (
    documentId,
    url = 'https://example.test/page',
    frameId = 0,
    origin,
    tabURL = 'https://example.test/page'
) => ({
    tab: { id: 12, url: tabURL },
    frameId,
    documentId,
    url,
    ...(origin === undefined ? {} : { origin }),
});
const request = (requestId, hostname = 'example.test') => ({
    what: 'injectCustomFilters',
    schema: 1,
    requestId,
    hostname,
});

const background = loadBackground();
const reply = await background.onMessage(
    request('bound-document'),
    sender('main-document')
);
assert.deepEqual(structuredClone(reply), {
    ok: true,
    schema: 1,
    requestId: 'bound-document',
    plainSelectors: [ '#background' ],
    proceduralSelectors: [],
});
assert.deepEqual(background.calls.injectCustomFilters, [ {
    target: { tabId: 12, documentIds: [ 'main-document' ] },
    hostname: 'example.test',
    storageSnapshot: {},
} ]);
assert.equal(background.calls.ensureFullyInitialized, 0);
assert.equal(background.calls.localSnapshot, 1);
assert.deepEqual(background.calls.localSnapshotArguments, [ {
    excludedKeys: [],
    requestedKeys: [
        'floorp.settingsRestoreJournal.v1',
        'floorp.customFilterMutationJournal.v1',
        'filteringModeDetails',
        'admin.defaultFiltering',
        'admin.noFiltering',
        'site.example.test',
        'site.test',
    ],
} ]);
assert.deepEqual(background.calls.localRead, []);

for ( const invalidDocumentId of [ undefined, '', '   ', 42 ] ) {
    const invalid = loadBackground();
    const invalidReply = await invalid.onMessage(
        request(`invalid-${String(invalidDocumentId)}`),
        sender(invalidDocumentId)
    );
    assert.equal(invalidReply.ok, false);
    assert.match(invalidReply.error, /document ID/);
    assert.deepEqual(invalid.calls.injectCustomFilters, []);
}

const mismatched = loadBackground();
const mismatchReply = await mismatched.onMessage(
    request('host-mismatch'),
    sender('mismatched-document', 'https://other.test/')
);
assert.equal(mismatchReply.ok, false);
assert.match(mismatchReply.error, /hostname mismatch/);
assert.deepEqual(mismatched.calls.injectCustomFilters, []);

// The background sender describes the child URL/origin, not the immediate
// parent URL WebKit used for matchOriginAsFallback. Those documents must use
// css-user's bounded storage path and are rejected here rather than selecting
// an embedded blob origin or trusting a page-derived hostname.
for ( const fallback of [
    {
        label: 'about-blank',
        url: 'about:blank',
        origin: 'https://example.test',
    },
    {
        label: 'about-srcdoc',
        url: 'about:srcdoc',
        origin: 'https://example.test',
    },
    {
        label: 'data',
        url: 'data:text/html,frame',
        origin: 'https://example.test',
    },
    {
        label: 'blob',
        url: 'blob:https://example.test/2cd67a74-3675-47ab-bcec-59480a14285d',
        origin: 'https://wrong-origin.test',
    },
] ) {
    const originFallback = loadBackground();
    const originFallbackReply = await originFallback.onMessage(
        request(`origin-fallback-${fallback.label}`),
        sender(
            `origin-fallback-${fallback.label}-document`,
            fallback.url,
            4,
            fallback.origin
        )
    );
    assert.equal(originFallbackReply.ok, false, fallback.label);
    assert.match(originFallbackReply.error, /hostname mismatch/, fallback.label);
    assert.deepEqual(originFallback.calls.injectCustomFilters, [], fallback.label);
}

for ( const [ label, requestedHostname, fallbackSender ] of [
    [
        'spoofed base hostname',
        'other.test',
        sender(
            'spoofed-base-document',
            'about:srcdoc',
            4,
            'https://example.test'
        ),
    ],
    [
        'opaque sender origin',
        'example.test',
        sender('opaque-document', 'data:text/html,frame', 4, 'null'),
    ],
    [
        'missing sender origin',
        'example.test',
        sender('missing-origin-document', 'about:blank', 4),
    ],
] ) {
    const rejectedFallback = loadBackground();
    const rejectedFallbackReply = await rejectedFallback.onMessage(
        request(`rejected-${label}`, requestedHostname),
        fallbackSender
    );
    assert.equal(rejectedFallbackReply.ok, false, label);
    assert.match(rejectedFallbackReply.error, /hostname mismatch/, label);
    assert.deepEqual(rejectedFallback.calls.injectCustomFilters, [], label);
}

const directURLWins = loadBackground();
const directURLMismatchReply = await directURLWins.onMessage(
    request('direct-url-wins', 'origin-only.test'),
    sender(
        'direct-url-document',
        'https://example.test/frame',
        4,
        'https://origin-only.test'
    )
);
assert.equal(directURLMismatchReply.ok, false);
assert.match(directURLMismatchReply.error, /hostname mismatch/);
assert.deepEqual(directURLWins.calls.injectCustomFilters, []);

const subframe = loadBackground();
await subframe.onMessage(
    request('subframe-document'),
    sender('subframe-exact-document', 'https://example.test/frame', 9)
);
assert.deepEqual(
    subframe.calls.injectCustomFilters[0].target,
    { tabId: 12, documentIds: [ 'subframe-exact-document' ] }
);

let resolveOldDocument;
const oldDocumentReply = new Promise(resolve => {
    resolveOldDocument = resolve;
});
const navigated = loadBackground({
    injectCustomFilters(target) {
        if ( target.documentIds[0] === 'old-document' ) {
            return oldDocumentReply;
        }
        return Promise.resolve({
            plainSelectors: [ '#new-document' ],
            proceduralSelectors: [],
        });
    },
});
const delayedOld = navigated.onMessage(
    request('old-request'),
    sender('old-document')
);
const immediateNew = await navigated.onMessage(
    request('new-request'),
    sender('new-document')
);
assert.equal(immediateNew.plainSelectors[0], '#new-document');
assert.deepEqual(
    navigated.calls.injectCustomFilters.map(call => call.target.documentIds[0]),
    [ 'old-document', 'new-document' ]
);
resolveOldDocument({ plainSelectors: [ '#old-document' ], proceduralSelectors: [] });
assert.equal((await delayedOld).plainSelectors[0], '#old-document');

const beforeLocal = {
    'site.example.test': [ '#last-committed' ],
};
for ( const phase of [ 'applying', 'committingForeground', 'rollingBack' ] ) {
    const restoring = loadBackground({
        journal: {
            version: 1,
            id: `restore-${phase}`,
            phase,
            beforeLocal,
        },
    });
    await restoring.onMessage(
        request(`journal-${phase}`),
        sender(`journal-${phase}`)
    );
    assert.deepEqual(
        restoring.calls.injectCustomFilters[0].storageSnapshot,
        {
            ...beforeLocal,
            'admin.defaultFiltering': undefined,
            'admin.noFiltering': undefined,
        }
    );
    assert.equal(restoring.calls.ensureFullyInitialized, 0);
    assert.equal(restoring.calls.localSnapshot, 1);
    assert.deepEqual(restoring.calls.localRead, []);
}

for ( const phase of [ 'applying', 'committingForeground', 'rollingBack' ] ) {
    const managedDisableDuringRestore = loadBackground({
        localState: {
            filteringModeDetails: optimalModes,
            'admin.defaultFiltering': { data: 'none' },
            'admin.noFiltering': { data: [ 'example.test' ] },
            'site.example.test': [ '#live-uncommitted' ],
            'floorp.settingsRestoreJournal.v1': {
                version: 1,
                id: `managed-disable-${phase}`,
                phase,
                beforeLocal: {
                    filteringModeDetails: optimalModes,
                    'admin.defaultFiltering': { data: 'optimal' },
                    'admin.noFiltering': { data: [] },
                    'site.example.test': [ '#last-committed' ],
                },
            },
        },
    });
    const reply = await managedDisableDuringRestore.onMessage(
        request(`managed-disable-${phase}`),
        sender(`managed-disable-${phase}`)
    );
    assert.deepEqual(Array.from(reply.plainSelectors), []);
    assert.deepEqual(managedDisableDuringRestore.calls.injectCustomFilters, []);

    const managedRelaxDuringRestore = loadBackground({
        localState: {
            filteringModeDetails: {
                none: [ 'all-urls' ],
                basic: [],
                optimal: [],
                complete: [],
            },
            'admin.defaultFiltering': { data: 'optimal' },
            'admin.noFiltering': { data: [] },
            'site.example.test': [ '#live-uncommitted' ],
            'floorp.settingsRestoreJournal.v1': {
                version: 1,
                id: `managed-relax-${phase}`,
                phase,
                beforeLocal: {
                    filteringModeDetails: optimalModes,
                    'admin.defaultFiltering': { data: 'none' },
                    'admin.noFiltering': { data: [ 'example.test' ] },
                    'site.example.test': [ '#last-committed' ],
                },
            },
        },
    });
    await managedRelaxDuringRestore.onMessage(
        request(`managed-relax-${phase}`),
        sender(`managed-relax-${phase}`)
    );
    assert.deepEqual(
        managedRelaxDuringRestore.calls.injectCustomFilters[0].storageSnapshot,
        {
            filteringModeDetails: optimalModes,
            'admin.defaultFiltering': { data: 'optimal' },
            'admin.noFiltering': { data: [] },
            'site.example.test': [ '#last-committed' ],
        }
    );
}

const customMutationSnapshot = loadBackground({
    localState: {
        filteringModeDetails: optimalModes,
        'site.example.test': [ '#live-partial' ],
        'floorp.customFilterMutationJournal.v1': {
            version: 1,
            id: 'custom-filter-write',
            phase: 'applying',
            beforeLocal: {
                'site.example.test': [ '#custom-filter-committed' ],
            },
        },
    },
});
await customMutationSnapshot.onMessage(
    request('custom-filter-journal'),
    sender('custom-filter-journal-document')
);
assert.deepEqual(
    customMutationSnapshot.calls.injectCustomFilters[0].storageSnapshot,
    {
        filteringModeDetails: optimalModes,
        'admin.defaultFiltering': undefined,
        'admin.noFiltering': undefined,
        'site.example.test': [ '#custom-filter-committed' ],
    }
);

const disabledModeBackground = loadBackground({
    localState: {
        filteringModeDetails: {
            none: [ 'example.test' ],
            basic: [],
            optimal: [ 'all-urls' ],
            complete: [],
        },
        'site.example.test': [ '#must-not-inject' ],
    },
});
const disabledModeReply = await disabledModeBackground.onMessage(
    request('disabled-mode'),
    sender('disabled-mode-document')
);
assert.deepEqual(structuredClone(disabledModeReply), {
    ok: true,
    schema: 1,
    requestId: 'disabled-mode',
    plainSelectors: [],
    proceduralSelectors: [],
});
assert.deepEqual(disabledModeBackground.calls.injectCustomFilters, []);

const managedWildcardBackground = loadBackground({
    localState: {
        filteringModeDetails: optimalModes,
        'admin.noFiltering': { data: [ '*' ] },
        'site.example.test': [ '#must-not-inject' ],
    },
});
const managedWildcardReply = await managedWildcardBackground.onMessage(
    request('managed-wildcard'),
    sender('managed-wildcard-document')
);
assert.deepEqual(Array.from(managedWildcardReply.plainSelectors), []);
assert.deepEqual(managedWildcardBackground.calls.injectCustomFilters, []);

const atomicLiveSnapshot = {
    'site.example.test': [ '#one-read-committed' ],
};
const unjournaled = loadBackground({ localState: atomicLiveSnapshot });
await unjournaled.onMessage(
    request('unjournaled-atomic-snapshot'),
    sender('unjournaled-atomic-document')
);
assert.deepEqual(
    unjournaled.calls.injectCustomFilters[0].storageSnapshot,
    atomicLiveSnapshot
);
assert.equal(unjournaled.calls.localSnapshot, 1);
assert.deepEqual(unjournaled.calls.localRead, []);

const malformedJournal = loadBackground({
    journal: { version: 1, id: 'broken', phase: 'applying' },
});
const malformedJournalReply = await malformedJournal.onMessage(
    request('malformed-journal'),
    sender('malformed-journal-document')
);
assert.equal(malformedJournalReply.ok, false);
assert.match(malformedJournalReply.error, /restore journal/);
assert.deepEqual(malformedJournal.calls.injectCustomFilters, []);

const exactDocumentMessages = loadBackground();
await exactDocumentMessages.onMessage(
    { what: 'insertCSS', css: '#insert{}' },
    sender('css-document', 'https://example.test/frame', 4)
);
await exactDocumentMessages.onMessage(
    { what: 'removeCSS', css: '#remove{}' },
    sender('css-document', 'https://example.test/frame', 4)
);
const proceduralReply = await exactDocumentMessages.onMessage({
    what: 'injectCSSProceduralAPI',
    requestId: 'procedural-fallback',
}, sender('css-document', 'https://example.test/frame', 4));
assert.equal(proceduralReply.ok, true);
assert.deepEqual(
    exactDocumentMessages.calls.insertCSS[0].target,
    { tabId: 12, documentIds: [ 'css-document' ] }
);
assert.deepEqual(
    exactDocumentMessages.calls.removeCSS[0].target,
    { tabId: 12, documentIds: [ 'css-document' ] }
);
assert.deepEqual(
    exactDocumentMessages.calls.executeScript[0].target,
    { tabId: 12, documentIds: [ 'css-document' ] }
);
assert.deepEqual(exactDocumentMessages.calls.executeScript[0].files, [
    '/js/scripting/css-api.js',
    '/js/scripting/css-procedural-api.js',
]);

const proceduralError = loadBackground({
    executeResults: [ { documentId: 'css-document', error: 'injection failed' } ],
});
const proceduralErrorReply = await proceduralError.onMessage({
    what: 'injectCSSProceduralAPI',
    requestId: 'procedural-error',
}, sender('css-document'));
assert.equal(proceduralErrorReply.ok, false);
assert.match(proceduralErrorReply.error, /injection failed/);

const sleep = delay => new Promise(resolve => setTimeout(resolve, delay));

function cssUserSandbox(responder, options = {}) {
    const messages = [];
    const insertions = [];
    const listeners = new Map();
    const storageGets = [];
    const sandbox = {
        URL,
        clearTimeout,
        console,
        crypto: { randomUUID: ( ) => options.requestId ?? 'css-user-request' },
        Date,
        document: {
            baseURI: options.baseURI,
            location: {
                hostname: options.locationHostname ?? 'example.test',
                origin: options.locationOrigin,
                href: options.locationHref,
                ancestorOrigins: options.ancestorOrigins,
            },
        },
        Math,
        setTimeout(callback, delay) {
            const adjusted = delay === 2000 && options.shortTimeout
                ? 10
                : delay;
            return setTimeout(callback, adjusted);
        },
        addEventListener(type, listener) {
            listeners.set(type, listener);
        },
        removeEventListener(type, listener) {
            if ( listeners.get(type) === listener ) {
                listeners.delete(type);
            }
        },
    };
    sandbox.self = sandbox;
    sandbox.top = options.subframe ? {} : sandbox;
    sandbox.parent = options.subframe
        ? options.parentLocation
            ? { location: options.parentLocation }
            : {}
        : sandbox;
    sandbox.cssAPI = {
        insert(css) {
            insertions.push(css);
        },
    };
    if ( options.ProceduralFiltererAPI ) {
        sandbox.ProceduralFiltererAPI = options.ProceduralFiltererAPI;
    }
    sandbox.chrome = {
        runtime: {
            sendMessage(message) {
                messages.push(structuredClone(message));
                return responder(message, sandbox);
            },
        },
        storage: {
            local: {
                get(keys) {
                    storageGets.push(structuredClone(keys));
                    if ( options.storageError ) {
                        return Promise.reject(options.storageError);
                    }
                    return Promise.resolve(structuredClone(
                        options.localState ?? {}
                    ));
                },
            },
        },
    };
    const context = vm.createContext(sandbox);
    new vm.Script(cssUserSource, {
        filename: 'js/scripting/css-user.js',
    }).runInContext(context);
    return {
        context,
        insertions,
        listeners,
        messages,
        sandbox,
        storageGets,
    };
}

const successfulAck = (message, selectors = [ '#typed' ]) => ({
    ok: true,
    schema: 1,
    requestId: message.requestId,
    plainSelectors: selectors,
    proceduralSelectors: [],
});

const unprovenParentRequest = cssUserSandbox(
    message => Promise.resolve(successfulAck(message)),
    {
        baseURI: 'https://spoofed-base.test/parent',
        locationHostname: '',
        locationOrigin: 'null',
        requestId: 'about-srcdoc-request',
    }
);
await sleep(30);
assert.deepEqual(unprovenParentRequest.messages, []);
assert.deepEqual(unprovenParentRequest.storageGets, []);
assert.deepEqual(unprovenParentRequest.insertions, []);

const blobOriginRequest = cssUserSandbox(
    message => Promise.resolve(successfulAck(message)),
    {
        baseURI: 'blob:https://blob-owner.test/fallback',
        locationHostname: '',
        locationOrigin: 'https://blob-owner.test',
        ancestorOrigins: [ 'https://parent.example.test' ],
        parentLocation: {
            origin: 'https://parent.example.test',
            href: 'https://parent.example.test/frame-host',
        },
        requestId: 'blob-request',
        subframe: true,
        localState: {
            filteringModeDetails: optimalModes,
            'site.parent.example.test': [ '#blob-parent-direct' ],
            'site.blob-owner.test': [ '#must-not-select-blob-origin' ],
        },
    }
);
await sleep(30);
assert.deepEqual(blobOriginRequest.messages, []);
assert.deepEqual(blobOriginRequest.insertions, [
    '#blob-parent-direct{display:none!important;}',
]);
assert.deepEqual(blobOriginRequest.storageGets, [ [
    'floorp.settingsRestoreJournal.v1',
    'floorp.customFilterMutationJournal.v1',
    'filteringModeDetails',
    'admin.defaultFiltering',
    'admin.noFiltering',
    'site.parent.example.test',
    'site.example.test',
    'site.test',
] ]);

const mismatchedParentAuthority = cssUserSandbox(
    ( ) => Promise.reject(new Error('background must not be used')),
    {
        locationHostname: '',
        locationOrigin: 'https://blob-owner.test',
        ancestorOrigins: [ 'https://parent-a.test' ],
        parentLocation: {
            origin: 'https://parent-b.test',
            href: 'https://parent-b.test/',
        },
        subframe: true,
    }
);
await sleep(30);
assert.deepEqual(mismatchedParentAuthority.storageGets, []);
assert.deepEqual(mismatchedParentAuthority.messages, []);
assert.deepEqual(mismatchedParentAuthority.insertions, []);

const opaqueImmediateParent = cssUserSandbox(
    ( ) => Promise.reject(new Error('background must not be used')),
    {
        locationHostname: '',
        locationOrigin: 'null',
        ancestorOrigins: [ 'null', 'https://grandparent.test' ],
        parentLocation: { origin: 'null', href: 'about:blank' },
        subframe: true,
    }
);
await sleep(30);
assert.deepEqual(opaqueImmediateParent.storageGets, []);
assert.deepEqual(opaqueImmediateParent.messages, []);
assert.deepEqual(opaqueImmediateParent.insertions, []);

const directOriginFallback = cssUserSandbox(
    ( ) => Promise.reject(new Error('background must not be used')),
    {
        baseURI: 'https://spoofed-base.test/',
        locationHostname: '',
        locationOrigin: 'null',
        ancestorOrigins: [ 'https://child.example.test' ],
        parentLocation: {
            origin: 'https://child.example.test',
            href: 'https://child.example.test/frame-host',
        },
        requestId: 'direct-origin-fallback',
        subframe: true,
        localState: {
            filteringModeDetails: optimalModes,
            'site.child.example.test': [ '#child' ],
            'site.example.test': [ '#parent', '+js(noop)' ],
        },
    }
);
await sleep(30);
assert.deepEqual(directOriginFallback.messages, []);
assert.deepEqual(directOriginFallback.insertions, [
    '#child,\n#parent{display:none!important;}',
]);
assert.deepEqual(directOriginFallback.storageGets[0], [
    'floorp.settingsRestoreJournal.v1',
    'floorp.customFilterMutationJournal.v1',
    'filteringModeDetails',
    'admin.defaultFiltering',
    'admin.noFiltering',
    'site.child.example.test',
    'site.example.test',
    'site.test',
]);

// A live custom-filter refresh does not carry the idle marker, but must still
// use the trusted direct path in an already committed origin-fallback frame.
new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
}).runInContext(directOriginFallback.context);
await sleep(30);
assert.equal(directOriginFallback.storageGets.length, 2);
assert.equal(directOriginFallback.messages.length, 0);
assert.equal(directOriginFallback.insertions.length, 2);

directOriginFallback.sandbox.floorpCSSUserIdleReplay = true;
new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
}).runInContext(directOriginFallback.context);
await sleep(30);
assert.equal(directOriginFallback.storageGets.length, 3);
assert.equal(directOriginFallback.messages.length, 0);
assert.equal(directOriginFallback.insertions.length, 3);

const directModeNone = cssUserSandbox(
    ( ) => Promise.resolve({ ok: true }),
    {
        locationHostname: '',
        locationOrigin: 'null',
        ancestorOrigins: [ 'https://disabled.example.test' ],
        subframe: true,
        localState: {
            filteringModeDetails: {
                none: [ 'disabled.example.test' ],
                basic: [],
                optimal: [ 'all-urls' ],
                complete: [],
            },
            'site.example.test': [ '#must-not-apply' ],
        },
    }
);
await sleep(30);
assert.deepEqual(directModeNone.messages, []);
assert.deepEqual(directModeNone.insertions, []);
assert.equal(directModeNone.sandbox.customFilters.ok, true);

const malformedDirectJournal = cssUserSandbox(
    message => Promise.resolve(successfulAck(message, [ '#unsafe-fallback' ])),
    {
        locationHostname: '',
        locationOrigin: 'null',
        ancestorOrigins: [ 'https://example.test' ],
        subframe: true,
        localState: {
            filteringModeDetails: optimalModes,
            'site.example.test': [ '#live-uncommitted' ],
            'floorp.settingsRestoreJournal.v1': {
                version: 1,
                id: 'malformed',
                phase: 'applying',
            },
        },
    }
);
await sleep(30);
assert.deepEqual(malformedDirectJournal.messages, []);
assert.deepEqual(malformedDirectJournal.insertions, []);

const invalidCustomMutationPhase = cssUserSandbox(
    ( ) => Promise.reject(new Error('background must not be used')),
    {
        locationHostname: '',
        locationOrigin: 'null',
        ancestorOrigins: [ 'https://example.test' ],
        subframe: true,
        localState: {
            filteringModeDetails: optimalModes,
            'site.example.test': [ '#live-uncommitted' ],
            'floorp.customFilterMutationJournal.v1': {
                version: 1,
                id: 'invalid-custom-filter-phase',
                phase: 'committingForeground',
                beforeLocal: {
                    'site.example.test': [ '#must-not-apply' ],
                },
            },
        },
    }
);
await sleep(30);
assert.deepEqual(invalidCustomMutationPhase.messages, []);
assert.deepEqual(invalidCustomMutationPhase.insertions, []);

const directCommittedJournal = cssUserSandbox(
    ( ) => Promise.reject(new Error('background must not be used')),
    {
        locationHostname: '',
        locationOrigin: 'null',
        ancestorOrigins: [ 'https://example.test' ],
        subframe: true,
        localState: {
            filteringModeDetails: optimalModes,
            'site.example.test': [ '#live-uncommitted' ],
            'floorp.settingsRestoreJournal.v1': {
                version: 1,
                id: 'restore-applying',
                phase: 'applying',
                beforeLocal: {
                    filteringModeDetails: optimalModes,
                    'site.example.test': [ '#last-committed' ],
                },
            },
        },
    }
);
await sleep(30);
assert.deepEqual(directCommittedJournal.insertions, [
    '#last-committed{display:none!important;}',
]);

for ( const phase of [ 'applying', 'committingForeground', 'rollingBack' ] ) {
    const directManagedDisable = cssUserSandbox(
        ( ) => Promise.reject(new Error('background must not be used')),
        {
            locationHostname: '',
            locationOrigin: 'null',
            ancestorOrigins: [ 'https://example.test' ],
            subframe: true,
            localState: {
                filteringModeDetails: optimalModes,
                'admin.defaultFiltering': { data: 'none' },
                'admin.noFiltering': { data: [ 'example.test' ] },
                'site.example.test': [ '#live-uncommitted' ],
                'floorp.settingsRestoreJournal.v1': {
                    version: 1,
                    id: `direct-managed-disable-${phase}`,
                    phase,
                    beforeLocal: {
                        filteringModeDetails: optimalModes,
                        'admin.defaultFiltering': { data: 'optimal' },
                        'admin.noFiltering': { data: [] },
                        'site.example.test': [ '#last-committed' ],
                    },
                },
            },
        }
    );
    await sleep(30);
    assert.deepEqual(directManagedDisable.messages, []);
    assert.deepEqual(directManagedDisable.insertions, []);

    const directManagedRelax = cssUserSandbox(
        ( ) => Promise.reject(new Error('background must not be used')),
        {
            locationHostname: '',
            locationOrigin: 'null',
            ancestorOrigins: [ 'https://example.test' ],
            subframe: true,
            localState: {
                filteringModeDetails: {
                    none: [ 'all-urls' ],
                    basic: [],
                    optimal: [],
                    complete: [],
                },
                'admin.defaultFiltering': { data: 'optimal' },
                'admin.noFiltering': { data: [] },
                'site.example.test': [ '#live-uncommitted' ],
                'floorp.settingsRestoreJournal.v1': {
                    version: 1,
                    id: `direct-managed-relax-${phase}`,
                    phase,
                    beforeLocal: {
                        filteringModeDetails: optimalModes,
                        'admin.defaultFiltering': { data: 'none' },
                        'admin.noFiltering': { data: [ 'example.test' ] },
                        'site.example.test': [ '#last-committed' ],
                    },
                },
            },
        }
    );
    await sleep(30);
    assert.deepEqual(directManagedRelax.messages, []);
    assert.deepEqual(directManagedRelax.insertions, [
        '#last-committed{display:none!important;}',
    ]);
}

const directLocationRequest = cssUserSandbox(
    message => Promise.resolve(successfulAck(message)),
    {
        baseURI: 'https://spoofed-base.test/',
        locationHostname: 'example.test',
        locationOrigin: 'https://example.test',
        requestId: 'direct-location-request',
    }
);
await sleep(30);
assert.equal(directLocationRequest.messages[0].hostname, 'example.test');

directLocationRequest.sandbox.floorpCSSUserIdleReplay = true;
new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
}).runInContext(directLocationRequest.context);
await sleep(30);
assert.equal(
    directLocationRequest.messages.length,
    1,
    'the idle registration must not duplicate an ordinary HTTP(S) activation'
);

unprovenParentRequest.sandbox.floorpCSSUserIdleReplay = true;
new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
}).runInContext(unprovenParentRequest.context);
await sleep(30);
assert.equal(
    unprovenParentRequest.messages.length,
    0,
    'an idle replay without immediate-parent authority must remain fail-closed'
);
assert.deepEqual(unprovenParentRequest.storageGets, []);

let undefinedAttempts = 0;
const undefinedRetry = cssUserSandbox(message => {
    undefinedAttempts += 1;
    return Promise.resolve(
        undefinedAttempts === 1 ? undefined : successfulAck(message)
    );
});
await sleep(160);
assert.equal(undefinedRetry.messages.length, 2);
assert.equal(undefinedRetry.messages[0].schema, 1);
assert.equal(
    undefinedRetry.messages[0].requestId,
    undefinedRetry.messages[1].requestId
);
assert.deepEqual(undefinedRetry.insertions, [
    '#typed{display:none!important;}',
]);
assert.equal(undefinedRetry.listeners.has('pagereveal'), false);

const subframeUndefined = cssUserSandbox(
    ( ) => Promise.resolve(undefined),
    { subframe: true }
);
await sleep(160);
assert.equal(subframeUndefined.messages.length, 1);
assert.equal(subframeUndefined.listeners.has('pagereveal'), true);

for ( const [ label, responder ] of [
    [ 'rejection', ( ) => Promise.reject(new Error('rejected')) ],
    [ 'error response', ( ) => Promise.resolve({ error: 'failed' }) ],
    [ 'typed error', message => Promise.resolve({
        ok: false,
        schema: 1,
        requestId: message.requestId,
        error: 'failed',
    }) ],
    [ 'malformed success', message => Promise.resolve({
        ok: true,
        schema: 1,
        requestId: message.requestId,
        plainSelectors: '#not-an-array',
        proceduralSelectors: [],
    }) ],
] ) {
    const failed = cssUserSandbox(responder, { requestId: label });
    await sleep(30);
    assert.equal(failed.messages.length, 1, `${label} must not auto-resend`);
    assert.equal(failed.sandbox.customFilters, undefined);
    assert.equal(failed.listeners.has('pagereveal'), true);
}

const never = new Promise(( ) => {});
const timedOut = cssUserSandbox(
    ( ) => never,
    { shortTimeout: true, requestId: 'timeout-request' }
);
await sleep(30);
assert.equal(timedOut.messages.length, 1);
assert.equal(timedOut.listeners.has('pagereveal'), true);
void timedOut.listeners.get('pagereveal')();
void timedOut.listeners.get('pagereveal')();
await sleep(40);
assert.equal(
    timedOut.messages.length,
    1,
    'a timed-out but unsettled send must be reused, not duplicated'
);

let resolveLateReply;
let lateRequest;
const lateReplyPromise = new Promise(resolve => {
    resolveLateReply = resolve;
});
const lateReply = cssUserSandbox(message => {
    lateRequest = message;
    return lateReplyPromise;
}, { shortTimeout: true, requestId: 'late-reply-request' });
await sleep(30);
assert.equal(lateReply.messages.length, 1);
resolveLateReply(successfulAck(lateRequest, [ '#late-reply' ]));
await sleep(30);
assert.equal(
    lateReply.messages.length,
    1,
    'a late valid reply must be consumed without a second send'
);
assert.equal(lateReply.sandbox.customFilters.ok, true);
assert.deepEqual(lateReply.insertions, [
    '#late-reply{display:none!important;}',
]);

let malformedThenSuccess = false;
const pageRevealRetry = cssUserSandbox(message => Promise.resolve(
    malformedThenSuccess ? successfulAck(message, [ '#page-reveal' ]) : {}
));
await sleep(30);
assert.equal(pageRevealRetry.listeners.has('pagereveal'), true);
malformedThenSuccess = true;
await pageRevealRetry.listeners.get('pagereveal')();
await sleep(10);
assert.equal(pageRevealRetry.messages.length, 2);
assert.equal(pageRevealRetry.sandbox.customFilters.ok, true);
assert.equal(pageRevealRetry.listeners.has('pagereveal'), false);

class ProceduralFiltererAPI {
    addDeclaratives(selectors) {
        this.declaratives = selectors;
    }
    addProcedurals(selectors) {
        this.procedurals = selectors;
    }
}
const proceduralPreloaded = cssUserSandbox(message => {
    assert.equal(message.what, 'injectCustomFilters');
    return Promise.resolve({
        ok: true,
        schema: 1,
        requestId: message.requestId,
        plainSelectors: [],
        proceduralSelectors: [ '{"cssable":false,"raw":"preloaded"}' ],
    });
}, { ProceduralFiltererAPI });
await sleep(30);
assert.deepEqual(
    proceduralPreloaded.messages.map(message => message.what),
    [ 'injectCustomFilters' ]
);
assert.equal(
    proceduralPreloaded.sandbox.customProceduralFiltererAPI.procedurals[0].raw,
    'preloaded'
);

const proceduralFallback = cssUserSandbox((message, sandbox) => {
    if ( message.what === 'injectCustomFilters' ) {
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            plainSelectors: [],
            proceduralSelectors: [ '{"cssable":false,"raw":"p"}' ],
        });
    }
    assert.equal(message.what, 'injectCSSProceduralAPI');
    sandbox.ProceduralFiltererAPI = ProceduralFiltererAPI;
    return Promise.resolve(successfulAck(message, []));
});
await sleep(30);
assert.deepEqual(
    proceduralFallback.messages.map(message => message.what),
    [ 'injectCustomFilters', 'injectCSSProceduralAPI' ]
);
assert.equal(
    proceduralFallback.sandbox.customProceduralFiltererAPI.procedurals[0].raw,
    'p'
);

const apiListeners = new Map();
const sharedDocumentElement = {};
const apiReplaySandbox = {
    console,
    document: {
        documentElement: sharedDocumentElement,
        location: { hostname: '' },
    },
    performance: { timeOrigin: 17 },
    addEventListener(type, listener) {
        apiListeners.set(type, listener);
    },
    removeEventListener(type, listener) {
        if ( apiListeners.get(type) === listener ) {
            apiListeners.delete(type);
        }
    },
    chrome: {
        runtime: {
            sendMessage() {
                return Promise.resolve();
            },
        },
    },
};
apiReplaySandbox.self = apiReplaySandbox;
const apiReplayContext = vm.createContext(apiReplaySandbox);
const cssAPIScript = new vm.Script(cssAPISource, {
    filename: 'js/scripting/css-api.js',
});
const proceduralAPIScript = new vm.Script(proceduralAPISource, {
    filename: 'js/scripting/css-procedural-api.js',
});
const idlePreludeScript = new vm.Script(idlePreludeSource, {
    filename: 'js/scripting/css-user-idle-prelude.js',
});
const idleMarkerScript = new vm.Script(idleMarkerSource, {
    filename: 'js/scripting/css-user-idle.js',
});

cssAPIScript.runInContext(apiReplayContext);
proceduralAPIScript.runInContext(apiReplayContext);
const transientCSSAPI = apiReplaySandbox.cssAPI;
const transientProceduralAPI = apiReplaySandbox.ProceduralFiltererAPI;

idlePreludeScript.runInContext(apiReplayContext);
assert.equal(apiReplaySandbox.floorpCSSUserAPIIdleReplay, true);
cssAPIScript.runInContext(apiReplayContext);
proceduralAPIScript.runInContext(apiReplayContext);
assert.notEqual(
    apiReplaySandbox.cssAPI,
    transientCSSAPI,
    'origin-fallback idle replay must rebuild cssAPI for the final document'
);
assert.notEqual(
    apiReplaySandbox.ProceduralFiltererAPI,
    transientProceduralAPI,
    'origin-fallback idle replay must rebuild the procedural DOM engine'
);
const finalCSSAPI = apiReplaySandbox.cssAPI;
const finalProceduralAPI = apiReplaySandbox.ProceduralFiltererAPI;
idleMarkerScript.runInContext(apiReplayContext);
assert.equal(apiReplaySandbox.floorpCSSUserIdleReplay, true);
assert.equal(apiReplaySandbox.floorpCSSUserAPIIdleReplay, undefined);

apiReplaySandbox.document.location.hostname = 'example.test';
idlePreludeScript.runInContext(apiReplayContext);
cssAPIScript.runInContext(apiReplayContext);
proceduralAPIScript.runInContext(apiReplayContext);
assert.equal(apiReplaySandbox.cssAPI, finalCSSAPI);
assert.equal(apiReplaySandbox.ProceduralFiltererAPI, finalProceduralAPI);

console.log('uBO custom-filter injection tests passed');
