import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 3 ) {
    throw new Error(
        'usage: node ubol_settings_restore_transaction_test.mjs <background.js>'
    );
}

const source = await readFile(process.argv[2], 'utf8');

function section(startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.notEqual(start, -1, `missing source marker: ${startMarker}`);
    assert.notEqual(end, -1, `missing source marker: ${endMarker}`);
    return source.slice(start, end);
}

const queueSource = section(
    'let backgroundMutationTail = Promise.resolve();',
    '\nasync function onPermissionsChanged'
);
const lockSource = section(
    'const SETTINGS_RESTORE_JOURNAL_KEY = settingsRestoreJournalKey;',
    '\nasync function restoreRolledBackSettingsSideEffects'
);
const transactionSource = section(
    'async function validateSettingsRestore(targetConfig)',
    '\nasync function reconcileDashboardState'
);
const recoverySource = section(
    'let protectionRecoveryTail = Promise.resolve();',
    '\nasync function mutateFilteringModeAndScripts'
);
const onMessageSource = section(
    'const CUSTOM_FILTER_MESSAGE_SCHEMA = 1;',
    '\n/' + '*'.repeat(78) + '/\n\nfunction onCommand'
);
const startupRecoverySource = section(
    'async function recoverInterruptedSettingsRestoreAtStart()',
    '\n\nasync function start()'
);
const dispatchSource = section(
    'const backgroundMutationMessages = new Set([',
    '\nruntime.onMessage.addListener'
);
const ensureInitializationSource = section(
    'let initializationRecovery;',
    '\nsetAdminSettingsMutationRunner(async operation => {'
);

class FakeLockManager {
    constructor() {
        this.requestCount = 0;
        this.tail = Promise.resolve();
    }

    request(name, options, callback) {
        assert.equal(name, 'floorp.ubol.settings-restore.v1');
        assert.equal(options.mode, 'exclusive');
        this.requestCount += 1;
        const result = this.tail.then(( ) => callback({ name, mode: 'exclusive' }));
        this.tail = result.catch(( ) => undefined);
        return result;
    }
}

const lockManager = new FakeLockManager();
const localState = {
    rulesetConfig: { enabledRulesets: [ 'default' ] },
    'site.example.test': [ '#committed' ],
};
const calls = {
    initialization: 0,
    localReplace: 0,
    reconciliation: [],
    registrations: 0,
};
const reconciliationResults = [];
let initializationBlocked = false;
const never = new Promise(( ) => {});

const clone = value => value === undefined
    ? undefined
    : structuredClone(value);

const sandbox = {
    URL,
    UBOL_ORIGIN: 'safari-web-extension://ubol-test-extension',
    browser: { scripting: {} },
    crypto: { randomUUID: ( ) => 'restore-transaction-id' },
    customFilterModeStorageKeys: [],
    customFilterMutationJournalKey: 'floorp.customFilterMutationJournal.v1',
    getCurrentVersion: ( ) => '2026.825.1619',
    localRead: async key => clone(localState[key]),
    localRemove: async keys => {
        for ( const key of Array.isArray(keys) ? keys : [ keys ] ) {
            delete localState[key];
        }
    },
    localReplace: async snapshot => {
        calls.localReplace += 1;
        for ( const key of Object.keys(localState) ) {
            if ( key === 'floorp.settingsRestoreJournal.v1' ) { continue; }
            delete localState[key];
        }
        Object.assign(localState, clone(snapshot));
    },
    localSnapshot: async excludedKeys => Object.fromEntries(
        Object.entries(localState)
            .filter(([ key ]) => excludedKeys.includes(key) === false)
            .map(([ key, value ]) => [ key, clone(value) ])
    ),
    localWrite: async (key, value) => {
        localState[key] = clone(value);
    },
    navigator: { locks: lockManager },
    reconcileSettingsState: async options => {
        calls.reconciliation.push(clone(options));
        return reconciliationResults.shift() ?? { ready: true };
    },
    registerContentScripts: async ( ) => {
        calls.registrations += 1;
    },
    releaseRealmRulesetStartupGate() {},
    resetSafariRealmReadiness() {},
    restoreRolledBackSettingsSideEffects: async ( ) => {},
    rulesetConfig: { enabledRulesets: [ 'default' ] },
    runtime: { id: 'ubol-test-extension' },
    saveRulesetConfig: async ( ) => {
        localState.rulesetConfig = clone(sandbox.rulesetConfig);
    },
    loadRulesetConfig: async ( ) => {
        Object.assign(sandbox.rulesetConfig, clone(localState.rulesetConfig));
    },
    settingsRestoreJournalKey: 'floorp.settingsRestoreJournal.v1',
    setDeveloperMode: async state => {
        sandbox.rulesetConfig.developerMode = state === true;
        await sandbox.saveRulesetConfig();
        return sandbox.rulesetConfig.developerMode;
    },
    ubolErr() {},
    waitForRealmRulesetUpdates: async ( ) => {},
    webextFlavor: 'safari',
};
sandbox.self = sandbox;
sandbox.committedCustomFilterMutationSnapshot = ( ) => undefined;
sandbox.committedSettingsRestoreSnapshot = ( ) => undefined;
sandbox.customFilterStorageKeys = ( ) => [];
sandbox.customFilteringEnabledFromStorageSnapshot = ( ) => true;
sandbox.injectCustomFilters = async ( ) => ({
    plainSelectors: [],
    proceduralSelectors: [],
});
sandbox.ensureFullyInitialized = ( ) => {
    calls.initialization += 1;
    return initializationBlocked ? never : Promise.resolve(false);
};

