import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 11 ) {
    throw new Error(
        'usage: node ubol_custom_filter_injection_test.mjs ' +
        '<background.js> <filter-manager.js> <picker-ui.js> <css-user.js> ' +
        '<css-api.js> <css-procedural-api.js> <css-user-idle-prelude.js> ' +
        '<css-user-idle.js> <css-user-terminate.js>'
    );
}

const [
    backgroundPath,
    filterManagerPath,
    pickerUIPath,
    cssUserPath,
    cssAPIPath,
    proceduralAPIPath,
    idlePreludePath,
    idleMarkerPath,
    cssUserTerminatePath,
] = process.argv.slice(2);
const [
    backgroundSource,
    filterManagerSource,
    pickerUISource,
    cssUserSource,
    cssAPISource,
    proceduralAPISource,
    idlePreludeSource,
    idleMarkerSource,
    cssUserTerminateSource,
] =
    await Promise.all([
        readFile(backgroundPath, 'utf8'),
        readFile(filterManagerPath, 'utf8'),
        readFile(pickerUIPath, 'utf8'),
        readFile(cssUserPath, 'utf8'),
        readFile(cssAPIPath, 'utf8'),
        readFile(proceduralAPIPath, 'utf8'),
        readFile(idlePreludePath, 'utf8'),
        readFile(idleMarkerPath, 'utf8'),
        readFile(cssUserTerminatePath, 'utf8'),
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
                    const recorded = { ...details };
                    if ( typeof recorded.func === 'function' ) {
                        recorded.func = recorded.func.name;
                    }
                    calls.executeScript.push(structuredClone(recorded));
                    if ( options.executeScript ) {
                        return options.executeScript(details);
                    }
                    const documentId = details.target.documentIds[0];
                    if ( Array.isArray(details.files) ) {
                        return Promise.resolve(details.files.map(( ) => ({
                            documentId,
                        })));
                    }
                    const terminated = details.func?.name ===
                        'probeTerminatedCustomFilters';
                    return Promise.resolve([ {
                        documentId,
                        result: terminated
                            ? {
                                ok: true,
                                schema: 1,
                                terminated: true,
                                documentId,
                            }
                            : {
                                ok: true,
                                schema: 1,
                                committed: true,
                                documentId,
                            },
                    } ]);
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
        `assertCommittedCustomFilterInjection,` +
        `assertSuccessfulScriptInjection,` +
        `committedCustomFilterMutationSnapshot,` +
        `committedSettingsRestoreSnapshot,` +
        `customFilterStorageKeys,customFiltersFromSnapshot,` +
        `customFilteringEnabledFromStorageSnapshot,injectCustomFilters,` +
        `mutateCustomFiltersAtomically,recoverCustomFilterMutation,` +
        `registerCustomFilters,replaceAllCustomFiltersAtomically,` +
        `replaceCustomFiltersAtomically,startCustomFilters,` +
        `terminateCustomFilters};`,
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
    [ '/js/scripting/css-api.js', '/js/scripting/css-user.js' ],
    'plain-only custom filters must preload the native acknowledgement API'
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

const liveStart = loadFilterManager();
await liveStart.api.startCustomFilters(19, 3, 'executed-document');
assert.deepEqual(liveStart.calls.executeScript[0], {
    files: [
        '/js/scripting/css-api.js',
        '/js/scripting/css-procedural-api.js',
        '/js/scripting/css-user.js',
    ],
    injectImmediately: true,
    target: { tabId: 19, documentIds: [ 'executed-document' ] },
});
assert.equal(liveStart.calls.executeScript.length, 2);
assert.deepEqual(liveStart.calls.executeScript[1].target, {
    tabId: 19,
    documentIds: [ 'executed-document' ],
});

function pickerCreateHandler(options = {}) {
    const startMarker = 'async function onCreateClicked() {';
    const start = pickerUISource.indexOf(startMarker);
    const end = pickerUISource.indexOf(
        '\n}\n\n/' + '*'.repeat(78) + '/',
        start
    );
    assert.notEqual(start, -1, 'picker create handler must exist');
    assert.notEqual(end, -1, 'picker create handler boundary must exist');
    const textarea = { value: '#picker-filter' };
    const calls = { close: 0, mutation: 0, start: 0, terminate: 0 };
    const sandbox = {
        dom: {
            cl: {
                remove() {},
            },
            root: {},
        },
        qs$(selector) {
            assert.equal(selector, 'textarea');
            return textarea;
        },
        quitPicker() {
            calls.close += 1;
        },
        toolOverlay: {
            url: { hostname: 'picker.example' },
            postMessage(message) {
                if ( message.what === 'terminateCustomFilters' ) {
                    calls.terminate += 1;
                    return options.terminate();
                }
                assert.equal(message.what, 'startCustomFilters');
                calls.start += 1;
                return options.start();
            },
            sendMessage(message) {
                assert.equal(message.what, 'addCustomFilters');
                calls.mutation += 1;
                return Promise.resolve(true);
            },
        },
        validateSelector(selector) {
            return selector;
        },
    };
    sandbox.self = sandbox;
    const context = vm.createContext(sandbox);
    new vm.Script(
        `${pickerUISource.slice(start, end + 2)}\n` +
        'self.__onCreateClicked = onCreateClicked;',
        { filename: 'js/picker-ui.js#create' }
    ).runInContext(context);
    return { calls, run: sandbox.__onCreateClicked };
}

const injectionFailures = [
    [ 'resolved error', ( ) => Promise.resolve([ { error: 'world failed' } ]) ],
    [ 'empty result', ( ) => Promise.resolve([]) ],
    [ 'malformed result', ( ) => Promise.resolve([ null ]) ],
    [ 'runtime rejection', ( ) => Promise.reject(new Error('runtime failed')) ],
];
for ( const [ label, failedInjection ] of injectionFailures ) {
    const terminateFailure = loadFilterManager({
        executeScript: failedInjection,
    });
    const terminatePicker = pickerCreateHandler({
        terminate: ( ) => terminateFailure.api.terminateCustomFilters(
            19, 3, 'executed-document'
        ),
        start: ( ) => Promise.resolve(),
    });
    await assert.rejects(terminatePicker.run(), undefined, label);
    assert.equal(
        terminatePicker.calls.mutation,
        0,
        `${label} termination must stop picker storage mutation`
    );
    assert.equal(
        terminatePicker.calls.close,
        0,
        `${label} termination must keep the picker open`
    );

    let injectionCount = 0;
    const startFailure = loadFilterManager({
        executeScript(details) {
            injectionCount += 1;
            if ( injectionCount === 1 ) {
                return Promise.resolve([ {
                    documentId: 'terminated-document',
                } ]);
            }
            if ( injectionCount === 2 ) {
                return Promise.resolve([ {
                    documentId: 'terminated-document',
                    result: {
                        ok: true,
                        schema: 1,
                        terminated: true,
                        documentId: 'terminated-document',
                    },
                } ]);
            }
            return failedInjection(details);
        },
    });
    const startPicker = pickerCreateHandler({
        terminate: ( ) => startFailure.api.terminateCustomFilters(
            19, 3, 'terminated-document'
        ),
        start: ( ) => startFailure.api.startCustomFilters(
            19, 3, 'terminated-document'
        ),
    });
    await assert.rejects(startPicker.run(), undefined, label);
    assert.equal(
        startPicker.calls.mutation,
        1,
        `${label} start failure occurs only after the requested filter is saved`
    );
    assert.equal(
        startPicker.calls.close,
        0,
        `${label} start failure must keep the picker open`
    );
}

const uncommittedStart = loadFilterManager({
    executeScript: ( ) => Promise.resolve([ {
        documentId: 'uncommitted-document',
        result: { ok: false, schema: 1, committed: false },
    } ]),
});
const uncommittedStartPicker = pickerCreateHandler({
    terminate: ( ) => Promise.resolve(),
    start: ( ) => uncommittedStart.api.startCustomFilters(
        19, 3, 'uncommitted-document'
    ),
});
await assert.rejects(
    uncommittedStartPicker.run(),
    /did not commit custom filters/
);
assert.equal(uncommittedStartPicker.calls.mutation, 1);
assert.equal(
    uncommittedStartPicker.calls.close,
    0,
    'native CSS commit failure must keep the picker open after storage save'
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
assert.deepEqual(
    filter.calls.insertCSS,
    [],
    'background selector acknowledgement must not pre-insert duplicate CSS'
);
assert.deepEqual(
    filter.calls.executeScript,
    [],
    'the selector acknowledgement must not depend on dynamic injection into ' +
    'an origin-fallback frame'
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
                    if ( options.insertCSS ) {
                        return options.insertCSS(details);
                    }
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
const exactScopeAttribute =
    'data-floorp-ubol-0123456789abcdef0123456789abcdef';
const exactScopeCanary =
    '--floorp-ubol-canary-0123456789abcdef0123456789abcdef';
const exactScopeCanaryValue =
    'floorp-fedcba9876543210fedcba9876543210';
const exactScopeWrapper = `:where(:root[${exactScopeAttribute}])`;
const exactScopedCSS = selector =>
    `${exactScopeWrapper} {\n` +
    `${exactScopeCanary}: ${exactScopeCanaryValue} !important;\n` +
    `}\n${exactScopeWrapper} :is(${selector}),\n` +
    `${exactScopeWrapper}:is(${selector}) { display: none !important; }`;
const exactNestedScopedCSS = selector =>
    `${exactScopeWrapper} {\n` +
    `${exactScopeCanary}: ${exactScopeCanaryValue} !important;\n` +
    `& :is(${selector}),\n&:is(${selector}) { display: none !important; }\n}`;
const exactScopedInsert = exactScopedCSS('#insert');
const insertReply = await exactDocumentMessages.onMessage(
    {
        what: 'insertCSS',
        schema: 1,
        requestId: 'insert-request',
        css: exactScopedInsert,
        scopeAttribute: exactScopeAttribute,
        scopeCanary: exactScopeCanary,
        scopeCanaryValue: exactScopeCanaryValue,
        expectedDocumentId: 'css-document',
        expectedFrameId: 4,
    },
    sender('css-document', 'https://example.test/frame', 4)
);
assert.deepEqual(structuredClone(insertReply), {
    ok: true,
    schema: 1,
    requestId: 'insert-request',
    documentId: 'css-document',
    frameId: 4,
    ensured: true,
});
const rejectedLegacySubframe = await exactDocumentMessages.onMessage(
    { what: 'insertCSS', css: '#legacy-insert{}' },
    sender('legacy-css-document', 'https://example.test/frame', 4)
);
assert.equal(rejectedLegacySubframe.ok, false);
await exactDocumentMessages.onMessage(
    { what: 'insertCSS', css: '#legacy-insert{}' },
    sender('legacy-css-document', 'https://example.test/frame', 0)
);
assert.equal(
    exactDocumentMessages.calls.insertCSS[1].css,
    '#legacy-insert{}',
    'legacy picker/tool-overlay insertCSS messages must remain supported'
);
assert.equal(
    exactDocumentMessages.calls.insertCSS[1].target.documentIds[0],
    'legacy-css-document'
);
await exactDocumentMessages.onMessage(
    { what: 'removeCSS', css: '#remove{}' },
    sender('css-document', 'https://example.test/frame', 0)
);
const structuredRemoveCSS = exactScopedCSS('#structured-remove');
const structuredRemoveReply = await exactDocumentMessages.onMessage(
    {
        what: 'removeCSS',
        schema: 1,
        requestId: 'remove-request',
        css: structuredRemoveCSS,
        scopeAttribute: exactScopeAttribute,
        scopeCanary: exactScopeCanary,
        scopeCanaryValue: exactScopeCanaryValue,
        expectedDocumentId: 'css-document',
        expectedFrameId: 4,
    },
    sender('css-document', 'https://example.test/frame', 4)
);
assert.deepEqual(structuredClone(structuredRemoveReply), {
    ok: true,
    schema: 1,
    requestId: 'remove-request',
    documentId: 'css-document',
    frameId: 4,
});
assert.deepEqual(
    exactDocumentMessages.calls.insertCSS[1].target,
    { tabId: 12, documentIds: [ 'legacy-css-document' ] },
    'schema-less picker CSS must retain exact main-document targeting'
);
assert.deepEqual(
    exactDocumentMessages.calls.removeCSS[1].target,
    { tabId: 12, documentIds: [ 'css-document' ] },
    'schema-less picker cleanup must retain exact main-document targeting'
);
assert.deepEqual(
    exactDocumentMessages.calls.removeCSS[2].target,
    { tabId: 12, allFrames: true },
    'structured exact-payload cleanup must use the all-frame physical path'
);
const proceduralReply = await exactDocumentMessages.onMessage({
    what: 'injectCSSProceduralAPI',
    requestId: 'procedural-fallback',
}, sender('css-document', 'https://example.test/frame', 4));
assert.equal(proceduralReply.ok, true);
assert.deepEqual(
    exactDocumentMessages.calls.insertCSS[0].target,
    { tabId: 12, allFrames: true }
);
assert.deepEqual(
    exactDocumentMessages.calls.removeCSS[0].target,
    { tabId: 12, allFrames: true }
);
assert.deepEqual(
    exactDocumentMessages.calls.executeScript[0].target,
    { tabId: 12, documentIds: [ 'css-document' ] }
);
assert.deepEqual(exactDocumentMessages.calls.executeScript[0].files, [
    '/js/scripting/css-api.js',
    '/js/scripting/css-procedural-api.js',
]);

for ( const [ label, mutate ] of [
    [ 'scope breakout', css =>
        `${css}\n.global-leak { display:block!important; }` ],
    [ 'empty forgiving selector', css => css.replace(
        `${exactScopeWrapper} :is(#insert)`,
        `${exactScopeWrapper} :is()`
    ) ],
    [ 'global at-rule', css => css.replace(
        `${exactScopeWrapper} :is(#insert),`,
        '@font-face { font-family: leak; src: url(leak); }\n' +
            `${exactScopeWrapper} :is(#insert),`
    ) ],
    [ 'legacy qualified-rule nesting', ( ) => exactNestedScopedCSS('#insert') ],
    [ 'missing effect rules', ( ) =>
        `${exactScopeWrapper} {\n` +
        `${exactScopeCanary}: ${exactScopeCanaryValue} !important;\n}\n` ],
    [ 'comment-only effect body', ( ) =>
        `${exactScopeWrapper} {\n` +
        `${exactScopeCanary}: ${exactScopeCanaryValue} !important;\n}\n` +
        '/* no effect */' ],
    [ 'empty conditional effect body', ( ) =>
        `${exactScopeWrapper} {\n` +
        `${exactScopeCanary}: ${exactScopeCanaryValue} !important;\n}\n` +
        '@media (min-width: 1px) { /* no effect */ }' ],
] ) {
    const rejectedScope = loadBackground();
    const rejectedScopeReply = await rejectedScope.onMessage({
        what: 'insertCSS',
        schema: 1,
        requestId: `rejected-${label}`,
        css: mutate(exactScopedInsert),
        scopeAttribute: exactScopeAttribute,
        scopeCanary: exactScopeCanary,
        scopeCanaryValue: exactScopeCanaryValue,
        expectedDocumentId: 'css-document',
        expectedFrameId: 4,
    }, sender('css-document', 'https://example.test/frame', 4));
    assert.equal(rejectedScopeReply.ok, false, label);
    assert.deepEqual(rejectedScope.calls.insertCSS, [], label);
    assert.deepEqual(rejectedScope.calls.removeCSS, [], label);
}

const flatConditionalCSS =
    `${exactScopeWrapper} {\n` +
    `${exactScopeCanary}: ${exactScopeCanaryValue} !important;\n}\n` +
    `@media (min-width: 1px) {\n` +
    `${exactScopeWrapper} :is(#media),\n` +
    `${exactScopeWrapper}:is(:root) { color: red !important; }\n}\n` +
    `@supports selector(:has(*)) {\n` +
    `${exactScopeWrapper} :is(#supported) { visibility: hidden !important; }\n}\n` +
    `@container sidebar (width > 1px) {\n` +
    `${exactScopeWrapper} :is(#contained)::after { content: "ok" !important; }\n}`;
const flatConditionalMessages = loadBackground();
const flatConditionalReply = await flatConditionalMessages.onMessage({
    what: 'insertCSS',
    schema: 1,
    requestId: 'flat-conditional-request',
    css: flatConditionalCSS,
    scopeAttribute: exactScopeAttribute,
    scopeCanary: exactScopeCanary,
    scopeCanaryValue: exactScopeCanaryValue,
    expectedDocumentId: 'flat-conditional-document',
    expectedFrameId: 4,
}, sender(
    'flat-conditional-document',
    'https://example.test/frame',
    4
));
assert.equal(flatConditionalReply.ok, true);
assert.equal(flatConditionalReply.ensured, true);
assert.equal(flatConditionalMessages.calls.insertCSS.length, 1);
assert.equal(flatConditionalMessages.calls.insertCSS[0].css, flatConditionalCSS);

const rejectedCSSInsertion = loadBackground({
    insertCSS: ( ) => Promise.reject(new Error('transient CSS failure')),
});
const rejectedCSSReply = await rejectedCSSInsertion.onMessage({
    what: 'insertCSS',
    schema: 1,
    requestId: 'rejected-insert-request',
    css: exactScopedCSS('#retry'),
    scopeAttribute: exactScopeAttribute,
    scopeCanary: exactScopeCanary,
    scopeCanaryValue: exactScopeCanaryValue,
    expectedDocumentId: 'rejected-css-document',
    expectedFrameId: 0,
}, sender('rejected-css-document'));
assert.deepEqual(structuredClone(rejectedCSSReply), {
    ok: false,
    schema: 1,
    requestId: 'rejected-insert-request',
    documentId: 'rejected-css-document',
    frameId: 0,
    error: 'Error: transient CSS failure',
});

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
const waitUntil = async (predicate, timeout = 1000) => {
    const deadline = Date.now() + timeout;
    while ( predicate() === false && Date.now() < deadline ) {
        await sleep(5);
    }
};

function mockDocumentElement(options = {}) {
    const attributes = new Map();
    return {
        hasAttribute(name) { return attributes.has(name); },
        setAttribute(name, value) {
            const normalized = `${value}`;
            attributes.set(name, normalized);
            options.onSetAttribute?.(this, name, normalized);
        },
        removeAttribute(name) { attributes.delete(name); },
        attributeNames() { return Array.from(attributes.keys()); },
    };
}

function mockScopedComputedStyle(messages, enabled = ( ) => true) {
    return root => ({
        getPropertyValue(property) {
            const prefix = '--floorp-ubol-canary-';
            if ( property.startsWith(prefix) === false ) { return ''; }
            const token = property.slice(prefix.length);
            const attribute = `data-floorp-ubol-${token}`;
            const declaration = messages
                .filter(message => message.what === 'insertCSS')
                .map(message => new RegExp(
                    `${property.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}:\\s*` +
                    '([^;\\s]+)\\s*!important'
                ).exec(message.css ?? ''))
                .find(match => match !== null);
            return enabled(property, root) &&
                root?.hasAttribute?.(attribute) && declaration !== undefined
                ? declaration[1]
                : '';
        },
    });
}

function parsedCSSRules(source) {
    const rules = [];
    let start = 0;
    let quote = '';
    let comment = false;
    let depth = 0;
    for ( let index = 0; index < source.length; index += 1 ) {
        const char = source[index];
        const next = source[index + 1];
        if ( comment ) {
            if ( char === '*' && next === '/' ) {
                comment = false;
                index += 1;
            }
            continue;
        }
        if ( quote !== '' ) {
            if ( char === '\\' ) { index += 1; }
            else if ( char === quote ) { quote = ''; }
            continue;
        }
        if ( char === '/' && next === '*' ) {
            comment = true;
            index += 1;
            continue;
        }
        if ( char === '"' || char === "'" ) {
            quote = char;
            continue;
        }
        if ( char === '{' ) {
            depth += 1;
            continue;
        }
        if ( char === '}' ) {
            depth -= 1;
            if ( depth !== 0 ) { continue; }
            const cssText = source.slice(start, index + 1).trim();
            if ( cssText === '' ) { continue; }
            const opening = cssText.indexOf('{');
            const prefix = cssText.slice(0, opening).trim();
            const nested = cssText.slice(opening + 1, -1);
            if ( prefix.startsWith('@') ) {
                rules.push({ cssText, cssRules: parsedCSSRules(nested) });
            } else {
                let nestedStart = -1;
                let boundary = 0;
                let innerQuote = '';
                let innerComment = false;
                let parentheses = 0;
                let brackets = 0;
                for ( let inner = 0; inner < nested.length; inner += 1 ) {
                    const innerChar = nested[inner];
                    const innerNext = nested[inner + 1];
                    if ( innerComment ) {
                        if ( innerChar === '*' && innerNext === '/' ) {
                            innerComment = false;
                            inner += 1;
                        }
                        continue;
                    }
                    if ( innerQuote !== '' ) {
                        if ( innerChar === '\\' ) { inner += 1; }
                        else if ( innerChar === innerQuote ) { innerQuote = ''; }
                        continue;
                    }
                    if ( innerChar === '/' && innerNext === '*' ) {
                        innerComment = true;
                        inner += 1;
                        continue;
                    }
                    if ( innerChar === '"' || innerChar === "'" ) {
                        innerQuote = innerChar;
                        continue;
                    }
                    if ( innerChar === '\\' ) { inner += 1; continue; }
                    if ( innerChar === '(' ) { parentheses += 1; continue; }
                    if ( innerChar === ')' ) { parentheses -= 1; continue; }
                    if ( innerChar === '[' ) { brackets += 1; continue; }
                    if ( innerChar === ']' ) { brackets -= 1; continue; }
                    if ( parentheses !== 0 || brackets !== 0 ) { continue; }
                    if ( innerChar === ';' ) {
                        boundary = inner + 1;
                        continue;
                    }
                    if ( innerChar === '{' ) {
                        nestedStart = boundary;
                        break;
                    }
                }
                const declarations = (nestedStart === -1
                    ? nested
                    : nested.slice(0, nestedStart)).trim();
                const childRules = nestedStart === -1
                    ? []
                    : parsedCSSRules(nested.slice(nestedStart));
                rules.push({
                    cssText,
                    selectorText: prefix,
                    cssRules: childRules,
                    style: {
                        cssText: declarations,
                        getPropertyValue(name) {
                            for ( const declaration of declarations.split(';') ) {
                                const colon = declaration.indexOf(':');
                                if ( colon === -1 ) { continue; }
                                if ( declaration.slice(0, colon).trim() !== name ) {
                                    continue;
                                }
                                return declaration.slice(colon + 1)
                                    .replace(/\s*!important\s*$/i, '')
                                    .trim();
                            }
                            return '';
                        },
                        getPropertyPriority(name) {
                            for ( const declaration of declarations.split(';') ) {
                                const colon = declaration.indexOf(':');
                                if ( colon === -1 ) { continue; }
                                if ( declaration.slice(0, colon).trim() !== name ) {
                                    continue;
                                }
                                return /!important\s*$/i.test(
                                    declaration.slice(colon + 1)
                                ) ? 'important' : '';
                            }
                            return '';
                        },
                    },
                });
            }
            start = index + 1;
            continue;
        }
        if ( char === ';' && depth === 0 ) {
            const cssText = source.slice(start, index + 1).trim();
            if ( cssText !== '' ) { rules.push({ cssText }); }
            start = index + 1;
        }
    }
    if ( depth !== 0 || quote !== '' || comment ) {
        throw new SyntaxError('invalid mock CSS');
    }
    const remainder = source.slice(start).trim();
    if ( remainder !== '' ) { rules.push({ cssText: remainder }); }
    return rules;
}

class MockCSSStyleSheet {
    replaceSync(source) {
        this.cssRules = parsedCSSRules(source);
    }
}

// WKWebExtension insertCSS on iOS 26 can apply declarations from a top-level
// qualified rule while leaving qualified rules nested inside it ineffective.
// Recurse through supported conditional groups, but deliberately do not treat
// a CSSStyleRule's nested cssRules as native effects. This keeps the canary and
// the selector effects on opposite sides of the compatibility boundary which
// caused the release-acceptance regression.
function ios26TopLevelEffectRules(source) {
    const out = [];
    const visit = rules => {
        for ( const rule of rules ) {
            const text = `${rule.cssText ?? ''}`.trim();
            if ( text.startsWith('@') ) {
                visit(rule.cssRules ?? []);
                continue;
            }
            out.push(rule);
        }
    };
    visit(parsedCSSRules(source));
    return out;
}

const mockMutationObservers = [];
class MockMutationObserver {
    constructor(callback) {
        this.callback = callback;
        this.registrations = [];
        mockMutationObservers.push(this);
    }
    observe(target, options = {}) {
        this.registrations.push({ target, options });
    }
    disconnect() { this.registrations = []; }
    takeRecords() { return []; }
}

function cssUserSandbox(responder, options = {}) {
    const commits = [];
    const messages = [];
    const insertions = [];
    const insertionTransactions = [];
    const listeners = new Map();
    const storageGets = [];
    const identityMessages = [];
    let monotonicNow = 0;
    const locationHostname = options.locationHostname ?? 'example.test';
    const sandbox = {
        URL,
        clearTimeout,
        console,
        crypto: { randomUUID: ( ) => options.requestId ?? 'css-user-request' },
        Date,
        document: {
            baseURI: options.baseURI,
            location: {
                hostname: locationHostname,
                origin: options.locationOrigin ??
                    (locationHostname === '' ? 'null' : `https://${locationHostname}`),
                href: options.locationHref ??
                    (locationHostname === '' ? 'about:blank' :
                        `https://${locationHostname}/`),
                ancestorOrigins: options.ancestorOrigins,
            },
        },
        Math,
        performance: {
            now() {
                return options.realTime ? performance.now() : monotonicNow;
            },
        },
        setTimeout(callback, delay) {
            if ( options.realTime ) {
                const adjusted = delay === 2000 && options.shortTimeout
                    ? 10
                    : delay;
                return setTimeout(callback, adjusted);
            }
            return setTimeout(( ) => {
                monotonicNow += delay;
                callback();
            }, 0);
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
    if ( options.withoutCSSAPI !== true ) {
        const nativeDocumentId = options.documentId ?? 'css-user-document';
        const nativeFrameId = options.subframe ? 1 : 0;
        sandbox.cssAPI = {
            documentId: nativeDocumentId,
            frameId: nativeFrameId,
            suspendForIdentity(record) {
                this.pendingIdentity = record;
            },
            resumeForIdentity(record, documentId, frameId) {
                if (
                    this.pendingIdentity !== record ||
                    documentId !== nativeDocumentId ||
                    frameId !== nativeFrameId
                ) { return false; }
                this.pendingIdentity = undefined;
                sandbox.floorpCSSUserIdentityPendingRecord = undefined;
                return true;
            },
            bindDocumentId(documentId, frameId) {
                return documentId === nativeDocumentId &&
                    frameId === nativeFrameId;
            },
            insert(css, insertionOptions) {
                insertions.push(css);
                if ( options.cssInsertResponder ) {
                    return options.cssInsertResponder(css, insertionOptions);
                }
                return Promise.resolve({
                    ok: true,
                    schema: 1,
                    requestId: 'css-insert',
                    documentId: 'css-user-document',
                });
            },
            commit(generation) {
                commits.push(generation);
                if ( options.cssCommitResponder ) {
                    return options.cssCommitResponder(generation);
                }
                return Promise.resolve({
                    ok: true,
                    schema: 1,
                    requestId: null,
                    documentId: 'css-user-document',
                });
            },
            beginInsertionTransaction(generation, deadline) {
                const transaction = { deadline, generation };
                insertionTransactions.push({
                    event: 'begin',
                    transaction,
                });
                return transaction;
            },
            finishInsertionTransaction(transaction) {
                insertionTransactions.push({ event: 'finish', transaction });
            },
            rollbackInsertionTransaction(transaction) {
                insertionTransactions.push({ event: 'rollback', transaction });
                return { ok: true };
            },
            beginRecoveryWindow() {
                return Promise.resolve({ ok: true });
            },
            waitForRecovery() {
                return Promise.resolve({ ok: true });
            },
            replay() {
                return Promise.resolve({ ok: true });
            },
        };
    }
    if ( options.ProceduralFiltererAPI ) {
        sandbox.ProceduralFiltererAPI = options.ProceduralFiltererAPI;
    }
    sandbox.chrome = {
        runtime: {
            sendMessage(message) {
                if ( message.what === 'floorpCSSDocumentIdentity' ) {
                    identityMessages.push(structuredClone(message));
                    if ( options.identityResponder ) {
                        return options.identityResponder(message, sandbox);
                    }
                    return Promise.resolve({
                        ok: true,
                        schema: 1,
                        requestId: message.requestId,
                        documentId: options.documentId ?? 'css-user-document',
                        frameId: options.subframe ? 1 : 0,
                    });
                }
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
        commits,
        context,
        insertions,
        insertionTransactions,
        identityMessages,
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

function successfulCSSAPI(insertions, commits) {
    return {
        documentId: 'css-user-document',
        frameId: 0,
        suspendForIdentity(record) {
            this.pendingIdentity = record;
        },
        resumeForIdentity(record, documentId, frameId) {
            if ( this.pendingIdentity !== record ) { return false; }
            this.pendingIdentity = undefined;
            return documentId === this.documentId && frameId === this.frameId;
        },
        bindDocumentId(documentId, frameId) {
            return documentId === this.documentId && frameId === this.frameId;
        },
        insert(css) {
            insertions.push(css);
            return Promise.resolve({ ok: true });
        },
        commit(generation) {
            commits.push(generation);
            return Promise.resolve({ ok: true });
        },
        beginInsertionTransaction(generation, deadline) {
            return { deadline, generation };
        },
        finishInsertionTransaction() {},
        rollbackInsertionTransaction() {
            return { ok: true };
        },
        beginRecoveryWindow() {
            return Promise.resolve({ ok: true });
        },
        waitForRecovery() {
            return Promise.resolve({ ok: true });
        },
        replay() {
            return Promise.resolve({ ok: true });
        },
    };
}

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
assert.equal(directOriginFallback.storageGets.length, 1);
assert.equal(directOriginFallback.messages.length, 0);
assert.equal(directOriginFallback.insertions.length, 1);

directOriginFallback.sandbox.floorpCSSUserIdleReplay = true;
new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
}).runInContext(directOriginFallback.context);
await sleep(30);
assert.equal(directOriginFallback.storageGets.length, 1);
assert.equal(directOriginFallback.messages.length, 0);
assert.equal(directOriginFallback.insertions.length, 1);

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

directLocationRequest.sandbox.floorpCSSUserActivationState.committed = false;
directLocationRequest.sandbox.ordinaryIdleRetryCount = 0;
directLocationRequest.sandbox.cssUserStartHandler = ( ) => {
    directLocationRequest.sandbox.ordinaryIdleRetryCount += 1;
};
directLocationRequest.sandbox.floorpCSSUserIdleReplay = true;
new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
}).runInContext(directLocationRequest.context);
await sleep(10);
assert.equal(
    directLocationRequest.sandbox.ordinaryIdleRetryCount,
    1,
    'document_idle must replay an uncommitted ordinary main-frame generation'
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
await waitUntil(( ) => subframeUndefined.listeners.has('pagereveal'));
assert.ok(subframeUndefined.messages.length > 1);
assert.ok(subframeUndefined.messages.length < 20);
assert.equal(subframeUndefined.listeners.has('pagereveal'), true);

for ( const [ label, responder ] of [
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
    await waitUntil(( ) => failed.listeners.has('pagereveal'));
    assert.ok(failed.messages.length > 1, `${label} must retry`);
    assert.ok(failed.messages.length < 20, `${label} retries must be bounded`);
    assert.equal(failed.storageGets.length, 0, `${label} must stay fail-closed`);
    assert.equal(failed.sandbox.customFilters, undefined);
    assert.equal(failed.listeners.has('pagereveal'), true);
}

const rejectedBackgroundFallback = cssUserSandbox(
    ( ) => Promise.reject(new Error('background transport rejected')),
    {
        localState: {
            filteringModeDetails: optimalModes,
            'site.example.test': [ '#rejected-background-fallback' ],
        },
    }
);
await sleep(30);
assert.equal(rejectedBackgroundFallback.messages.length, 1);
assert.equal(rejectedBackgroundFallback.storageGets.length, 1);
assert.deepEqual(rejectedBackgroundFallback.storageGets[0], [
    'floorp.settingsRestoreJournal.v1',
    'floorp.customFilterMutationJournal.v1',
    'filteringModeDetails',
    'admin.defaultFiltering',
    'admin.noFiltering',
    'site.example.test',
    'site.test',
]);
assert.deepEqual(rejectedBackgroundFallback.insertions, [
    '#rejected-background-fallback{display:none!important;}',
]);
assert.equal(rejectedBackgroundFallback.sandbox.customFilters.ok, true);

const mismatchedDirectFallback = cssUserSandbox(
    ( ) => Promise.reject(new Error('background transport rejected')),
    {
        locationHref: 'https://different.example/frame',
        localState: {
            filteringModeDetails: optimalModes,
            'site.example.test': [ '#must-not-cross-document-authority' ],
        },
    }
);
await waitUntil(( ) => mismatchedDirectFallback.listeners.has('pagereveal'));
assert.deepEqual(mismatchedDirectFallback.storageGets, []);
assert.deepEqual(mismatchedDirectFallback.insertions, []);

const never = new Promise(( ) => {});
const timedOut = cssUserSandbox(
    ( ) => never,
    {
        requestId: 'timeout-request',
        storageError: new Error('direct storage unavailable'),
    }
);
await waitUntil(( ) => timedOut.listeners.has('pagereveal'));
assert.equal(timedOut.messages.length, 1);
assert.ok(timedOut.storageGets.length > 1);
assert.ok(timedOut.storageGets.length < 20);
assert.equal(timedOut.listeners.has('pagereveal'), true);
const timedOutStorageCount = timedOut.storageGets.length;
void timedOut.listeners.get('pagereveal')();
void timedOut.listeners.get('pagereveal')();
await sleep(20);
assert.equal(
    timedOut.storageGets.length,
    timedOutStorageCount,
    'the 15-second document-generation deadline must bound later replays'
);

const timeoutThenSuccess = cssUserSandbox(
    ( ) => never,
    {
        requestId: 'timeout-retry-request',
        localState: {
            filteringModeDetails: optimalModes,
            'site.example.test': [ '#timeout-retry' ],
        },
    }
);
await sleep(30);
assert.equal(
    timeoutThenSuccess.messages.length,
    1,
    'a timed-out cold-background request must switch to direct storage once'
);
assert.equal(timeoutThenSuccess.storageGets.length, 1);
assert.equal(timeoutThenSuccess.sandbox.customFilters.ok, true);
assert.deepEqual(timeoutThenSuccess.insertions, [
    '#timeout-retry{display:none!important;}',
]);

let malformedAttempt = 0;
const automaticMalformedRetry = cssUserSandbox(message => {
    malformedAttempt += 1;
    return Promise.resolve(
        malformedAttempt === 1
            ? {}
            : successfulAck(message, [ '#automatic-retry' ])
    );
});
await sleep(30);
assert.equal(automaticMalformedRetry.messages.length, 2);
assert.equal(automaticMalformedRetry.sandbox.customFilters.ok, true);
assert.equal(automaticMalformedRetry.listeners.has('pagereveal'), false);

for ( const [ label, cssInsertResponder ] of [
    [ 'false acknowledgement', ( ) => Promise.resolve({
        ok: false,
        error: 'native insertion unavailable',
    }) ],
    [ 'undefined acknowledgement', ( ) => Promise.resolve(undefined) ],
] ) {
    let insertionAttempts = 0;
    const failedPlainInsertion = cssUserSandbox(
        message => Promise.resolve(successfulAck(message, [ '#plain-fail' ])),
        {
            cssInsertResponder(css) {
                insertionAttempts += 1;
                return cssInsertResponder(css);
            },
        }
    );
    await sleep(30);
    assert.equal(
        failedPlainInsertion.sandbox.customFilters,
        undefined,
        `${label} must not publish customFilters`
    );
    assert.equal(
        failedPlainInsertion.sandbox.floorpCSSUserActivationState.committed,
        false,
        `${label} must leave activation uncommitted`
    );
    assert.equal(
        failedPlainInsertion.commits.length,
        0,
        `${label} must not commit after a failed plain insertion`
    );
    assert.equal(failedPlainInsertion.listeners.has('pagereveal'), true);
    const firstAttemptCount = insertionAttempts;
    await failedPlainInsertion.listeners.get('pagereveal')();
    assert.ok(
        insertionAttempts > firstAttemptCount,
        `${label} must remain retryable on a later lifecycle replay`
    );
}

const missingPlainCSSAPI = cssUserSandbox(
    message => Promise.resolve(successfulAck(message, [ '#missing-api' ])),
    { withoutCSSAPI: true }
);
await sleep(30);
assert.equal(missingPlainCSSAPI.sandbox.customFilters, undefined);
assert.equal(
    missingPlainCSSAPI.sandbox.floorpCSSUserActivationState,
    undefined,
    'plain selectors must fail closed before activation when cssAPI is unavailable'
);
assert.equal(missingPlainCSSAPI.listeners.has('pagereveal'), false);
const recoveredPlainInsertions = [];
const recoveredPlainCommits = [];
missingPlainCSSAPI.sandbox.cssAPI = successfulCSSAPI(
    recoveredPlainInsertions,
    recoveredPlainCommits
);
missingPlainCSSAPI.sandbox.floorpCSSUserIdleReplay = true;
new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
}).runInContext(missingPlainCSSAPI.context);
await sleep(30);
assert.equal(missingPlainCSSAPI.sandbox.customFilters.ok, true);
assert.equal(
    missingPlainCSSAPI.sandbox.floorpCSSUserActivationState.committed,
    true,
    'document_idle must finish a plain activation after cssAPI becomes available'
);
assert.equal(recoveredPlainInsertions.length, 1);
assert.equal(recoveredPlainCommits.length, 1);

class ProceduralFiltererAPI {
    reset(options) {
        this.resetOptions = options;
        return Promise.resolve();
    }
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

let malformedProceduralRequests = 0;
const malformedProcedural = cssUserSandbox(message => {
    malformedProceduralRequests += 1;
    return Promise.resolve({
        ok: true,
        schema: 1,
        requestId: message.requestId,
        plainSelectors: [],
        proceduralSelectors: malformedProceduralRequests === 1
            ? [ '{' ]
            : [ '{"cssable":false,"raw":"repaired"}' ],
    });
}, { ProceduralFiltererAPI });
await sleep(30);
assert.equal(malformedProcedural.sandbox.customFilters, undefined);
assert.equal(
    malformedProcedural.sandbox.floorpCSSUserActivationState.committed,
    false,
    'malformed procedural JSON must never commit an empty activation'
);
assert.equal(
    malformedProcedural.sandbox.customProceduralFiltererAPI,
    undefined,
    'malformed procedural JSON must not publish a partial filterer'
);
assert.equal(malformedProcedural.insertionTransactions.length, 0);
await malformedProcedural.listeners.get('pagereveal')({ type: 'pagereveal' });
assert.equal(malformedProceduralRequests, 2);
assert.equal(malformedProcedural.sandbox.customFilters.ok, true);
assert.equal(
    malformedProcedural.sandbox.customProceduralFiltererAPI.procedurals[0].raw,
    'repaired',
    'a later lifecycle replay must fully rebuild repaired procedural data'
);

for ( const failingMethod of [ 'addDeclaratives', 'addProcedurals' ] ) {
    const instances = [];
    class PartiallyFailingProceduralFilterer {
        constructor() {
            instances.push(this);
        }
        reset(options) {
            this.resetOptions = options;
            return Promise.resolve();
        }
        addDeclaratives(selectors) {
            this.declaratives = selectors;
            if ( instances.length === 1 && failingMethod === 'addDeclaratives' ) {
                throw new Error('declarative construction failed');
            }
        }
        addProcedurals(selectors) {
            this.procedurals = selectors;
            if ( instances.length === 1 && failingMethod === 'addProcedurals' ) {
                throw new Error('procedural construction failed');
            }
        }
    }
    let filterDocumentRequests = 0;
    const partialFailure = cssUserSandbox(message => {
        filterDocumentRequests += 1;
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            plainSelectors: [],
            proceduralSelectors: [
                '{"cssable":true,"raw":"declarative"}',
                '{"cssable":false,"raw":"procedural"}',
            ],
        });
    }, { ProceduralFiltererAPI: PartiallyFailingProceduralFilterer });
    await sleep(30);
    assert.equal(partialFailure.sandbox.customFilters, undefined);
    assert.equal(
        partialFailure.sandbox.customProceduralFiltererAPI,
        undefined,
        `${failingMethod} failure must not publish its partial filterer`
    );
    assert.equal(instances[0].resetOptions?.removeCSS, false);
    assert.deepEqual(
        partialFailure.insertionTransactions.map(entry => entry.event),
        [ 'begin', 'rollback' ],
        `${failingMethod} failure must discard its staged CSS transaction`
    );
    await partialFailure.listeners.get('pagereveal')({ type: 'pagereveal' });
    assert.equal(filterDocumentRequests, 2);
    assert.equal(partialFailure.sandbox.customFilters.ok, true);
    assert.equal(
        partialFailure.sandbox.customProceduralFiltererAPI,
        instances[1],
        `${failingMethod} replay must publish a newly constructed filterer`
    );
    assert.deepEqual(
        partialFailure.insertionTransactions.map(entry => entry.event),
        [ 'begin', 'rollback', 'begin', 'finish' ]
    );
}

let proceduralCommitAttempts = 0;
const failedProceduralCommit = cssUserSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
    plainSelectors: [],
    proceduralSelectors: [ '{"cssable":false,"raw":"commit-fail"}' ],
}), {
    ProceduralFiltererAPI,
    cssCommitResponder() {
        proceduralCommitAttempts += 1;
        return Promise.resolve({ ok: false, error: 'captured CSS failure' });
    },
});
await sleep(30);
assert.equal(failedProceduralCommit.sandbox.customFilters, undefined);
assert.equal(
    failedProceduralCommit.sandbox.floorpCSSUserActivationState.committed,
    false,
    'a failed CSS commit must leave procedural activation uncommitted'
);
assert.equal(proceduralCommitAttempts, 1);
assert.equal(failedProceduralCommit.listeners.has('pagereveal'), true);
await failedProceduralCommit.listeners.get('pagereveal')();
assert.ok(
    proceduralCommitAttempts > 1,
    'a failed CSS commit must remain retryable on a later lifecycle replay'
);

const missingProceduralCSSAPI = cssUserSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
    plainSelectors: [],
    proceduralSelectors: [ '{"cssable":false,"raw":"missing-css-api"}' ],
}), {
    ProceduralFiltererAPI,
    withoutCSSAPI: true,
});
await sleep(30);
assert.equal(missingProceduralCSSAPI.sandbox.customFilters, undefined);
assert.equal(
    missingProceduralCSSAPI.sandbox.floorpCSSUserActivationState,
    undefined,
    'procedural selectors must fail closed before activation when cssAPI is unavailable'
);
assert.equal(
    missingProceduralCSSAPI.sandbox.customProceduralFiltererAPI,
    undefined
);
const recoveredProceduralInsertions = [];
const recoveredProceduralCommits = [];
missingProceduralCSSAPI.sandbox.cssAPI = successfulCSSAPI(
    recoveredProceduralInsertions,
    recoveredProceduralCommits
);
missingProceduralCSSAPI.sandbox.floorpCSSUserIdleReplay = true;
new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
}).runInContext(missingProceduralCSSAPI.context);
await sleep(30);
assert.equal(missingProceduralCSSAPI.sandbox.customFilters.ok, true);
assert.ok(
    missingProceduralCSSAPI.sandbox.customProceduralFiltererAPI instanceof
        ProceduralFiltererAPI
);
assert.equal(recoveredProceduralInsertions.length, 0);
assert.equal(recoveredProceduralCommits.length, 1);

