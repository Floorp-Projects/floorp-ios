import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 3 ) {
    throw new Error(
        'usage: node ubol_background_message_initialization_test.mjs <background.js>'
    );
}

const source = await readFile(process.argv[2], 'utf8');
const functionStartMarker = 'const CUSTOM_FILTER_MESSAGE_SCHEMA = 1;';
const functionEndMarker = '\n/' + '*'.repeat(78) +
    '/\n\nfunction onCommand';
const functionStart = source.indexOf(functionStartMarker);
const functionEnd = source.indexOf(functionEndMarker, functionStart);

assert.notEqual(functionStart, -1, 'background.js must define onMessage');
assert.notEqual(
    functionEnd,
    -1,
    'background.js must keep onMessage immediately before onCommand'
);

const onMessageSource = source.slice(functionStart, functionEnd);
const never = new Promise(( ) => {});
const customFilterResult = {
    plainSelectors: [ '#custom-filter-result' ],
    proceduralSelectors: [],
};
const calls = {
    ensureFullyInitialized: 0,
    getEnabledRulesets: 0,
    injectCustomFilters: [],
    localRead: [],
    localSnapshot: 0,
    localSnapshotArguments: [],
};

const sandbox = {
    ensureFullyInitialized() {
        calls.ensureFullyInitialized += 1;
        return never;
    },
    getEnabledRulesets() {
        calls.getEnabledRulesets += 1;
        return Promise.resolve([ 'unexpected' ]);
    },
    injectCustomFilters(target, hostname, storageSnapshot) {
        calls.injectCustomFilters.push(structuredClone({
            target,
            hostname,
            storageSnapshot,
        }));
        return Promise.resolve(customFilterResult);
    },
    localRead(key) {
        calls.localRead.push(key);
        return Promise.resolve(undefined);
    },
    localSnapshot(excludedKeys, requestedKeys) {
        calls.localSnapshot += 1;
        calls.localSnapshotArguments.push(structuredClone({
            excludedKeys,
            requestedKeys,
        }));
        return Promise.resolve({});
    },
    customFilterStorageKeys(hostname) {
        const keys = [];
        let current = hostname;
        while ( current !== '' ) {
            keys.push(`site.${current}`);
            const separator = current.indexOf('.');
            if ( separator === -1 ) { break; }
            current = current.slice(separator + 1);
        }
        return keys;
    },
    customFilterModeStorageKeys: [
        'filteringModeDetails',
        'admin.defaultFiltering',
        'admin.noFiltering',
    ],
    customFilterMutationJournalKey:
        'floorp.customFilterMutationJournal.v1',
    committedCustomFilterMutationSnapshot() {},
    committedSettingsRestoreSnapshot() {},
    customFilteringEnabledFromStorageSnapshot() { return true; },
    SETTINGS_RESTORE_JOURNAL_KEY: 'floorp.settingsRestoreJournal.v1',
    foregroundRulesetReconciliationRequired: false,
    runtime: { id: 'ubol-test-extension' },
    UBOL_ORIGIN: 'safari-web-extension://ubol-test-extension',
    ubolErr() {},
    URL,
};
sandbox.self = sandbox;

const context = vm.createContext(sandbox);
vm.runInContext(
    `${onMessageSource}\nself.floorpOnMessageUnderTest = onMessage;`,
    context,
    { filename: 'js/background.js' }
);

const sender = {
    tab: { id: 41 },
    frameId: 0,
    documentId: 'main-document-41',
    url: 'https://filters.example/page',
};
const timeout = Symbol('timeout');
const customReply = await Promise.race([
    sandbox.floorpOnMessageUnderTest({
        what: 'injectCustomFilters',
        schema: 1,
        requestId: 'initialization-regression',
        hostname: 'filters.example',
    }, sender),
    new Promise(resolve => setTimeout(( ) => resolve(timeout), 1_000)),
]);

assert.notEqual(
    customReply,
    timeout,
    'injectCustomFilters must not wait for background initialization'
);
assert.deepEqual(structuredClone(customReply), {
    ok: true,
    schema: 1,
    requestId: 'initialization-regression',
    ...customFilterResult,
});
assert.deepEqual(calls.injectCustomFilters, [ {
    target: {
        tabId: 41,
        documentIds: [ 'main-document-41' ],
    },
    hostname: 'filters.example',
    storageSnapshot: {},
} ]);
assert.deepEqual(calls.localRead, []);
assert.equal(calls.localSnapshot, 1);
assert.deepEqual(calls.localSnapshotArguments, [ {
    excludedKeys: [],
    requestedKeys: [
        'floorp.settingsRestoreJournal.v1',
        'floorp.customFilterMutationJournal.v1',
        'filteringModeDetails',
        'admin.defaultFiltering',
        'admin.noFiltering',
        'site.filters.example',
        'site.example',
    ],
} ]);
assert.equal(
    calls.ensureFullyInitialized,
    0,
    'injectCustomFilters must bypass ensureFullyInitialized'
);

const authorization = await sandbox.floorpOnMessageUnderTest({
    what: 'floorpAuthorizeForegroundReconciliation',
    settingsRestoreId: 'restore-under-test',
}, {
    id: 'ubol-test-extension',
    origin: 'safari-web-extension://ubol-test-extension',
});
assert.deepEqual(structuredClone(authorization), { authorized: true });
assert.equal(
    sandbox.foregroundRulesetReconciliationRequired,
    true,
    'authorization must keep readiness fail-closed until finalization'
);
assert.equal(
    calls.ensureFullyInitialized,
    0,
    'foreground authorization must bypass blocked initialization'
);

let gatedRequestSettled = false;
const gatedRequest = sandbox.floorpOnMessageUnderTest(
    { what: 'getEnabledRulesets' },
    sender
);
gatedRequest.then(
    ( ) => { gatedRequestSettled = true; },
    ( ) => { gatedRequestSettled = true; }
);
await new Promise(resolve => setTimeout(resolve, 50));

assert.equal(
    gatedRequestSettled,
    false,
    'normal gated messages must remain behind background initialization'
);
assert.equal(calls.ensureFullyInitialized, 1);
assert.equal(
    calls.getEnabledRulesets,
    0,
    'the gated handler must not run before initialization completes'
);

console.log('uBO background message initialization tests passed');