const context = vm.createContext(sandbox);
sandbox.__localState = localState;
sandbox.__calls = calls;
vm.runInContext(
    [
        `const __cloneForTest = value => value === undefined
            ? undefined
            : JSON.parse(JSON.stringify(value));
        async function localRead(key) {
            return __cloneForTest(self.__localState[key]);
        }
        async function localRemove(keys) {
            for ( const key of Array.isArray(keys) ? keys : [ keys ] ) {
                delete self.__localState[key];
            }
        }
        async function localWrite(key, value) {
            self.__localState[key] = __cloneForTest(value);
        }
        async function localSnapshot(excludedKeys) {
            return Object.fromEntries(Object.entries(self.__localState)
                .filter(([ key ]) => excludedKeys.includes(key) === false)
                .map(([ key, value ]) => [ key, __cloneForTest(value) ]));
        }
        async function localReplace(snapshot) {
            self.__calls.localReplace += 1;
            for ( const key of Object.keys(self.__localState) ) {
                if ( key === 'floorp.settingsRestoreJournal.v1' ) { continue; }
                delete self.__localState[key];
            }
            Object.assign(self.__localState, __cloneForTest(snapshot));
        }`,
        queueSource,
        lockSource,
        transactionSource,
        recoverySource,
        onMessageSource,
        startupRecoverySource,
        dispatchSource,
        `self.__restoreTest = {
            assertSettingsRestoreMutationOwner,
            dispatchMessage,
            queueBackgroundMutation,
            recoverInterruptedSettingsRestoreAtStart,
            recoverProtectionState,
            waitForBackgroundMutations,
            getBackgroundMutationError: () => backgroundMutationError,
            setActiveSettingsRestoreId: value => {
                activeSettingsRestoreId = value;
            },
        };`,
    ].join('\n\n'),
    context,
    { filename: 'js/background-settings-restore-test.js' }
);

const api = sandbox.__restoreTest;
const trustedSender = {
    id: 'ubol-test-extension',
    origin: 'safari-web-extension://ubol-test-extension',
};
const timeout = (promise, label) => Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(
        ( ) => reject(new Error(`${label} timed out`)),
        1000
    )),
]);
const step = async (label, promise) => {
    try {
        return await promise;
    } catch (reason) {
        reason.message = `${label}: ${reason.message}`;
        throw reason;
    }
};

const begin = await step('begin', api.dispatchMessage({
    what: 'beginSettingsRestore',
}, trustedSender));
assert.equal(begin.id, 'restore-transaction-id');
assert.equal(
    localState['floorp.settingsRestoreJournal.v1'].phase,
    'applying'
);
await assert.rejects(
    api.dispatchMessage({
        what: 'floorpAuthorizeForegroundReconciliation',
        settingsRestoreId: begin.id,
    }, trustedSender),
    /Settings restore is in progress/,
    'foreground reconciliation must not finalize an applying transaction'
);