const apiListeners = new Map();
const sharedDocumentElement = mockDocumentElement();
const apiReplaySandbox = {
    CSSStyleSheet: MockCSSStyleSheet,
    MutationObserver: MockMutationObserver,
    Uint32Array,
    console,
    crypto: {
        getRandomValues(values) { return values.fill(7); },
        randomUUID() { return '00000000-0000-4000-8000-000000000007'; },
    },
    document: {
        documentElement: sharedDocumentElement,
        location: { hostname: '' },
    },
    getComputedStyle: mockScopedComputedStyle([]),
    performance: { timeOrigin: 17, now: ( ) => 0 },
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
const cssUserScript = new vm.Script(cssUserSource, {
    filename: 'js/scripting/css-user.js',
});
const cssUserTerminateScript = new vm.Script(cssUserTerminateSource, {
    filename: 'js/scripting/css-user-terminate.js',
});

cssAPIScript.runInContext(apiReplayContext);
proceduralAPIScript.runInContext(apiReplayContext);
const transientCSSAPI = apiReplaySandbox.cssAPI;
const transientProceduralAPI = apiReplaySandbox.ProceduralFiltererAPI;

idlePreludeScript.runInContext(apiReplayContext);
assert.equal(apiReplaySandbox.floorpCSSUserAPIIdleReplay, true);
cssAPIScript.runInContext(apiReplayContext);
proceduralAPIScript.runInContext(apiReplayContext);
assert.equal(
    apiReplaySandbox.cssAPI,
    transientCSSAPI,
    'stable origin-fallback idle must retain its native-identity controller'
);
assert.equal(
    apiReplaySandbox.ProceduralFiltererAPI,
    transientProceduralAPI,
    'stable origin-fallback idle must retain its procedural DOM engine'
);
const finalCSSAPI = apiReplaySandbox.cssAPI;
const finalProceduralAPI = apiReplaySandbox.ProceduralFiltererAPI;
idleMarkerScript.runInContext(apiReplayContext);
assert.equal(apiReplaySandbox.floorpCSSUserIdleReplay, true);
assert.equal(
    apiReplaySandbox.floorpCSSUserAPIIdleReplay,
    true,
    'the API prelude marker remains set until css-user consumes it'
);

apiReplaySandbox.document.location.hostname = 'example.test';
idlePreludeScript.runInContext(apiReplayContext);
cssAPIScript.runInContext(apiReplayContext);
proceduralAPIScript.runInContext(apiReplayContext);
assert.equal(apiReplaySandbox.cssAPI, finalCSSAPI);
assert.equal(apiReplaySandbox.ProceduralFiltererAPI, finalProceduralAPI);

function integratedCSSUserAPISandbox(options = {}) {
    const listeners = new Map();
    const messages = [];
    let monotonicNow = 0;
    let requestSequence = 0;
    const sandbox = {
        CSSStyleSheet: MockCSSStyleSheet,
        MutationObserver: MockMutationObserver,
        Uint32Array,
        URL,
        clearTimeout,
        console,
        crypto: {
            getRandomValues(values) {
                requestSequence += 1;
                values.fill(requestSequence);
                return values;
            },
            randomUUID() {
                requestSequence += 1;
                return `integrated-${requestSequence}`;
            },
        },
        Date,
        document: {
            documentElement: mockDocumentElement(),
            location: {
                ancestorOrigins: [],
                hostname: 'integrated.example',
                href: 'https://integrated.example/frame',
                origin: 'https://integrated.example',
            },
        },
        getComputedStyle: mockScopedComputedStyle(
            messages,
            options.canaryResponder
        ),
        Math,
        performance: {
            get timeOrigin() { return 31; },
            now() { return monotonicNow; },
        },
        setTimeout(callback, delay) {
            if ( options.realTime ) {
                const adjusted = delay === 2000 && options.shortTimeout
                    ? 10
                    : delay;
                return setTimeout(callback, adjusted);
            }
            if ( options.scaledTime ) {
                return setTimeout(( ) => {
                    monotonicNow += delay;
                    callback();
                }, Math.max(1, delay / 1000));
            }
            return setTimeout(( ) => {
                monotonicNow += delay;
                callback();
            }, 0);
        },
        addEventListener(type, listener) {
            const entries = listeners.get(type) ?? [];
            entries.push(listener);
            listeners.set(type, entries);
        },
        removeEventListener(type, listener) {
            const entries = listeners.get(type) ?? [];
            listeners.set(type, entries.filter(entry => entry !== listener));
        },
    };
    sandbox.self = sandbox;
    sandbox.__documentId = options.documentId ?? 'integrated-document';
    sandbox.__frameId = options.subframe ? 1 : 0;
    sandbox.top = options.subframe ? {} : sandbox;
    sandbox.parent = options.subframe ? {} : sandbox;
    if ( options.ProceduralFiltererAPI ) {
        sandbox.ProceduralFiltererAPI = options.ProceduralFiltererAPI;
    }
    sandbox.chrome = {
        runtime: {
            sendMessage(message) {
                messages.push(structuredClone(message));
                if ( message.what === 'floorpCSSDocumentIdentity' ) {
                    if ( options.identityResponder ) {
                        return options.identityResponder(message, sandbox);
                    }
                    return Promise.resolve({
                        ok: true,
                        schema: 1,
                        requestId: message.requestId,
                        documentId: sandbox.__documentId,
                        frameId: sandbox.__frameId,
                    });
                }
                if ( message.what === 'injectCustomFilters' ) {
                    if ( options.customFilterResponder ) {
                        return options.customFilterResponder(message, sandbox);
                    }
                    return Promise.resolve(successfulAck(message, [
                        options.selector ?? '#integrated',
                    ]));
                }
                if ( message.what === 'insertCSS' ) {
                    if ( options.insertCSSResponder ) {
                        return options.insertCSSResponder(message, sandbox);
                    }
                    return Promise.resolve({
                        ok: true,
                        schema: 1,
                        requestId: message.requestId,
                        documentId: sandbox.__documentId,
                        frameId: sandbox.__frameId,
                        ensured: true,
                    });
                }
                if ( message.what === 'removeCSS' && options.removeCSSResponder ) {
                    return options.removeCSSResponder(message, sandbox);
                }
                if ( message.what === 'removeCSS' ) {
                    return Promise.resolve({
                        ok: true,
                        schema: 1,
                        requestId: message.requestId,
                        documentId: sandbox.__documentId,
                        frameId: sandbox.__frameId,
                    });
                }
                if ( message.what === 'injectCSSProceduralAPI' ) {
                    if ( options.injectAPIResponder ) {
                        return options.injectAPIResponder(message, sandbox);
                    }
                    return Promise.resolve({
                        ok: true,
                        schema: 1,
                        requestId: message.requestId,
                        plainSelectors: [],
                        proceduralSelectors: [],
                    });
                }
                return Promise.resolve();
            },
        },
        storage: {
            local: {
                get(keys) {
                    if ( options.storageResponder ) {
                        return options.storageResponder(keys, sandbox);
                    }
                    return Promise.resolve(structuredClone(options.localState ?? {}));
                },
            },
        },
    };
    const context = vm.createContext(sandbox);
    const runCSSAPI = ( ) => cssAPIScript.runInContext(context);
    const runProceduralAPI = ( ) => proceduralAPIScript.runInContext(context);
    const runCSSUser = ( ) => {
        cssUserScript.runInContext(context);
        return sandbox.floorpCSSUserExecution;
    };
    const runTerminate = ( ) => {
        cssUserTerminateScript.runInContext(context);
        return sandbox.floorpCSSUserTerminationOp;
    };
    const runIdle = ( ) => {
        idlePreludeScript.runInContext(context);
        runCSSAPI();
        idleMarkerScript.runInContext(context);
        return runCSSUser();
    };
    const dispatch = async (type, event = { type }) => {
        const entries = Array.from(listeners.get(type) ?? []);
        await Promise.all(entries.map(listener => listener(event)));
        await sleep(20);
    };
    if ( options.preloadCSSAPI ) { runCSSAPI(); }
    if ( options.autoStart !== false ) { runCSSUser(); }
    return {
        advance(delay) { monotonicNow += delay; },
        context,
        dispatch,
        listeners,
        messages,
        runCSSAPI,
        runIdle,
        runProceduralAPI,
        runTerminate,
        runCSSUser,
        sandbox,
    };
}

const firstLivePlainFilter = integratedCSSUserAPISandbox({ autoStart: false });
firstLivePlainFilter.runCSSAPI();
const firstLivePlainResult = await firstLivePlainFilter.runCSSUser();
assert.deepEqual(
    structuredClone(firstLivePlainResult),
    {
        ok: true,
        schema: 1,
        committed: true,
        documentId: 'integrated-document',
    },
    'dynamic css-user execution must report its same-document commit'
);
assert.equal(firstLivePlainFilter.sandbox.floorpCSSUserActivationState.committed, true);
assert.equal(
    firstLivePlainFilter.messages.filter(message => message.what === 'insertCSS').length,
    1,
    'the first plain filter added after document_idle must commit immediately'
);

const failedLiveCommit = integratedCSSUserAPISandbox({
    autoStart: false,
    preloadCSSAPI: true,
    scaledTime: true,
    selector: '#failed-live-commit',
    insertCSSResponder(message) {
        return Promise.resolve({
            ok: false,
            schema: 1,
            requestId: message.requestId,
            documentId: 'integrated-document',
            error: 'native insertion unavailable',
        });
    },
});
const failedLiveCommitResult = await failedLiveCommit.runCSSUser();
assert.deepEqual(
    structuredClone(failedLiveCommitResult),
    {
        ok: false,
        schema: 1,
        committed: false,
        documentId: 'integrated-document',
    },
    'dynamic css-user execution must expose native commit failure'
);
assert.equal(failedLiveCommit.sandbox.customFilters, undefined);

let firstLiveProceduralHost;
class FirstLiveProceduralFilterer {
    constructor(options) {
        this.options = options;
        firstLiveProceduralHost.cssAPI.registerOwnerHook(
            options.cssOwner,
            options.cssGeneration,
            this,
            options.cssLane
        );
    }
    addDeclaratives(selectors) { this.declaratives = selectors; }
    addProcedurals(selectors) {
        this.procedurals = selectors;
        void firstLiveProceduralHost.cssAPI.activateOwner(
            this.options.cssOwner,
            this.options.cssGeneration,
            { lane: this.options.cssLane }
        );
    }
    activatePrepared() { this.activated = true; }
    reset() { return Promise.resolve(); }
}
const firstLiveProceduralFilter = integratedCSSUserAPISandbox({
    autoStart: false,
    ProceduralFiltererAPI: FirstLiveProceduralFilterer,
    customFilterResponder(message) {
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            plainSelectors: [],
            proceduralSelectors: [
                '{"cssable":false,"raw":"first-live-procedural"}',
            ],
        });
    },
});
firstLiveProceduralHost = firstLiveProceduralFilter.sandbox;
firstLiveProceduralFilter.runCSSAPI();
firstLiveProceduralFilter.runCSSUser();
await sleep(30);
assert.equal(
    firstLiveProceduralFilter.sandbox.floorpCSSUserActivationState.committed,
    true,
    'the first procedural filter added after document_idle must commit immediately'
);
assert.equal(
    firstLiveProceduralFilter.sandbox.customProceduralFiltererAPI
        .procedurals[0].raw,
    'first-live-procedural'
);

