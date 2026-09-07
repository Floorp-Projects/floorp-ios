import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 3 ) {
    throw new Error(
        'usage: node ubol_admin_settings_serialization_test.mjs <admin.js>'
    );
}

const source = await readFile(process.argv[2], 'utf8');
const start = source.indexOf('let runAdminSettingsMutation = async operation => {');
const end = source.indexOf(
    '\n/' + '*'.repeat(78) + '/\n\nexport async function getAdminRulesets',
    start
);
assert.notEqual(start, -1, 'admin.js must define its mutation runner');
assert.notEqual(end, -1, 'admin.js must keep the managed settings block intact');
const adminSource = source.slice(start, end).replaceAll('export function', 'function');
const applyStart = source.indexOf('async function applyAdminConfig(config, apply = false)');
const applyEnd = source.indexOf('\n/' + '*'.repeat(78) + '/', applyStart);
assert.notEqual(applyStart, -1, 'admin.js must define applyAdminConfig');
assert.notEqual(applyEnd, -1, 'admin.js must delimit applyAdminConfig');
const applySource = source.slice(applyStart, applyEnd);

const timers = [];
const calls = {
    applied: [],
    broadcasts: [],
    registrations: 0,
    runner: 0,
};
let journalActive = false;
let foregroundRequired = false;
let readinessFlag = false;

const sandbox = {
    applyAdminConfig: async config => {
        calls.applied.push(structuredClone(config));
    },
    broadcastMessage(message) {
        calls.broadcasts.push(structuredClone(message));
    },
    enableRulesets: async ( ) => foregroundRequired
        ? { foregroundReconciliationRequired: true }
        : { enabledRulesets: [ 'managed' ] },
    getAdminRulesets: async ( ) => [ '+managed' ],
    getDefaultFilteringMode: async ( ) => 2,
    getEnabledRulesets: async ( ) => [ 'managed' ],
    readFilteringModeDetails: async ( ) => ({ basic: [], optimal: [] }),
    registerContentScripts: async ( ) => {
        calls.registrations += 1;
    },
    rulesetConfig: { enabledRulesets: [ 'default' ] },
    setTimeout(callback) {
        timers.push(callback);
        return timers.length;
    },
    ubolErr() {},
    ubolLog() {},
    webextFlavor: 'safari',
};
sandbox.self = sandbox;

const context = vm.createContext(sandbox);
vm.runInContext(
    `${adminSource}
    setAdminSettingsMutationRunner(async operation => {
        self.__calls.runner += 1;
        if ( self.__journalActive() ) { return false; }
        const result = await operation();
        if ( result?.foregroundReconciliationRequired ) {
            self.__setReadinessFlag();
            return false;
        }
        return true;
    });
    self.__adminSettings = adminSettings;
    self.__resumeAdminSettingsProcessing = resumeAdminSettingsProcessing;`,
    Object.assign(context, {
        __calls: calls,
        __journalActive: ( ) => journalActive,
        __setReadinessFlag: ( ) => { readinessFlag = true; },
    }),
    { filename: 'js/admin-settings-serialization-test.js' }
);

const admin = sandbox.__adminSettings;
const resume = sandbox.__resumeAdminSettingsProcessing;
const changeWithoutTimer = (key, value) => {
    admin.change(key, value);
    admin.timer = undefined;
};

journalActive = true;
changeWithoutTimer('popupBlockMode', false);
await admin.process();
assert.equal(admin.deferred, true);
assert.equal(admin.keys.has('popupBlockMode'), true);
assert.deepEqual(calls.applied, []);
journalActive = false;
resume();
admin.timer = undefined;
await admin.process();
assert.equal(admin.keys.size, 0, 'journal-deferred policy must resume exactly once');
assert.deepEqual(calls.applied, [ { popupBlockMode: false } ]);

foregroundRequired = true;
changeWithoutTimer('rulesets', [ '+managed' ]);
await admin.process();
assert.equal(readinessFlag, true, 'managed static changes must request foreground work');
assert.equal(admin.deferred, true);
assert.equal(admin.keys.has('rulesets'), true);
assert.equal(calls.registrations, 1, 'only the earlier popup update registered scripts');
foregroundRequired = false;
readinessFlag = false;
resume();
admin.timer = undefined;
await admin.process();
assert.equal(admin.keys.size, 0);
assert.equal(calls.registrations, 2);