reconciliationResults.push(
    { foregroundReconciliationRequired: true },
    { ready: true }
);
const commit = await step('commit', api.dispatchMessage({
    what: 'commitSettingsRestore',
    id: begin.id,
    settingsRestoreId: begin.id,
    enabledRulesets: [ 'default', 'annoyances' ],
}, trustedSender));
assert.equal(commit.foregroundReconciliationRequired, true);
assert.equal(commit.settingsRestoreId, begin.id);
assert.deepEqual(
    clone(localState['floorp.settingsRestoreJournal.v1'].targetEnabledRulesets),
    [ 'default', 'annoyances' ]
);
assert.equal(
    localState['floorp.settingsRestoreJournal.v1'].phase,
    'committingForeground'
);

let releaseForegroundLock;
let foregroundLockAcquired;
const acquired = new Promise(resolve => { foregroundLockAcquired = resolve; });
const heldForegroundLock = lockManager.request(
    'floorp.ubol.settings-restore.v1',
    { mode: 'exclusive' },
    async ( ) => {
        foregroundLockAcquired();
        await new Promise(resolve => { releaseForegroundLock = resolve; });
    }
);
await acquired;

// Model a new background realm while the foreground page still owns the lock.
api.setActiveSettingsRestoreId(undefined);
initializationBlocked = true;
const startupRecovery = api.recoverInterruptedSettingsRestoreAtStart();
let startupSettled = false;
startupRecovery.finally(( ) => { startupSettled = true; });
await new Promise(resolve => setTimeout(resolve, 10));
assert.equal(startupSettled, false, 'startup must wait for the foreground lease');

// An ordinary mutation waits outside the queue for initialization. It must not
// prevent the lock holder's early authorization and terminal finalizer.
void api.dispatchMessage({
    what: 'setAutoReload',
    settingsRestoreId: begin.id,
    state: true,
}, trustedSender);
const initializationCallsBeforeEarlyMessages = calls.initialization;
const authorization = await step('authorize', timeout(api.dispatchMessage({
    what: 'floorpAuthorizeForegroundReconciliation',
    settingsRestoreId: begin.id,
}, trustedSender), 'foreground authorization'));
assert.deepEqual(clone(authorization), { authorized: true });

const finalized = await step('finalize', timeout(api.dispatchMessage({
    what: 'floorpFinalizeForegroundReconciliation',
    settingsRestoreId: begin.id,
}, trustedSender), 'foreground finalizer'));
assert.equal(finalized.ready, true);
assert.equal(finalized.committed, true);
assert.equal(finalized.rolledBack, false);
assert.equal(
    calls.initialization,
    initializationCallsBeforeEarlyMessages,
    'authorize/finalize must not wait for initialization'
);
assert.equal(localState['floorp.settingsRestoreJournal.v1'], undefined);
assert.deepEqual(clone(localState.rulesetConfig.enabledRulesets), [
    'default',
    'annoyances',
]);
assert.equal(calls.localReplace, 0, 'terminal commit must not roll back');

releaseForegroundLock();
await heldForegroundLock;
await step(
    'startup recovery release',
    timeout(startupRecovery, 'startup recovery release')
);
assert.equal(
    calls.localReplace,
    0,
    'startup must observe the terminal publication after acquiring the lock'
);

// A non-restore setting change must wait behind the same cross-realm lease so
// an in-flight foreground ruleset save cannot silently overwrite it.
initializationBlocked = false;
let releaseOrdinaryForegroundLock;
let ordinaryForegroundLockAcquired;
const ordinaryAcquired = new Promise(resolve => {
    ordinaryForegroundLockAcquired = resolve;
});
const ordinaryForegroundLock = lockManager.request(
    'floorp.ubol.settings-restore.v1',
    { mode: 'exclusive' },
    async ( ) => {
        ordinaryForegroundLockAcquired();
        await new Promise(resolve => {
            releaseOrdinaryForegroundLock = resolve;
        });
    }
);
await ordinaryAcquired;
let developerMutationSettled = false;
const developerMutation = api.dispatchMessage({
    what: 'setDeveloperMode',
    state: true,
}, trustedSender);
developerMutation.finally(( ) => { developerMutationSettled = true; });
await new Promise(resolve => setTimeout(resolve, 10));
assert.equal(
    developerMutationSettled,
    false,
    'ordinary settings mutation must wait behind foreground reconciliation'
);
releaseOrdinaryForegroundLock();
await ordinaryForegroundLock;
assert.equal(await timeout(developerMutation, 'developer mutation'), true);
assert.deepEqual(clone(localState.rulesetConfig), {
    enabledRulesets: [ 'default', 'annoyances' ],
    developerMode: true,
});