let transactionalCSSHost;
const transactionalFilterers = [];
class TransactionalFailureFilterer {
    constructor() { transactionalFilterers.push(this); }
    addDeclaratives() {
        transactionalCSSHost.cssAPI.insert(
            '#staged-before-procedural-failure{display:none!important}'
        );
    }
    addProcedurals(selectors) {
        this.procedurals = selectors;
        if ( transactionalFilterers.length === 1 ) {
            throw new Error('later procedural selector failed');
        }
    }
    reset(options) {
        this.resetOptions = options;
        return Promise.resolve();
    }
}
const transactionalFailure = integratedCSSUserAPISandbox({
    preloadCSSAPI: true,
    ProceduralFiltererAPI: TransactionalFailureFilterer,
    customFilterResponder(message) {
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            plainSelectors: [],
            proceduralSelectors: [
                '{"cssable":true,"raw":"stage-css"}',
                '{"cssable":false,"raw":"throw-after-stage"}',
            ],
        });
    },
});
transactionalCSSHost = transactionalFailure.sandbox;
await sleep(30);
assert.equal(transactionalFailure.sandbox.customFilters, undefined);
assert.equal(transactionalFailure.sandbox.customProceduralFiltererAPI, undefined);
assert.equal(transactionalFilterers[0].resetOptions?.removeCSS, false);
assert.deepEqual(
    transactionalFailure.messages.slice(0, 2).map(message => message.what),
    [ 'floorpCSSDocumentIdentity', 'injectCustomFilters' ],
    'the transaction must first bind its native Document then fetch selectors'
);
assert.deepEqual(
    transactionalFailure.messages
        .filter(message => [ 'insertCSS', 'removeCSS' ].includes(message.what)),
    [],
    'partial procedural construction must send neither native insert nor remove'
);
await transactionalFailure.dispatch('pagereveal', { type: 'pagereveal' });
assert.equal(transactionalFailure.sandbox.floorpCSSUserActivationState.committed, true);
assert.equal(
    transactionalFailure.messages.filter(message => message.what === 'insertCSS').length,
    1,
    'replay must rebuild and apply the complete procedural transaction once'
);