let releaseFirstApply;
let firstApplyEntered;
const firstApplyStarted = new Promise(resolve => { firstApplyEntered = resolve; });
const originalApplyAdminConfig = sandbox.applyAdminConfig;
let holdFirstApply = true;
sandbox.applyAdminConfig = async config => {
    calls.applied.push(structuredClone(config));
    if ( holdFirstApply ) {
        holdFirstApply = false;
        firstApplyEntered();
        await new Promise(resolve => { releaseFirstApply = resolve; });
    }
};
changeWithoutTimer('showBlockedCount', false);
const firstProcess = admin.process();
await firstApplyStarted;
changeWithoutTimer('showBlockedCount', true);
releaseFirstApply();
await firstProcess;
assert.equal(
    admin.keys.get('showBlockedCount').value,
    true,
    'a same-key managed change arriving during await must remain queued'
);
admin.timer = undefined;
await admin.process();
assert.equal(admin.keys.size, 0);
assert.deepEqual(calls.applied.slice(-2), [
    { showBlockedCount: false },
    { showBlockedCount: true },
]);
sandbox.applyAdminConfig = originalApplyAdminConfig;

let persistentFailure = true;
sandbox.applyAdminConfig = async config => {
    if ( persistentFailure ) { throw new Error('persistent managed failure'); }
    calls.applied.push(structuredClone(config));
};
admin.change('strictBlockMode', false);
const failingTimer = timers.at(-1);
failingTimer();
for ( let i = 0; i < 10 && admin.processing; i++ ) {
    await new Promise(resolve => setTimeout(resolve, 0));
}
assert.equal(admin.deferred, true);
assert.equal(admin.keys.has('strictBlockMode'), true);
const timerCountAfterFailure = timers.length;
await new Promise(resolve => setTimeout(resolve, 10));
assert.equal(
    timers.length,
    timerCountAfterFailure,
    'a persistent failure must not create a 127 ms retry loop'
);
persistentFailure = false;
resume();
const retryTimer = timers.at(-1);
assert.notEqual(retryTimer, failingTimer);
retryTimer();
for ( let i = 0; i < 10 && admin.processing; i++ ) {
    await new Promise(resolve => setTimeout(resolve, 0));
}
assert.equal(admin.keys.size, 0);
assert.equal(admin.deferred, false);

const sideEffectAttempts = {
    popupBlockMode: 0,
    showBlockedCount: 0,
    strictBlockMode: 0,
};
let saveCount = 0;
const applySandbox = {
    broadcastMessage() {},
    dnr: {
        async setExtensionActionOptions() {
            sideEffectAttempts.showBlockedCount += 1;
            if ( sideEffectAttempts.showBlockedCount === 1 ) {
                throw new Error('first badge failure');
            }
        },
    },
    rulesetConfig: {
        popupBlockMode: true,
        showBlockedCount: true,
        strictBlockMode: true,
    },
    async saveRulesetConfig() { saveCount += 1; },
    async setPopupBlockMode() {
        sideEffectAttempts.popupBlockMode += 1;
        if ( sideEffectAttempts.popupBlockMode === 1 ) {
            throw new Error('first popup failure');
        }
    },
    async setStrictBlockMode() {
        sideEffectAttempts.strictBlockMode += 1;
        return sideEffectAttempts.strictBlockMode === 1
            ? { error: 'first strict-block failure' }
            : {};
    },
};
applySandbox.self = applySandbox;
const applyContext = vm.createContext(applySandbox);
vm.runInContext(
    `${applySource}
    self.__applyAdminConfig = applyAdminConfig;`,
    applyContext,
    { filename: 'js/admin-idempotent-side-effect-test.js' }
);
for ( const key of Object.keys(sideEffectAttempts) ) {
    await assert.rejects(
        applySandbox.__applyAdminConfig({ [key]: false }, true),
        /first/
    );
    assert.equal(applySandbox.rulesetConfig[key], false);
    await applySandbox.__applyAdminConfig({ [key]: false }, true);
    assert.equal(
        sideEffectAttempts[key],
        2,
        `${key} must retry its native side effect after durable config matches`
    );
}
assert.equal(
    saveCount,
    3,
    'idempotent side-effect retries must not rewrite unchanged config'
);

console.log('uBO managed settings serialization tests passed');