assert.equal(api.getBackgroundMutationError(), undefined);

await assert.rejects(
    api.queueBackgroundMutation(async ( ) => {
        throw new Error('persistent protected mutation failure');
    }),
    /persistent protected mutation failure/
);
assert.equal(
    await api.queueBackgroundMutation(async ( ) => 'unrelated-success'),
    'unrelated-success'
);
await assert.rejects(
    api.waitForBackgroundMutations(),
    /persistent protected mutation failure/,
    'an unrelated successful mutation must not erase an earlier failure'
);
await api.recoverProtectionState();
await api.waitForBackgroundMutations();
assert.equal(api.getBackgroundMutationError(), undefined);

const genericAuthorization = await api.dispatchMessage({
    what: 'floorpAuthorizeForegroundReconciliation',
}, trustedSender);
assert.deepEqual(clone(genericAuthorization), { authorized: true });
const interruptedForegroundReadiness = await api.dispatchMessage({
    what: 'floorpReadiness',
}, trustedSender);
assert.equal(interruptedForegroundReadiness.ready, false);
assert.equal(
    interruptedForegroundReadiness.foregroundReconciliationRequired,
    true,
    'an authorized foreground handoff must survive page loss before finalization'
);
const genericFinalization = await api.dispatchMessage({
    what: 'floorpFinalizeForegroundReconciliation',
}, trustedSender);
assert.equal(genericFinalization.ready, true);
assert.equal(genericFinalization.foregroundReconciliationRequired, false);

let readinessInitializationAttempts = 0;
sandbox.ensureFullyInitialized = ( ) => {
    readinessInitializationAttempts += 1;
    return readinessInitializationAttempts === 1
        ? Promise.reject(new Error('transient readiness recovery failure'))
        : Promise.resolve(false);
};
const recoveredReadiness = await timeout(api.dispatchMessage({
    what: 'floorpReadiness',
}, trustedSender), 'same-call readiness recovery');
assert.equal(recoveredReadiness.ready, true);
assert.equal(
    readinessInitializationAttempts,
    2,
    'readiness must discard a transient first error after same-call recovery'
);

const localReplaceBeforeMalformedJournal = calls.localReplace;
localState.keepAfterMalformedJournal = { protected: true };
localState['floorp.settingsRestoreJournal.v1'] = {
    id: undefined,
    beforeLocal: {},
    phase: 'rollingBack',
};
await assert.rejects(
    api.dispatchMessage({ what: 'beginSettingsRestore' }, trustedSender),
    /Settings restore journal is invalid/
);
assert.equal(calls.localReplace, localReplaceBeforeMalformedJournal);
assert.deepEqual(clone(localState.keepAfterMalformedJournal), {
    protected: true,
});
delete localState['floorp.settingsRestoreJournal.v1'];

let recoveryAttempts = 0;
const recoverySandbox = {
    recoverProtectionState() {
        recoveryAttempts += 1;
        return recoveryAttempts === 1
            ? Promise.reject(new Error('transient recovery failure'))
            : Promise.resolve({ ready: true });
    },
    ubolErr() {},
};
recoverySandbox.self = recoverySandbox;
const recoveryContext = vm.createContext(recoverySandbox);
vm.runInContext(
    `const isFullyInitialized = Promise.reject(new Error('startup failed'));
    void isFullyInitialized.catch(() => undefined);
    ${ensureInitializationSource}
    self.__ensureFullyInitialized = ensureFullyInitialized;`,
    recoveryContext,
    { filename: 'js/background-initialization-retry-test.js' }
);
await assert.rejects(
    recoverySandbox.__ensureFullyInitialized(),
    /transient recovery failure/
);
assert.equal(
    await recoverySandbox.__ensureFullyInitialized(),
    false,
    'a failed recovery must not poison later initialization attempts'
);
assert.equal(
    await recoverySandbox.__ensureFullyInitialized(),
    false,
    'a successful recovery must remain cached for later messages'
);
assert.equal(recoveryAttempts, 2);

console.log('uBO settings-restore transaction tests passed');