for ( const subframe of [ false, true ] ) {
    const slowIdle = integratedCSSUserAPISandbox({ subframe });
    await sleep(30);
    assert.equal(
        slowIdle.sandbox.floorpCSSUserActivationState,
        undefined,
        'css-user must not publish an activation before css-api is available'
    );
    slowIdle.advance(16000);
    slowIdle.runIdle();
    await sleep(30);
    assert.equal(
        slowIdle.sandbox.floorpCSSUserActivationState.committed,
        true,
        `slow document_idle must recover a ${subframe ? 'subframe' : 'main frame'}`
    );
    assert.equal(
        slowIdle.messages.filter(message => message.what === 'insertCSS').length,
        1,
        'the idle recovery window must perform one native insertion'
    );
    assert.equal(slowIdle.sandbox.floorpCSSUserActivationState.idleRecoveryUsed, false);
}

let listenerOrderInsertionAttempt = 0;
const reverseListenerOrder = integratedCSSUserAPISandbox({
    preloadCSSAPI: true,
    insertCSSResponder(message, sandbox) {
        listenerOrderInsertionAttempt += 1;
        if ( listenerOrderInsertionAttempt === 1 ) {
            return Promise.resolve(undefined);
        }
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            documentId: sandbox.__documentId,
            frameId: sandbox.__frameId,
            ensured: true,
        });
    },
});
await sleep(30);
reverseListenerOrder.advance(16000);
assert.equal(
    reverseListenerOrder.listeners.get('pagereveal').length,
    2,
    'failed activation must retain both css-api and css-user reveal listeners'
);
assert.equal(
    reverseListenerOrder.listeners.get('pagereveal')[1],
    reverseListenerOrder.sandbox.cssUserStartHandler,
    'registered css-api runs first and css-user recovery follows in one event'
);
await reverseListenerOrder.dispatch('pagereveal', { type: 'pagereveal' });
assert.equal(
    reverseListenerOrder.sandbox.floorpCSSUserActivationState.committed,
    true,
    'one page reveal must recover activation regardless of listener order'
);
assert.equal(
    reverseListenerOrder.messages.filter(message => message.what === 'insertCSS').length,
    2
);

let resolvePendingCustomFilters;
const pendingIdle = integratedCSSUserAPISandbox({
    preloadCSSAPI: true,
    realTime: true,
    customFilterResponder(message) {
        return new Promise(resolve => {
            resolvePendingCustomFilters = ( ) => resolve(
                successfulAck(message, [ '#pending-idle' ])
            );
        });
    },
});
await sleep(10);
pendingIdle.runIdle();
await sleep(10);
resolvePendingCustomFilters();
await sleep(30);
assert.equal(pendingIdle.sandbox.floorpCSSUserActivationState.committed, true);
assert.equal(
    pendingIdle.messages.filter(message => message.what === 'insertCSS').length,
    1,
    'queued document_idle must not replay after document_start commits first'
);

class QueuedIdleProceduralFilterer {
    addDeclaratives(selectors) { this.declaratives = selectors; }
    addProcedurals(selectors) { this.procedurals = selectors; }
    reset() { return Promise.resolve(); }
}
let expiredStartRequests = 0;
const queuedIdleAfterExpiredStart = integratedCSSUserAPISandbox({
    autoStart: false,
    preloadCSSAPI: true,
    scaledTime: true,
    ProceduralFiltererAPI: QueuedIdleProceduralFilterer,
    customFilterResponder() {
        expiredStartRequests += 1;
        return never;
    },
    storageResponder(keys, sandbox) {
        if ( sandbox.floorpCSSUserActivationState?.idleRecoveryUsed !== true ) {
            return Promise.reject(new Error('cold storage lane is still blocked'));
        }
        return Promise.resolve({
            filteringModeDetails: optimalModes,
            'site.integrated.example': [
                '#queued-idle-recovery',
                '{"cssable":false,"raw":"queued-idle-procedural"}',
            ],
        });
    },
});
const expiredDocumentStart = queuedIdleAfterExpiredStart.runCSSUser();
while ( expiredStartRequests === 0 ) { await sleep(1); }
const queuedIdleGeneration =
    queuedIdleAfterExpiredStart.sandbox.cssUserDocumentGeneration;
const recoveredDocumentIdle = queuedIdleAfterExpiredStart.runIdle();
const [ expiredStartResult, recoveredIdleResult ] = await Promise.race([
    Promise.all([ expiredDocumentStart, recoveredDocumentIdle ]),
    sleep(1000).then(( ) => { throw new Error('queued idle recovery deadlocked'); }),
]);
assert.equal(expiredStartResult.committed, false);
assert.equal(recoveredIdleResult.committed, true);
assert.equal(
    queuedIdleAfterExpiredStart.sandbox.cssUserDocumentGeneration,
    queuedIdleGeneration,
    'document_idle must recover the existing owner generation without orphaning it'
);
assert.equal(
    queuedIdleAfterExpiredStart.sandbox.floorpCSSUserActivationState.committed,
    true,
    'document_idle must receive a fresh bounded window after document_start expires'
);
assert.equal(expiredStartRequests, 2);
assert.equal(
    queuedIdleAfterExpiredStart.messages.filter(
        message => message.what === 'insertCSS'
    ).length,
    1
);
assert.equal(
    queuedIdleAfterExpiredStart.sandbox.document.documentElement
        .attributeNames().filter(name => name.startsWith('data-floorp-ubol-')).length,
    1
);
assert.equal(
    queuedIdleAfterExpiredStart.sandbox.customProceduralFiltererAPI
        .procedurals[0].raw,
    'queued-idle-procedural'
);

let expiredDynamicRequests = 0;
const queuedDynamicAfterExpiredStart = integratedCSSUserAPISandbox({
    autoStart: false,
    preloadCSSAPI: true,
    scaledTime: true,
    customFilterResponder() {
        expiredDynamicRequests += 1;
        return never;
    },
    storageResponder() {
        if ( expiredDynamicRequests < 2 ) {
            return Promise.reject(new Error('first dynamic storage lane is blocked'));
        }
        return Promise.resolve({
            filteringModeDetails: optimalModes,
            'site.integrated.example': [ '#queued-dynamic-recovery' ],
        });
    },
});
const expiredDynamicStart = queuedDynamicAfterExpiredStart.runCSSUser();
while ( expiredDynamicRequests === 0 ) { await sleep(1); }
const queuedDynamicGeneration =
    queuedDynamicAfterExpiredStart.sandbox.cssUserDocumentGeneration;
const recoveredDynamicStart = queuedDynamicAfterExpiredStart.runCSSUser();
const [ firstDynamicResult, recoveredDynamicResult ] = await Promise.race([
    Promise.all([ expiredDynamicStart, recoveredDynamicStart ]),
    sleep(1000).then(( ) => { throw new Error('queued dynamic recovery deadlocked'); }),
]);
assert.equal(typeof firstDynamicResult.committed, 'boolean');
assert.equal(recoveredDynamicResult.committed, true);
assert.equal(expiredDynamicRequests, 2);
assert.equal(
    queuedDynamicAfterExpiredStart.sandbox.cssUserDocumentGeneration,
    queuedDynamicGeneration,
    'dynamic replay must recover the existing owner generation'
);
assert.equal(
    queuedDynamicAfterExpiredStart.messages.filter(
        message => message.what === 'insertCSS'
    ).length,
    1
);
assert.equal(
    queuedDynamicAfterExpiredStart.sandbox.document.documentElement
        .attributeNames().filter(name => name.startsWith('data-floorp-ubol-')).length,
    1
);

let deferredCustomInsert;
let deferredStockInsert;
let firstCustomInsert = true;
const terminationRace = integratedCSSUserAPISandbox({
    preloadCSSAPI: true,
    realTime: true,
    selector: '#terminate-custom',
    insertCSSResponder(message) {
        if (
            firstCustomInsert &&
            message.css.includes('#terminate-custom')
        ) {
            firstCustomInsert = false;
            return new Promise(resolve => {
                deferredCustomInsert = ( ) => resolve({
                    ok: true,
                    schema: 1,
                    requestId: message.requestId,
                    documentId: 'integrated-document',
                    frameId: 0,
                    ensured: true,
                });
            });
        }
        if ( message.css.includes('#stock-survives-termination') ) {
            return new Promise(resolve => {
                deferredStockInsert = ( ) => resolve({
                    ok: true,
                    schema: 1,
                    requestId: message.requestId,
                    documentId: 'integrated-document',
                    frameId: 0,
                    ensured: true,
                });
            });
        }
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            documentId: 'integrated-document',
            frameId: 0,
            ensured: true,
        });
    },
});
const stockCSS = '#stock-survives-termination{display:none!important}';
await sleep(20);
assert.equal(typeof deferredCustomInsert, 'function');
const pendingStockInsertion = terminationRace.sandbox.cssAPI.insert(stockCSS);

let resolveFiltererReset;
let filtererResetOptions;
terminationRace.sandbox.customProceduralFiltererAPI = {
    reset(options) {
        filtererResetOptions = options;
        return new Promise(resolve => {
            resolveFiltererReset = resolve;
        });
    },
};
let terminationSettled = false;
const terminationOperation = Promise.resolve(terminationRace.runTerminate())
    .then(( ) => { terminationSettled = true; });
await sleep(10);
assert.equal(terminationRace.sandbox.floorpCSSUserActivationState, undefined);
assert.equal(terminationRace.sandbox.cssUserStartHandler, undefined);
assert.equal(terminationRace.sandbox.customFilters, undefined);
deferredCustomInsert();
while ( typeof deferredStockInsert !== 'function' ) {
    await sleep(5);
}
deferredStockInsert();
assert.equal(
    (await pendingStockInsertion).ok,
    true,
    'stock insertion must survive custom-generation invalidation'
);
await sleep(20);
assert.equal(
    terminationSettled,
    false,
    'termination must await procedural filterer reset completion'
);
assert.equal(filtererResetOptions?.removeCSS, false);
resolveFiltererReset();
await terminationOperation;
await sleep(20);
assert.equal(
    terminationRace.sandbox.customFilters,
    undefined,
    'a late native acknowledgement must not republish terminated filters'
);
const terminationMessages = terminationRace.messages;
const lateCustomInsertIndex = terminationMessages.findIndex(message =>
    message.what === 'insertCSS' && message.css.includes('#terminate-custom')
);
const customRemovalIndexes = terminationMessages.flatMap((message, index) =>
    message.what === 'removeCSS' && message.css.includes('#terminate-custom')
        ? [ index ]
        : []
);
assert.ok(lateCustomInsertIndex !== -1);
assert.ok(
    customRemovalIndexes.some(index => index > lateCustomInsertIndex),
    'owner cancellation must remove custom CSS after a late insert acknowledgement'
);

const beforeStockReplay = terminationRace.messages.length;
await terminationRace.dispatch('pagereveal', { type: 'pagereveal' });
const terminationReplayMessages = terminationRace.messages.slice(beforeStockReplay);
assert.ok(terminationReplayMessages.some(message =>
    message.what === 'insertCSS' &&
    message.css.includes('#stock-survives-termination')
));
assert.equal(
    terminationReplayMessages.some(message =>
        message.what === 'insertCSS' && message.css.includes('#terminate-custom')
    ),
    false,
    'terminated custom CSS must be forgotten while stock CSS remains replayable'
);

const restartedTerminationRace = await terminationRace.runCSSUser();
assert.equal(
    terminationRace.sandbox.floorpCSSUserActivationState.committed,
    true,
    `startCustomFilters after termination must build a fresh generation: ${JSON.stringify(structuredClone(restartedTerminationRace))}`
);
assert.equal(terminationRace.sandbox.customFilters.ok, true);
assert.ok(terminationRace.messages.slice(beforeStockReplay).some(message =>
    message.what === 'insertCSS' && message.css.includes('#terminate-custom')
));

for ( const [ label, removeCSSResponder ] of [
    [ 'structured negative', message => Promise.resolve({
        ok: false,
        schema: 1,
        requestId: message.requestId,
        documentId: 'integrated-document',
        error: 'native removal failed',
    }) ],
    [ 'malformed acknowledgement', ( ) => Promise.resolve({ ok: true }) ],
    [ 'runtime rejection', ( ) => Promise.reject(new Error('remove wake failed')) ],
] ) {
    const failedTermination = integratedCSSUserAPISandbox({
        preloadCSSAPI: true,
        scaledTime: true,
        selector: `#remove-failure-${label.replaceAll(' ', '-')}`,
        removeCSSResponder,
    });
    await sleep(30);
    assert.equal(
        failedTermination.sandbox.floorpCSSUserActivationState.committed,
        true
    );
    await assert.rejects(
        Promise.resolve(failedTermination.runTerminate()),
        undefined,
        `${label} remove failure must reject css-user-terminate injection`
    );
    assert.equal(failedTermination.sandbox.customFilters, undefined);
    assert.ok(
        failedTermination.messages.some(message => message.what === 'removeCSS'),
        `${label} must reach the structured native removal path`
    );
}

let resolveLateCleanupInsert;
let lateCleanupRemovalAttempt = 0;
const lateCleanupFailure = integratedCSSUserAPISandbox({
    preloadCSSAPI: true,
    realTime: true,
    selector: '#late-cleanup-failure',
    insertCSSResponder(message) {
        return new Promise(resolve => {
            resolveLateCleanupInsert = ( ) => resolve({
                ok: true,
                schema: 1,
                requestId: message.requestId,
                documentId: 'integrated-document',
            });
        });
    },
    removeCSSResponder(message) {
        lateCleanupRemovalAttempt += 1;
        if ( lateCleanupRemovalAttempt === 1 ) {
            return Promise.resolve({
                ok: true,
                schema: 1,
                requestId: message.requestId,
                documentId: 'integrated-document',
            });
        }
        return Promise.resolve({ ok: true });
    },
});
await sleep(20);
assert.equal(typeof resolveLateCleanupInsert, 'function');
let lateCleanupTerminationSettled = false;
const lateCleanupTermination = Promise.resolve(lateCleanupFailure.runTerminate());
void lateCleanupTermination.then(
    ( ) => { lateCleanupTerminationSettled = true; },
    ( ) => { lateCleanupTerminationSettled = true; }
);
await sleep(20);
assert.equal(
    lateCleanupTerminationSettled,
    false,
    'termination must await the retiring insertion and final cleanup'
);
resolveLateCleanupInsert();
await assert.rejects(
    lateCleanupTermination,
    undefined,
    'a malformed final late-insert cleanup must reject termination'
);
assert.equal(lateCleanupRemovalAttempt, 2);

const orphanedRetirement = integratedCSSUserAPISandbox({
    preloadCSSAPI: true,
    scaledTime: true,
    selector: '#orphaned-retirement',
    insertCSSResponder() {
        return new Promise(( ) => {});
    },
});
await sleep(20);
await assert.rejects(
    Promise.resolve(orphanedRetirement.runTerminate()),
    undefined,
    'an orphaned old insertion must return a bounded termination failure'
);
assert.equal(
    orphanedRetirement.messages.filter(message => message.what === 'insertCSS').length,
    1,
    'bounded termination failure must not start a replacement physical stream'
);
await assert.rejects(
    Promise.resolve(orphanedRetirement.runTerminate()),
    undefined,
    'a later empty-generation termination must still observe prior retirement'
);

let recoverBlockedRemoval = false;
const blockedRemovalRecovery = integratedCSSUserAPISandbox({
    preloadCSSAPI: true,
    selector: '#blocked-removal-recovery',
    removeCSSResponder(message) {
        if ( recoverBlockedRemoval === false ) {
            return Promise.resolve({ ok: true });
        }
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            documentId: 'integrated-document',
            frameId: 0,
        });
    },
});
await sleep(30);
await assert.rejects(
    Promise.resolve(blockedRemovalRecovery.runTerminate()),
    undefined,
    'ambiguous removal must fail the first termination'
);
recoverBlockedRemoval = true;
await Promise.resolve(blockedRemovalRecovery.runTerminate());
assert.equal(
    blockedRemovalRecovery.messages.filter(message => message.what === 'removeCSS').length,
    2,
    'a later termination must explicitly recover a prior removal tombstone'
);

const cssProtocolMessages = (host, what) =>
    host.messages.filter(message => message.what === what);
const scopeAttributes = host => host.sandbox.document.documentElement
    .attributeNames()
    .filter(name => name.startsWith('data-floorp-ubol-'));

let heldRepeatedAPIIdentity;
let repeatedAPIIdentityRequests = 0;
const repeatedAPIWhileIdentityPending = integratedCSSUserAPISandbox({
    autoStart: false,
    preloadCSSAPI: true,
    realTime: true,
    identityResponder(message, sandbox) {
        repeatedAPIIdentityRequests += 1;
        if ( repeatedAPIIdentityRequests === 1 ) {
            return new Promise(resolve => {
                heldRepeatedAPIIdentity = { message, resolve, sandbox };
            });
        }
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            documentId: sandbox.__documentId,
            frameId: sandbox.__frameId,
        });
    },
    customFilterResponder(message) {
        return Promise.resolve(successfulAck(message, [
            '#repeated-api-during-identity',
        ]));
    },
});
const repeatedAPIStart = repeatedAPIWhileIdentityPending.runCSSUser();
while ( heldRepeatedAPIIdentity === undefined ) { await sleep(1); }
repeatedAPIWhileIdentityPending.runCSSAPI();
await sleep(1);
assert.equal(
    repeatedAPIIdentityRequests,
    1,
    'repeated css-api execution must join the active css-user identity lease'
);
heldRepeatedAPIIdentity.resolve({
    ok: true,
    schema: 1,
    requestId: heldRepeatedAPIIdentity.message.requestId,
    documentId: heldRepeatedAPIIdentity.sandbox.__documentId,
    frameId: heldRepeatedAPIIdentity.sandbox.__frameId,
});
const repeatedAPIResult = await repeatedAPIStart;
assert.equal(repeatedAPIResult.committed, true);
assert.equal(scopeAttributes(repeatedAPIWhileIdentityPending).length, 1);
assert.equal(
    repeatedAPIWhileIdentityPending.sandbox
        .floorpCSSUserIdentityPendingRecord,
    undefined
);

for ( const resolutionOrder of [ [ 0, 1 ], [ 1, 0 ] ] ) {
    const heldIdentities = [];
    let identityRequestCount = 0;
    let concurrentFilterFetches = 0;
    const concurrentStart = integratedCSSUserAPISandbox({
        autoStart: false,
        preloadCSSAPI: true,
        identityResponder(message, sandbox) {
            identityRequestCount += 1;
            if ( identityRequestCount <= 2 ) {
                return new Promise(resolve => heldIdentities.push({
                    message,
                    resolve,
                    sandbox,
                }));
            }
            return Promise.resolve({
                ok: true,
                schema: 1,
                requestId: message.requestId,
                documentId: sandbox.__documentId,
                frameId: sandbox.__frameId,
            });
        },
        customFilterResponder(message) {
            concurrentFilterFetches += 1;
            return Promise.resolve(successfulAck(message, [ '#concurrent-start' ]));
        },
    });
    const firstStart = concurrentStart.runCSSUser();
    while ( heldIdentities.length < 1 ) { await sleep(1); }
    const secondStart = concurrentStart.runCSSUser();
    while ( heldIdentities.length < 2 ) { await sleep(1); }
    for ( const index of resolutionOrder ) {
        const held = heldIdentities[index];
        held.resolve({
            ok: true,
            schema: 1,
            requestId: held.message.requestId,
            documentId: held.sandbox.__documentId,
            frameId: held.sandbox.__frameId,
        });
        await sleep(1);
    }
    const concurrentResults = await Promise.all([ firstStart, secondStart ]);
    assert.ok(concurrentResults.every(result => result?.committed === true));
    assert.equal(concurrentFilterFetches, 1);
    assert.equal(
        concurrentStart.messages.filter(message => message.what === 'insertCSS').length,
        1,
        `overlapping starts resolved ${resolutionOrder.join('-')} must share one activation`
    );
    assert.equal(scopeAttributes(concurrentStart).length, 1);
    await concurrentStart.runTerminate();
    assert.deepEqual(scopeAttributes(concurrentStart), []);
}

let heldBootstrapIdentity;
let bootstrapIdentityCount = 0;
const terminatedBootstrap = integratedCSSUserAPISandbox({
    autoStart: false,
    preloadCSSAPI: true,
    identityResponder(message, sandbox) {
        bootstrapIdentityCount += 1;
        if ( bootstrapIdentityCount === 1 ) {
            return new Promise(resolve => {
                heldBootstrapIdentity = { message, resolve, sandbox };
            });
        }
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
            documentId: sandbox.__documentId,
            frameId: sandbox.__frameId,
        });
    },
});
const staleBootstrap = terminatedBootstrap.runCSSUser();
while ( heldBootstrapIdentity === undefined ) { await sleep(1); }
await terminatedBootstrap.runTerminate();
heldBootstrapIdentity.resolve({
    ok: true,
    schema: 1,
    requestId: heldBootstrapIdentity.message.requestId,
    documentId: heldBootstrapIdentity.sandbox.__documentId,
    frameId: heldBootstrapIdentity.sandbox.__frameId,
});
assert.equal((await staleBootstrap).committed, false);
assert.equal(
    terminatedBootstrap.messages.some(message =>
        message.what === 'injectCustomFilters' || message.what === 'insertCSS'
    ),
    false,
    'termination during identity bootstrap must invalidate every late continuation'
);
assert.deepEqual(scopeAttributes(terminatedBootstrap), []);
assert.equal((await terminatedBootstrap.runCSSUser()).committed, true);
assert.equal(scopeAttributes(terminatedBootstrap).length, 1);

let retainedDocument;
let retainedFilterFetches = 0;
retainedDocument = integratedCSSUserAPISandbox({
    autoStart: false,
    preloadCSSAPI: true,
    customFilterResponder(message) {
        retainedFilterFetches += 1;
        return Promise.resolve(successfulAck(message, [ '#retained-document' ]));
    },
    injectAPIResponder(message) {
        retainedDocument.runCSSAPI();
        retainedDocument.runProceduralAPI();
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: message.requestId,
        });
    },
});
assert.equal((await retainedDocument.runCSSUser()).committed, true);
const firstRetainedAPI = retainedDocument.sandbox.cssAPI;
const firstRetainedRoot = retainedDocument.sandbox.document.documentElement;
assert.equal(scopeAttributes(retainedDocument).length, 1);
retainedDocument.sandbox.__documentId = 'integrated-document-b';
retainedDocument.sandbox.document.documentElement = mockDocumentElement();
assert.equal((await retainedDocument.runCSSUser()).committed, true);
assert.notEqual(retainedDocument.sandbox.cssAPI, firstRetainedAPI);
assert.deepEqual(firstRetainedRoot.attributeNames(), []);
assert.equal(scopeAttributes(retainedDocument).length, 1);
assert.equal(retainedFilterFetches, 2);
assert.equal(
    retainedDocument.messages.filter(message => message.what === 'insertCSS').length,
    2,
    'a retained global with a new native Document must install a fresh bundle'
);

function cssAPIAckSandbox(responder, options = {}) {
    const messages = [];
    const listeners = new Map();
    let monotonicNow = 0;
    let requestSequence = 0;
    const generation = {};
    const sandbox = {
        CSSStyleSheet: MockCSSStyleSheet,
        MutationObserver: MockMutationObserver,
        Uint32Array,
        clearTimeout,
        crypto: {
            getRandomValues(values) {
                requestSequence += 1;
                values.fill(requestSequence);
                return values;
            },
            randomUUID() {
                requestSequence += 1;
                return `css-ack-${requestSequence}`;
            },
        },
        Date,
        document: {
            documentElement: options.documentElement ?? mockDocumentElement(),
            location: { hostname: 'ack.example' },
        },
        getComputedStyle: mockScopedComputedStyle(
            messages,
            options.canaryResponder
        ),
        Math,
        performance: {
            get timeOrigin() { return 23; },
            now() {
                return options.realTime ? performance.now() : monotonicNow;
            },
        },
        setTimeout(callback, delay) {
            if ( options.realTime ) { return setTimeout(callback, delay); }
            if ( options.scaledTime ) {
                return setTimeout(( ) => {
                    monotonicNow += delay;
                    callback();
                }, Math.max(1, delay / 1000));
            }
            return setTimeout(( ) => {
                monotonicNow += delay;
                callback();
            }, 0);
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
    sandbox.__documentId = options.documentId ?? 'ack-document';
    sandbox.__frameId = options.frameId ?? 0;
    sandbox.cssUserDocumentGeneration = generation;
    sandbox.floorpCSSUserActivationState = {
        generation,
        deadline: sandbox.performance.now() + 15000,
        committed: false,
    };
    sandbox.chrome = {
        runtime: {
            sendMessage(message) {
                messages.push(structuredClone(message));
                if ( message.what === 'floorpCSSDocumentIdentity' ) {
                    if ( options.identityResponder ) {
                        return options.identityResponder(message, sandbox);
                    }
                    return Promise.resolve({
                        ok: true,
                        schema: 1,
                        requestId: message.requestId,
                        documentId: sandbox.__documentId,
                        frameId: sandbox.__frameId,
                    });
                }
                return Promise.resolve(responder(message, sandbox)).then(value => {
                    if (
                        options.preserveDocumentId !== true &&
                        typeof value === 'object' &&
                        value !== null &&
                        value.schema === 1 &&
                        value.requestId === message.requestId
                    ) {
                        return {
                            ...value,
                            documentId: sandbox.__documentId,
                            frameId: sandbox.__frameId,
                            ...(message.what === 'insertCSS' && value.ok === true
                                ? { ensured: true }
                                : {}),
                        };
                    }
                    return value;
                });
            },
        },
    };
    const context = vm.createContext(sandbox);
    new vm.Script(cssAPISource, {
        filename: 'js/scripting/css-api.js',
    }).runInContext(context);
    sandbox.advanceMonotonic = delay => {
        monotonicNow += delay;
    };
    return {
        advance: sandbox.advanceMonotonic,
        context,
        async dispatch(type, event = { type }) {
            const listener = listeners.get(type);
            if ( typeof listener === 'function' ) { listener(event); }
            await sleep(20);
        },
        generation,
        listeners,
        messages,
        sandbox,
    };
}

let transientInsertAttempt = 0;
const recoveredCSS = cssAPIAckSandbox(message => {
    transientInsertAttempt += 1;
    return Promise.resolve({
        ok: transientInsertAttempt >= 3,
        schema: 1,
        requestId: message.requestId,
        error: transientInsertAttempt < 3 ? 'target not ready' : undefined,
    });
}, { realTime: true });
const recoveredCSSReply = await recoveredCSS.sandbox.cssAPI.insert(
    '#recover{display:none!important}',
    { generation: recoveredCSS.generation, owner: recoveredCSS.generation }
);
const recoveredInsertMessages = cssProtocolMessages(recoveredCSS, 'insertCSS');
assert.equal(recoveredCSSReply.ok, true);
assert.equal(recoveredInsertMessages.length, 3);
assert.equal(
    new Set(recoveredInsertMessages.map(message => message.requestId)).size,
    3,
    'each retry acknowledgement must be request-bound'
);
assert.equal(
    new Set(recoveredInsertMessages.map(message => message.css)).size,
    1,
    'request-bound negative acknowledgements retry one inert candidate payload'
);
assert.equal(scopeAttributes(recoveredCSS).length, 1);

const nativeNoOpCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}), {
    canaryResponder: ( ) => false,
});
const nativeNoOpResult = await nativeNoOpCSS.sandbox.cssAPI.insert(
    '#ack-without-effect{display:none!important}'
);
assert.equal(nativeNoOpResult.ok, false);
assert.match(nativeNoOpResult.error, /canary/);
assert.deepEqual(
    scopeAttributes(nativeNoOpCSS),
    [],
    'a native success acknowledgement without a live USER sheet must stay inert'
);
assert.ok(
    nativeNoOpCSS.sandbox.performance.now() <= 500,
    'a missing native canary must settle within the bounded confirmation window'
);

let delayedCanaryChecks = 0;
const delayedCanaryCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}), {
    canaryResponder() {
        delayedCanaryChecks += 1;
        return delayedCanaryChecks >= 3;
    },
});
const delayedCanaryResult = await delayedCanaryCSS.sandbox.cssAPI.insert(
    '#delayed-canary{display:none!important}'
);
assert.equal(delayedCanaryResult.ok, true);
assert.equal(delayedCanaryChecks, 3);
assert.equal(delayedCanaryCSS.sandbox.performance.now(), 50);
assert.equal(scopeAttributes(delayedCanaryCSS).length, 1);

let pendingCandidateRemoval;
const pendingCandidateRoot = mockDocumentElement({
    onSetAttribute(root, name) {
        if (
            pendingCandidateRemoval === undefined &&
            name.startsWith('data-floorp-ubol-')
        ) {
            pendingCandidateRemoval = name;
            queueMicrotask(( ) => root.removeAttribute(name));
        }
    },
});
let recoveredCandidateChecks = 0;
const recoveredCandidateCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}), {
    documentElement: pendingCandidateRoot,
    canaryResponder() {
        recoveredCandidateChecks += 1;
        return recoveredCandidateChecks >= 2;
    },
});
const recoveredCandidateResult = await recoveredCandidateCSS.sandbox.cssAPI.insert(
    '#candidate-marker-recovery{display:none!important}'
);
assert.equal(recoveredCandidateResult.ok, true);
assert.ok(recoveredCandidateChecks >= 2);
assert.equal(scopeAttributes(recoveredCandidateCSS).length, 1);
assert.equal(cssProtocolMessages(recoveredCandidateCSS, 'insertCSS').length, 1);
assert.equal(cssProtocolMessages(recoveredCandidateCSS, 'removeCSS').length, 0);

let suspendedCandidateCSS;
let suspendedCandidateSets = 0;
const suspendedCandidateRoot = mockDocumentElement({
    onSetAttribute(_root, name) {
        if ( name.startsWith('data-floorp-ubol-') === false ) { return; }
        suspendedCandidateSets += 1;
        if ( suspendedCandidateSets !== 1 ) { return; }
        queueMicrotask(( ) => {
            const record = {};
            suspendedCandidateCSS.sandbox.floorpCSSUserIdentityPendingRecord =
                record;
            suspendedCandidateCSS.sandbox.cssAPI.suspendForIdentity(record);
        });
    },
});
suspendedCandidateCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}), {
    documentElement: suspendedCandidateRoot,
    canaryResponder: ( ) => false,
});
const suspendedCandidateResult = await suspendedCandidateCSS.sandbox.cssAPI.insert(
    '#suspended-candidate-must-stay-inert{display:none!important}'
);
assert.equal(suspendedCandidateResult.ok, false);
assert.match(suspendedCandidateResult.error, /authority/);
assert.equal(suspendedCandidateSets, 1);
assert.deepEqual(scopeAttributes(suspendedCandidateCSS), []);

let promotedCandidateRemoval;
const promotedCandidateRoot = mockDocumentElement({
    onSetAttribute(root, name) {
        if (
            promotedCandidateRemoval === undefined &&
            name.startsWith('data-floorp-ubol-')
        ) {
            promotedCandidateRemoval = name;
            queueMicrotask(( ) => root.removeAttribute(name));
        }
    },
});
const repairedPromotionCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}), { documentElement: promotedCandidateRoot });
const repairedPromotionResult = await repairedPromotionCSS.sandbox.cssAPI.insert(
    '#promoted-marker-recovery{display:none!important}'
);
assert.equal(repairedPromotionResult.ok, true);
assert.equal(scopeAttributes(repairedPromotionCSS).length, 1);
assert.equal(cssProtocolMessages(repairedPromotionCSS, 'insertCSS').length, 1);
assert.equal(cssProtocolMessages(repairedPromotionCSS, 'removeCSS').length, 0);

mockMutationObservers.length = 0;
const activeMarkerRepairCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
assert.equal((await activeMarkerRepairCSS.sandbox.cssAPI.insert(
    '#active-marker-recovery{display:none!important}'
)).ok, true);
const activeMarker = scopeAttributes(activeMarkerRepairCSS)[0];
const activeRoot = activeMarkerRepairCSS.sandbox.document.documentElement;
activeRoot.removeAttribute(activeMarker);
const activeMarkerObserver = mockMutationObservers.find(observer =>
    observer.registrations.some(registration =>
        registration.target === activeRoot &&
        registration.options.attributeFilter?.includes(activeMarker)
    )
);
assert.ok(activeMarkerObserver);
activeMarkerObserver.callback();
assert.deepEqual(scopeAttributes(activeMarkerRepairCSS), [ activeMarker ]);

for ( const [ label, responder ] of [
    [ 'missing', ( ) => Promise.resolve(undefined) ],
    [ 'malformed', ( ) => Promise.resolve({ ok: true }) ],
    [ 'runtime rejection', ( ) => Promise.reject(new Error('wake failed')) ],
] ) {
    const ambiguousCSS = cssAPIAckSandbox(responder);
    const owner = ambiguousCSS.generation;
    const firstResult = await ambiguousCSS.sandbox.cssAPI.insert(
        `#ambiguous-${label.replaceAll(' ', '-')}{display:none!important}`,
        { generation: owner, owner }
    );
    assert.equal(firstResult.ok, false);
    assert.equal(firstResult.ambiguous, true);
    assert.equal(cssProtocolMessages(ambiguousCSS, 'insertCSS').length, 1);
    assert.deepEqual(scopeAttributes(ambiguousCSS), []);
    await sleep(20);
    assert.equal(
        cssProtocolMessages(ambiguousCSS, 'insertCSS').length,
        1,
        `${label} must not cause an automatic ambiguous resend`
    );
    await ambiguousCSS.dispatch('pagereveal');
    const replayAttempts = cssProtocolMessages(ambiguousCSS, 'insertCSS');
    assert.equal(replayAttempts.length, 2);
    assert.notEqual(
        replayAttempts[0].scopeAttribute,
        replayAttempts[1].scopeAttribute,
        'an explicit lifecycle retry must use a new private inert candidate'
    );
    assert.deepEqual(scopeAttributes(ambiguousCSS), []);
}

let deadlineInsertAttempt = 0;
const callerDeadlineCSS = cssAPIAckSandbox(message => {
    deadlineInsertAttempt += 1;
    if ( deadlineInsertAttempt === 1 ) { return new Promise(( ) => {}); }
    return Promise.resolve({ ok: true, schema: 1, requestId: message.requestId });
}, { realTime: true });
const shortDeadlineOwner = callerDeadlineCSS.generation;
const shortDeadlineOperation = callerDeadlineCSS.sandbox.cssAPI.insert(
    '#short-deadline{display:none!important}',
    {
        deadline: callerDeadlineCSS.sandbox.performance.now() + 40,
        generation: shortDeadlineOwner,
        owner: shortDeadlineOwner,
    }
);
const laterRevisionOperation = callerDeadlineCSS.sandbox.cssAPI.insert(
    '#later-revision{display:none!important}',
    {
        deadline: callerDeadlineCSS.sandbox.performance.now() + 500,
        generation: shortDeadlineOwner,
        owner: shortDeadlineOwner,
    }
);
assert.equal((await shortDeadlineOperation).ok, false);
const laterRevisionResult = await laterRevisionOperation;
assert.equal(laterRevisionResult.ok, true);
const revisionInsertMessages = cssProtocolMessages(callerDeadlineCSS, 'insertCSS');
assert.equal(revisionInsertMessages.length, 2);
assert.match(revisionInsertMessages[1].css, /#short-deadline/);
assert.match(revisionInsertMessages[1].css, /#later-revision/);

const stagedProceduralCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
const failedConstructionTransaction =
    stagedProceduralCSS.sandbox.cssAPI.beginInsertionTransaction(
        stagedProceduralCSS.generation,
        15000,
        stagedProceduralCSS.generation,
        'custom'
    );
const stagedReply = await stagedProceduralCSS.sandbox.cssAPI.insert(
    '#partial-procedural{display:none!important}'
);
assert.equal(stagedReply.staged, true);
stagedProceduralCSS.sandbox.cssAPI.rollbackInsertionTransaction(
    failedConstructionTransaction
);
await stagedProceduralCSS.dispatch('pagereveal');
assert.deepEqual(
    stagedProceduralCSS.messages.filter(message =>
        message.what === 'insertCSS' || message.what === 'removeCSS'
    ),
    [],
    'rolled-back construction must have no native side effects or replay state'
);

const orderedBundleCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
const orderedTransaction = orderedBundleCSS.sandbox.cssAPI
    .beginInsertionTransaction(
        orderedBundleCSS.generation,
        15000,
        orderedBundleCSS.generation,
        'custom'
    );
await orderedBundleCSS.sandbox.cssAPI.insert('#z-first{color:red!important}');
await orderedBundleCSS.sandbox.cssAPI.insert('#a-second{color:blue!important}');
await orderedBundleCSS.sandbox.cssAPI.insert('#z-first{color:red!important}');
orderedBundleCSS.sandbox.cssAPI.finishInsertionTransaction(orderedTransaction);
assert.equal((await orderedBundleCSS.sandbox.cssAPI.commit(
    orderedBundleCSS.generation,
    orderedBundleCSS.generation,
    15000
)).ok, true);
const orderedNativeInserts = cssProtocolMessages(orderedBundleCSS, 'insertCSS');
assert.equal(orderedNativeInserts.length, 1);
assert.ok(
    orderedNativeInserts[0].css.indexOf('#z-first') <
        orderedNativeInserts[0].css.indexOf('#a-second'),
    'one owner bundle must preserve first insertion order for cascade semantics'
);
assert.equal(
    orderedNativeInserts[0].css.match(/#z-first/g).length,
    2,
    'a duplicate input rule must still produce only its descendant/self branches'
);
const orderedBundleMessage = orderedNativeInserts[0];
assert.notEqual(
    orderedBundleMessage.scopeCanaryValue.slice('floorp-'.length),
    orderedBundleMessage.scopeAttribute.slice('data-floorp-ubol-'.length),
    'the native-effect canary value must be independent from its observable marker'
);

const flatTransformCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
const complexScopedSource = `
html body #floorp-custom-form-control,
:root,
:scope,
input:is([data-value="a,b"], #escaped\\,comma),
a:not(.one,.two),
section:has(> .child,.other),
li:nth-child(2n of .odd,.even),
.pseudo::before,
.legacy:after,
.columns || ::first-line { display:none!important; }
@media (min-width: 1px) {
    input, html::before { color:red!important; }
}
@supports selector(:has(*)) {
    #supported:not(.a,.b) { visibility:hidden!important; }
}
@container sidebar (width > 1px) {
    #contained::after { content:"a,b"!important; }
}`;
assert.equal((await flatTransformCSS.sandbox.cssAPI.insert(
    complexScopedSource
)).ok, true);
const flatTransformMessage = cssProtocolMessages(flatTransformCSS, 'insertCSS')[0];
const flatPayload = flatTransformMessage.css;
const flatWrapper =
    `:where(:root[${flatTransformMessage.scopeAttribute}])`;
assert.ok(flatPayload.startsWith(
    `${flatWrapper} {\n` +
    `${flatTransformMessage.scopeCanary}: ` +
    `${flatTransformMessage.scopeCanaryValue} !important;\n}\n`
));
for ( const suffix of [
    ' :is(html body #floorp-custom-form-control)',
    ':is(html body #floorp-custom-form-control)',
    ' :is(:root)',
    ':is(:root)',
    ' :is(:scope)',
    ':is(:scope)',
    ' :is(input:is([data-value="a,b"], #escaped\\,comma))',
    ' :is(a:not(.one,.two))',
    ' :is(section:has(> .child,.other))',
    ' :is(li:nth-child(2n of .odd,.even))',
    ' :is(.pseudo)::before',
    ':is(.legacy):after',
    ' :is(.columns || *)::first-line',
] ) {
    const fragment = `${flatWrapper}${suffix}`;
    assert.match(
        flatPayload,
        new RegExp(fragment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
        `flat document scope must preserve ${fragment}`
    );
}
for ( const fragment of [
    '@media (min-width: 1px)',
    '@supports selector(:has(*))',
    '@container sidebar (width > 1px)',
] ) {
    assert.match(
        flatPayload,
        new RegExp(fragment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
        `flat document scope must preserve ${fragment}`
    );
}
assert.equal(
    flatPayload.includes('@scope'),
    false,
    'the form-control path must not depend on WebKit @scope behavior'
);
assert.equal(
    flatPayload.includes('&'),
    false,
    'iOS 26 effect rules must not depend on qualified-rule nesting'
);

const ios26FlatEffects = ios26TopLevelEffectRules(flatPayload);
assert.equal(ios26FlatEffects[0].selectorText, flatWrapper);
assert.equal(
    ios26FlatEffects[0].style.getPropertyValue(
        flatTransformMessage.scopeCanary
    ),
    flatTransformMessage.scopeCanaryValue,
    'the standalone native-effect canary must remain observable'
);
const ios26FlatSelectors = ios26FlatEffects
    .slice(1)
    .map(rule => rule.selectorText)
    .join('\n');
for ( const selector of [
    `${flatWrapper} :is(html body #floorp-custom-form-control)`,
    `${flatWrapper}:is(:root)`,
    `${flatWrapper} :is(input)`,
    `${flatWrapper} :is(#supported:not(.a,.b))`,
    `${flatWrapper} :is(#contained)::after`,
] ) {
    assert.ok(
        ios26FlatSelectors.includes(selector),
        `iOS 26 top-level-only native effects must include ${selector}`
    );
}
assert.equal(
    ios26FlatEffects.every(rule => (rule.cssRules?.length ?? 0) === 0),
    true,
    'no native effect may be nested inside a qualified style rule'
);

const legacyNestedPayload = exactNestedScopedCSS('#ios26-nested-effect');
const legacyNestedRoot = mockDocumentElement();
legacyNestedRoot.setAttribute(exactScopeAttribute, '');
const legacyNestedCanary = mockScopedComputedStyle([ {
    what: 'insertCSS',
    css: legacyNestedPayload,
} ])(legacyNestedRoot).getPropertyValue(exactScopeCanary);
assert.equal(
    legacyNestedCanary,
    exactScopeCanaryValue,
    'the old nested payload demonstrates the iOS 26 canary false positive'
);
assert.equal(
    ios26TopLevelEffectRules(legacyNestedPayload).some(rule =>
        rule.selectorText?.includes('#ios26-nested-effect')
    ),
    false,
    'iOS 26 must not count a nested qualified rule as an applied effect'
);

const candidateResolvers = [];
const atomicCandidateCSS = cssAPIAckSandbox((message, sandbox) => {
    if ( message.what === 'removeCSS' ) {
        return Promise.resolve({ ok: true, schema: 1, requestId: message.requestId });
    }
    return new Promise(resolve => candidateResolvers.push({ message, resolve, sandbox }));
}, { realTime: true });
const atomicOwner = atomicCandidateCSS.generation;
const firstAtomicInsert = atomicCandidateCSS.sandbox.cssAPI.insert(
    '#atomic-a{display:none!important}',
    { generation: atomicOwner, owner: atomicOwner }
);
while ( candidateResolvers.length === 0 ) { await sleep(1); }
assert.deepEqual(scopeAttributes(atomicCandidateCSS), []);
candidateResolvers[0].resolve({
    ok: true,
    schema: 1,
    requestId: candidateResolvers[0].message.requestId,
});
assert.equal((await firstAtomicInsert).ok, true);
const firstAtomicAttribute = scopeAttributes(atomicCandidateCSS)[0];
assert.ok(firstAtomicAttribute);
const secondAtomicInsert = atomicCandidateCSS.sandbox.cssAPI.insert(
    '#atomic-b{display:none!important}',
    { generation: atomicOwner, owner: atomicOwner }
);
while ( candidateResolvers.length < 2 ) { await sleep(1); }
assert.deepEqual(scopeAttributes(atomicCandidateCSS), [ firstAtomicAttribute ]);
candidateResolvers[1].resolve({
    ok: true,
    schema: 1,
    requestId: candidateResolvers[1].message.requestId,
});
assert.equal((await secondAtomicInsert).ok, true);
const secondAtomicAttributes = scopeAttributes(atomicCandidateCSS);
assert.equal(secondAtomicAttributes.length, 1);
assert.notEqual(secondAtomicAttributes[0], firstAtomicAttribute);
assert.match(candidateResolvers[1].message.css, /#atomic-a/);
assert.match(candidateResolvers[1].message.css, /#atomic-b/);

const isolatedOwnersCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
const duplicateRawCSS = '#owner-isolation{display:none!important}';
assert.equal((await isolatedOwnersCSS.sandbox.cssAPI.insert(duplicateRawCSS)).ok, true);
const customIsolatedOwner = isolatedOwnersCSS.generation;
assert.equal((await isolatedOwnersCSS.sandbox.cssAPI.insert(duplicateRawCSS, {
    generation: customIsolatedOwner,
    lane: 'custom',
    owner: customIsolatedOwner,
})).ok, true);
const isolatedInserts = cssProtocolMessages(isolatedOwnersCSS, 'insertCSS');
assert.equal(isolatedInserts.length, 2);
assert.notEqual(isolatedInserts[0].css, isolatedInserts[1].css);
assert.equal(scopeAttributes(isolatedOwnersCSS).length, 2);
assert.equal((await isolatedOwnersCSS.sandbox.cssAPI.forgetOwner(
    customIsolatedOwner,
    customIsolatedOwner
)).ok, true);
assert.equal(scopeAttributes(isolatedOwnersCSS).length, 1);
assert.equal(
    cssProtocolMessages(isolatedOwnersCSS, 'removeCSS').at(-1).css,
    isolatedInserts[1].css,
    'custom termination must remove only its private exact payload'
);

const laneOrderingCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
await laneOrderingCSS.sandbox.cssAPI.insert('#base-first{color:red!important}');
const previewOwner = {};
await laneOrderingCSS.sandbox.cssAPI.insert('#preview-last{color:blue!important}', {
    generation: laneOrderingCSS.generation,
    lane: 'preview',
    owner: previewOwner,
});
const beforeLaneUpdate = cssProtocolMessages(laneOrderingCSS, 'insertCSS').length;
await laneOrderingCSS.sandbox.cssAPI.insert('#base-update{color:green!important}');
const laneUpdateMessages = cssProtocolMessages(laneOrderingCSS, 'insertCSS')
    .slice(beforeLaneUpdate);
assert.equal(laneUpdateMessages.length, 2);
assert.match(laneUpdateMessages[0].css, /#base-update/);
assert.match(laneUpdateMessages[1].css, /#preview-last/);

const bfcacheOwner = {};
const bfcacheCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
await bfcacheCSS.sandbox.cssAPI.insert('#bfcache{display:none!important}', {
    generation: bfcacheCSS.generation,
    owner: bfcacheOwner,
});
assert.equal(scopeAttributes(bfcacheCSS).length, 1);
bfcacheCSS.listeners.get('pagehide')({ type: 'pagehide', persisted: true });
assert.deepEqual(scopeAttributes(bfcacheCSS), []);
for ( let reveal = 0; reveal < 3; reveal += 1 ) {
    if ( reveal !== 0 ) {
        bfcacheCSS.listeners.get('pagehide')({
            type: 'pagehide',
            persisted: true,
        });
    }
    const firstEvent = reveal % 2 === 0 ? 'pagereveal' : 'pageshow';
    const secondEvent = firstEvent === 'pagereveal' ? 'pageshow' : 'pagereveal';
    await bfcacheCSS.dispatch(firstEvent, {
        type: firstEvent,
        persisted: firstEvent === 'pageshow',
    });
    await bfcacheCSS.dispatch(secondEvent, {
        type: secondEvent,
        persisted: secondEvent === 'pageshow',
    });
    assert.equal(scopeAttributes(bfcacheCSS).length, 1);
}
assert.equal(
    cssProtocolMessages(bfcacheCSS, 'insertCSS').length,
    4,
    'each BFCache reveal must serialize one fresh inert candidate publication'
);
assert.equal((await bfcacheCSS.sandbox.cssAPI.forgetOwner(
    bfcacheOwner,
    bfcacheCSS.generation
)).ok, true);
assert.deepEqual(scopeAttributes(bfcacheCSS), []);

for ( const invalidCSS of [
    '@import url(https://invalid.example/style.css);',
    '@import url(https://invalid.example/style.css); #otherwise-valid{display:none}',
    '@charset "utf-8"; #otherwise-valid{display:none}',
    '@namespace svg url(http://www.w3.org/2000/svg); #otherwise-valid{display:none}',
    '@font-face{font-family:x;src:url(x)}',
    '@keyframes x{from{opacity:0}to{opacity:1}}',
    '@layer floorp{#x{display:none}}',
    '@scope (:root){#x{display:none}}',
    '@unknown test{#x{display:none}}',
    '#valid{display:none} }',
    '#valid{display:none} #truncated{',
    ':is(){display:none}',
    '#authored{ & .nested{display:none} }',
] ) {
    const rejectedCSS = cssAPIAckSandbox(message => Promise.resolve({
        ok: true,
        schema: 1,
        requestId: message.requestId,
    }));
    const rejected = await rejectedCSS.sandbox.cssAPI.insert(invalidCSS);
    assert.equal(rejected.ok, false, invalidCSS);
    assert.equal(cssProtocolMessages(rejectedCSS, 'insertCSS').length, 0);
}

let heldIdentityResolve;
let identityAttempt = 0;
const rootBoundIdentityCSS = cssAPIAckSandbox(
    message => Promise.resolve({ ok: true, schema: 1, requestId: message.requestId }),
    {
        realTime: true,
        identityResponder(message, sandbox) {
            identityAttempt += 1;
            if ( identityAttempt === 1 ) {
                return new Promise(resolve => { heldIdentityResolve = resolve; });
            }
            return Promise.resolve({
                ok: true,
                schema: 1,
                requestId: message.requestId,
                documentId: sandbox.__documentId,
                frameId: sandbox.__frameId,
            });
        },
    }
);
const oldRoot = rootBoundIdentityCSS.sandbox.document.documentElement;
const rootBoundInsert = rootBoundIdentityCSS.sandbox.cssAPI.insert(
    '#root-bound{display:none!important}'
);
while ( typeof heldIdentityResolve !== 'function' ) { await sleep(1); }
const newRoot = mockDocumentElement();
rootBoundIdentityCSS.sandbox.document.documentElement = newRoot;
rootBoundIdentityCSS.sandbox.__documentId = 'replacement-document';
heldIdentityResolve({
    ok: true,
    schema: 1,
    requestId: cssProtocolMessages(rootBoundIdentityCSS, 'floorpCSSDocumentIdentity')[0]
        .requestId,
    documentId: 'old-document',
    frameId: 0,
});
assert.equal((await rootBoundInsert).ok, true);
assert.deepEqual(oldRoot.attributeNames(), []);
assert.equal(scopeAttributes(rootBoundIdentityCSS).length, 1);
assert.equal(cssProtocolMessages(rootBoundIdentityCSS, 'insertCSS').length, 1);

const replacedRootCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
const replacedRootAPI = replacedRootCSS.sandbox.cssAPI;
await replacedRootAPI.insert('#replace-root{display:none!important}');
const detachedRoot = replacedRootCSS.sandbox.document.documentElement;
assert.equal(detachedRoot.attributeNames().length, 1);
replacedRootCSS.sandbox.document.documentElement = mockDocumentElement();
replacedRootCSS.sandbox.document.location.href =
    'https://ack.example/same-document#history-state';
assert.equal((await replacedRootAPI.refreshForScriptExecution()).ok, true);
assert.equal(replacedRootCSS.sandbox.cssAPI, replacedRootAPI);
assert.deepEqual(
    detachedRoot.attributeNames(),
    [],
    'a retained old root must lose every private capability marker'
);
assert.equal(scopeAttributes(replacedRootCSS).length, 1);

const proceduralResumeCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
const proceduralNode = mockDocumentElement();
const changingStyleNode = mockDocumentElement();
let changingStylePhase = 'blue';
let proceduralQueryCount = 0;
let proceduralMediaCallback;
let proceduralFrameRequests = 0;
proceduralResumeCSS.sandbox.console = console;
proceduralResumeCSS.sandbox.window = proceduralResumeCSS.sandbox;
proceduralResumeCSS.sandbox.window.matchMedia = ( ) => ({
    media: 'all',
    matches: true,
    addEventListener(type, callback) {
        if ( type === 'change' ) { proceduralMediaCallback = callback; }
    },
    removeEventListener() {},
});
proceduralResumeCSS.sandbox.document.querySelectorAll = selector => {
    proceduralQueryCount += 1;
    if ( selector === '#procedural-resume' ) { return [ proceduralNode ]; }
    if ( selector === '#style-red' && changingStylePhase === 'red' ) {
        return [ changingStyleNode ];
    }
    if ( selector === '#style-blue' && changingStylePhase === 'blue' ) {
        return [ changingStyleNode ];
    }
    return [];
};
proceduralResumeCSS.sandbox.requestAnimationFrame = callback => {
    proceduralFrameRequests += 1;
    proceduralResumeCSS.sandbox.__pendingFrame = callback;
    return 1;
};
proceduralResumeCSS.sandbox.cancelAnimationFrame = ( ) => {
    proceduralResumeCSS.sandbox.__pendingFrame = undefined;
};
new vm.Script(proceduralAPISource, {
    filename: 'js/scripting/css-procedural-api.js',
}).runInContext(proceduralResumeCSS.context);
const proceduralOwner = {};
const proceduralAPI = new proceduralResumeCSS.sandbox.ProceduralFiltererAPI({
    cssGeneration: proceduralResumeCSS.generation,
    cssLane: 'custom',
    cssOwner: proceduralOwner,
});
proceduralAPI.addProcedurals([ {
    raw: '#procedural-resume',
    selector: '#procedural-resume',
    tasks: [ [ 'matches-media', 'all' ] ],
} ]);
assert.equal((await proceduralResumeCSS.sandbox.cssAPI.commit(
    proceduralResumeCSS.generation,
    proceduralOwner,
    15000
)).ok, true);
const liveProceduralFilterer = proceduralAPI.proceduralFilterer;
const liveStyleToken = proceduralNode.attributeNames()[0];
const liveProceduralPayload = cssProtocolMessages(
    proceduralResumeCSS,
    'insertCSS'
)[0].css;
assert.ok(liveStyleToken);
assert.match(liveProceduralPayload, new RegExp(`\\[${liveStyleToken}\\]`));
const proceduralIdentityRecord = {};
proceduralResumeCSS.sandbox.floorpCSSUserIdentityPendingRecord =
    proceduralIdentityRecord;
proceduralResumeCSS.sandbox.cssAPI.suspendForIdentity(proceduralIdentityRecord);
assert.equal(proceduralAPI.proceduralFilterer, liveProceduralFilterer);
assert.deepEqual(proceduralNode.attributeNames(), [ liveStyleToken ]);
const queryCountBeforeSuspendedCallback = proceduralQueryCount;
proceduralMediaCallback();
liveProceduralFilterer.uBOL_DOMChanged();
assert.equal(proceduralFrameRequests, 0);
assert.equal(proceduralQueryCount, queryCountBeforeSuspendedCallback);
assert.equal(
    proceduralResumeCSS.sandbox.cssAPI.resumeForIdentity(
        proceduralIdentityRecord,
        'ack-document',
        0
    ),
    true
);
assert.equal(proceduralAPI.proceduralFilterer, liveProceduralFilterer);
assert.deepEqual(proceduralNode.attributeNames(), [ liveStyleToken ]);
assert.ok(
    proceduralQueryCount > queryCountBeforeSuspendedCallback,
    'procedural resume must run one fresh authenticated commit'
);
assert.equal(
    cssProtocolMessages(proceduralResumeCSS, 'insertCSS').length,
    1,
    'same-Document identity refresh must retain one procedural token bundle'
);
proceduralAPI.addProcedurals([
    {
        action: [ 'style', 'color:red!important;' ],
        raw: '#style-red:style(color:red)',
        selector: '#style-red',
    },
    {
        action: [ 'style', 'color:blue!important;' ],
        raw: '#style-blue:style(color:blue)',
        selector: '#style-blue',
    },
]);
assert.equal((await proceduralResumeCSS.sandbox.cssAPI.commit(
    proceduralResumeCSS.generation,
    proceduralOwner,
    proceduralResumeCSS.sandbox.performance.now() + 15000
)).ok, true);
const redStyleToken = liveProceduralFilterer.styleTokenMap.get(
    'color:red!important;'
);
const blueStyleToken = liveProceduralFilterer.styleTokenMap.get(
    'color:blue!important;'
);
assert.deepEqual(changingStyleNode.attributeNames(), [ blueStyleToken ]);
changingStylePhase = 'red';
liveProceduralFilterer.uBOL_commit();
assert.deepEqual(
    changingStyleNode.attributeNames(),
    [ redStyleToken ],
    'style-token cleanup must be tracked per token when a node changes action'
);
const disposingIdentityRecord = {};
proceduralResumeCSS.sandbox.floorpCSSUserIdentityPendingRecord =
    disposingIdentityRecord;
proceduralResumeCSS.sandbox.cssAPI.suspendForIdentity(disposingIdentityRecord);
proceduralResumeCSS.sandbox.cssAPI.dispose();
assert.equal(proceduralAPI.proceduralFilterer, null);
assert.deepEqual(
    proceduralNode.attributeNames(),
    [],
    'actual API replacement must fully remove retained procedural tokens'
);

const reusablePreviewCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}));
const previewFirstNode = mockDocumentElement();
const previewSecondNode = mockDocumentElement();
const previewExistingTokenNode = mockDocumentElement();
const previewRemoveNode = {
    ...mockDocumentElement(),
    removed: false,
    textContent: 'advertisement',
    remove() { this.removed = true; },
};
reusablePreviewCSS.sandbox.console = console;
reusablePreviewCSS.sandbox.window = reusablePreviewCSS.sandbox;
reusablePreviewCSS.sandbox.document.querySelectorAll = selector => ({
    '#preview-first': [ previewFirstNode ],
    '#preview-second': [ previewSecondNode ],
    '#preview-existing-token': [ previewExistingTokenNode ],
    '#preview-remove': [ previewRemoveNode ],
})[selector] ?? [];
reusablePreviewCSS.sandbox.requestAnimationFrame = ( ) => 1;
reusablePreviewCSS.sandbox.cancelAnimationFrame = ( ) => {};
new vm.Script(proceduralAPISource, {
    filename: 'js/scripting/css-procedural-api.js',
}).runInContext(reusablePreviewCSS.context);
const previewOwnerLifecycle = {};
const reusablePreviewAPI =
    new reusablePreviewCSS.sandbox.ProceduralFiltererAPI({
        cssGeneration: reusablePreviewCSS.generation,
        cssLane: 'preview',
        cssOwner: previewOwnerLifecycle,
    });
reusablePreviewAPI.addProcedurals([ {
    raw: '#preview-first',
    selector: '#preview-first',
} ]);
assert.equal((await reusablePreviewCSS.sandbox.cssAPI.commit(
    reusablePreviewCSS.generation,
    previewOwnerLifecycle,
    15000
)).ok, true);
assert.equal(previewFirstNode.attributeNames().length, 1);
assert.equal((await reusablePreviewAPI.reset()).ok, true);
assert.deepEqual(previewFirstNode.attributeNames(), []);
assert.deepEqual(scopeAttributes(reusablePreviewCSS), []);

reusablePreviewAPI.addProcedurals([ {
    raw: '#preview-second',
    selector: '#preview-second',
} ]);
assert.equal((await reusablePreviewCSS.sandbox.cssAPI.commit(
    reusablePreviewCSS.generation,
    previewOwnerLifecycle,
    reusablePreviewCSS.sandbox.performance.now() + 15000
)).ok, true);
const reusedHideToken = previewSecondNode.attributeNames()[0];
assert.ok(reusedHideToken);
const insertsBeforeExistingToken = cssProtocolMessages(
    reusablePreviewCSS,
    'insertCSS'
).length;
reusablePreviewAPI.addProcedurals([ {
    raw: '#preview-existing-token',
    selector: '#preview-existing-token',
} ]);
assert.equal((await reusablePreviewCSS.sandbox.cssAPI.commit(
    reusablePreviewCSS.generation,
    previewOwnerLifecycle,
    reusablePreviewCSS.sandbox.performance.now() + 15000
)).ok, true);
assert.deepEqual(previewExistingTokenNode.attributeNames(), [ reusedHideToken ]);
assert.equal(
    cssProtocolMessages(reusablePreviewCSS, 'insertCSS').length,
    insertsBeforeExistingToken + 1,
    'an existing hide token still requires a fresh procedural activation intent'
);
reusablePreviewAPI.addProcedurals([ {
    action: [ 'remove' ],
    raw: '#preview-remove:remove()',
    selector: '#preview-remove',
} ]);
assert.equal((await reusablePreviewCSS.sandbox.cssAPI.commit(
    reusablePreviewCSS.generation,
    previewOwnerLifecycle,
    reusablePreviewCSS.sandbox.performance.now() + 15000
)).ok, true);
assert.equal(
    previewRemoveNode.removed,
    true,
    'a non-style procedural update must not be skipped by a CSS fingerprint fast path'
);

const cancelledIdentityCSS = cssAPIAckSandbox(message => Promise.resolve({
    ok: true,
    schema: 1,
    requestId: message.requestId,
}), { realTime: true });
const cancelledIdentityRecord = {};
cancelledIdentityCSS.sandbox.floorpCSSUserIdentityPendingRecord =
    cancelledIdentityRecord;
cancelledIdentityCSS.sandbox.cssAPI.suspendForIdentity(cancelledIdentityRecord);
const insertionWaitingForCancelledIdentity =
    cancelledIdentityCSS.sandbox.cssAPI.insert(
        '#cancelled-identity{display:none!important}'
    );
cancelledIdentityCSS.sandbox.cssAPI.cancelIdentity(cancelledIdentityRecord);
const cancelledIdentityResult = await Promise.race([
    insertionWaitingForCancelledIdentity,
    sleep(100).then(( ) => ({ timedOut: true })),
]);
assert.notEqual(cancelledIdentityResult.timedOut, true);
assert.equal(cancelledIdentityResult.ok, false);
assert.equal(cssProtocolMessages(cancelledIdentityCSS, 'insertCSS').length, 0);
assert.deepEqual(scopeAttributes(cancelledIdentityCSS), []);

let hookMustFail = false;
let hookContext;
const hookCSS = cssAPIAckSandbox((message, sandbox) => {
    if ( message.what === 'injectCSSProceduralAPI' ) {
        hookMustFail = false;
        new vm.Script(cssAPISource, {
            filename: 'js/scripting/css-api.js',
        }).runInContext(hookContext);
        new vm.Script(proceduralAPISource, {
            filename: 'js/scripting/css-procedural-api.js',
        }).runInContext(hookContext);
    }
    return Promise.resolve({
        ok: true,
        schema: 1,
        requestId: message.requestId,
    });
});
hookContext = hookCSS.context;
const hookOwnerA = hookCSS.generation;
const hookOwnerB = {};
const hookCounts = {
    aActivate: 0,
    aDeactivate: 0,
    aSuspend: 0,
    bActivate: 0,
    bDeactivate: 0,
    bSuspend: 0,
};
const hookA = {
    activatePrepared() { hookCounts.aActivate += 1; },
    deactivate() { hookCounts.aDeactivate += 1; },
    suspend() { hookCounts.aSuspend += 1; },
};
const hookB = {
    activatePrepared() {
        hookCounts.bActivate += 1;
        if ( hookMustFail ) { throw new Error('hook resume failed'); }
    },
    deactivate() { hookCounts.bDeactivate += 1; },
    suspend() { hookCounts.bSuspend += 1; },
};
hookCSS.sandbox.cssAPI.registerOwnerHook(
    hookOwnerA,
    hookOwnerA,
    hookA,
    'custom'
);
hookCSS.sandbox.cssAPI.registerOwnerHook(
    hookOwnerB,
    hookOwnerA,
    hookB,
    'preview'
);
await hookCSS.sandbox.cssAPI.activateOwner(
    hookOwnerA,
    hookOwnerA,
    { lane: 'custom' }
);
await hookCSS.sandbox.cssAPI.activateOwner(
    hookOwnerB,
    hookOwnerA,
    { lane: 'preview' }
);
assert.equal((await hookCSS.sandbox.cssAPI.commit(
    hookOwnerA,
    hookOwnerB,
    15000
)).ok, true);
const hookIdentityRecord = {};
hookMustFail = true;
hookCSS.sandbox.floorpCSSUserIdentityPendingRecord = hookIdentityRecord;
hookCSS.sandbox.cssAPI.suspendForIdentity(hookIdentityRecord);
assert.deepEqual(scopeAttributes(hookCSS), []);
assert.equal(
    hookCSS.sandbox.cssAPI.resumeForIdentity(
        hookIdentityRecord,
        'ack-document',
        0
    ),
    false,
    'a failed procedural hook resume must fail closed'
);
assert.equal(hookCounts.aDeactivate, 1);
assert.equal(hookCounts.bDeactivate, 1);
assert.deepEqual(scopeAttributes(hookCSS), []);
const insertsBeforeFailedCommit = cssProtocolMessages(hookCSS, 'insertCSS').length;
const oldHookAPI = hookCSS.sandbox.cssAPI;
const oldCommitAfterHookFailure = await Promise.race([
    oldHookAPI.commit(
        hookOwnerA,
        hookOwnerA,
        hookCSS.sandbox.performance.now() + 15000
    ),
    sleep(100).then(( ) => ({ timedOut: true })),
]);
assert.notEqual(oldCommitAfterHookFailure.timedOut, true);
assert.equal(oldCommitAfterHookFailure.ok, false);
assert.equal(
    cssProtocolMessages(hookCSS, 'insertCSS').length,
    insertsBeforeFailedCommit,
    'a hook-resume failure must keep concurrent operations behind failure'
);
assert.deepEqual(scopeAttributes(hookCSS), []);
const recoveredHookIdentity = await oldHookAPI.refreshForScriptExecution();
assert.equal(recoveredHookIdentity.ok, true);
assert.equal(oldHookAPI.disposed, true);
assert.notEqual(hookCSS.sandbox.cssAPI, oldHookAPI);
const rebuiltHookOwner = hookCSS.generation;
const rebuiltHook = {
    activatePrepared() { hookCounts.aActivate += 1; },
    deactivate() { hookCounts.aDeactivate += 1; },
    suspend() { hookCounts.aSuspend += 1; },
};
hookCSS.sandbox.cssAPI.registerOwnerHook(
    rebuiltHookOwner,
    rebuiltHookOwner,
    rebuiltHook,
    'custom'
);
await hookCSS.sandbox.cssAPI.activateOwner(
    rebuiltHookOwner,
    rebuiltHookOwner,
    { lane: 'custom' }
);
assert.equal((await hookCSS.sandbox.cssAPI.commit(
    rebuiltHookOwner,
    rebuiltHookOwner,
    hookCSS.sandbox.performance.now() + 15000
)).ok, true);
assert.equal(scopeAttributes(hookCSS).length, 1);

console.log('uBO custom-filter injection tests passed');
// Some deliberately orphaned callback/timer probes keep Node's event loop
// alive after every assertion has completed. End the harness explicitly so
// the Python release gate observes the completed result deterministically.
process.exit(0);
