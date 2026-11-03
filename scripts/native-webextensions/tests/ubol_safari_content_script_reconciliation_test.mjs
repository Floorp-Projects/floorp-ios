import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 3 ) {
    throw new Error(
        'usage: node ubol_safari_content_script_reconciliation_test.mjs ' +
        '<scripting-manager.js>'
    );
}

const source = await readFile(process.argv[2], 'utf8');
const start = source.indexOf('const resourceDetailPromises = new Map();');
const end = source.indexOf('\nfunction getScriptletDetails()', start);
assert.notEqual(start, -1);
assert.notEqual(end, -1);

const sandbox = {
    setTimeout,
    ubolErr() {},
    ubolLog() {},
};
sandbox.self = sandbox;
vm.runInContext(
    `${source.slice(start, end).replace('export async function ', 'async function ')}` +
    '\nself.reconcileUnderTest = reconcileSafariContentScripts;',
    vm.createContext(sandbox),
    { filename: 'js/scripting-manager.js' }
);

const sentinel = {
    id: 'floorp-safari-registration-sentinel',
    matches: [ 'https://floorp.invalid/*' ],
    js: [ '/js/safari-registration-sentinel.js' ],
    persistAcrossSessions: true,
    runAt: 'document_start',
    world: 'ISOLATED',
};
const content = {
    id: 'css-specific',
    matches: [ 'https://b.example/*', 'https://a.example/*' ],
    excludeMatches: [ 'https://off.example/*' ],
    js: [ '/js/first.js', '/js/second.js' ],
    allFrames: true,
    persistAcrossSessions: true,
    runAt: 'document_start',
    world: 'ISOLATED',
};

function clone(value) {
    return structuredClone(value);
}

{
    const calls = { register: 0, update: 0, unregister: 0 };
    const scripting = {
        async getRegisteredContentScripts() {
            return [
                { ...clone(content),
                    matches: [ ...content.matches ].reverse(),
                    js: content.js.map(path => path.slice(1)),
                    world: 'isolated' },
                { ...clone(sentinel),
                    js: sentinel.js.map(path => path.slice(1)),
                    world: 'isolated' },
            ];
        },
        async registerContentScripts() { calls.register += 1; },
        async updateContentScripts() { calls.update += 1; },
        async unregisterContentScripts() { calls.unregister += 1; },
    };
    await sandbox.reconcileUnderTest(scripting, [ sentinel, content ]);
    assert.deepEqual(calls, { register: 0, update: 0, unregister: 0 });
}

{
    let visible = [ clone(sentinel) ];
    let pending;
    let visibleAt = 0;
    let registerCalls = 0;
    let appliedRegistrations = 0;
    const scripting = {
        async getRegisteredContentScripts() {
            if ( pending !== undefined && Date.now() >= visibleAt ) {
                visible = pending;
                pending = undefined;
            }
            return clone(visible);
        },
        async registerContentScripts(details) {
            registerCalls += 1;
            if ( pending !== undefined ) {
                throw new Error('Duplicate script ID while readback is stale');
            }
            appliedRegistrations += 1;
            pending = [ ...visible, ...clone(details) ];
            visibleAt = Date.now() + 220;
        },
        async updateContentScripts() {},
        async unregisterContentScripts() {},
    };
    await sandbox.reconcileUnderTest(scripting, [ sentinel, content ]);
    assert.ok(registerCalls > 1, 'the harness must exercise stale duplicates');
    assert.equal(appliedRegistrations, 1);
    assert.deepEqual(visible.map(details => details.id).sort(), [
        'css-specific',
        'floorp-safari-registration-sentinel',
    ]);
}

{
    let visible = [ clone(sentinel) ];
    const scripting = {
        async getRegisteredContentScripts() { return clone(visible); },
        async registerContentScripts(details) {
            visible.push(...clone(details));
            throw new Error('Safari rejected after applying the mutation');
        },
        async updateContentScripts() {},
        async unregisterContentScripts() {},
    };
    await sandbox.reconcileUnderTest(scripting, [ sentinel, content ]);
}

{
    let visible = [];
    let activeMutations = 0;
    let maximumActiveMutations = 0;
    const delay = ( ) => new Promise(resolve => setTimeout(resolve, 5));
    const mutate = async callback => {
        activeMutations += 1;
        maximumActiveMutations = Math.max(maximumActiveMutations, activeMutations);
        await delay();
        callback();
        activeMutations -= 1;
    };
    const scripting = {
        async getRegisteredContentScripts() { return clone(visible); },
        async registerContentScripts(details) {
            await mutate(( ) => { visible.push(...clone(details)); });
        },
        async updateContentScripts(details) {
            await mutate(( ) => {
                const updates = new Map(details.map(item => [ item.id, clone(item) ]));
                visible = visible.map(item => updates.get(item.id) || item);
            });
        },
        async unregisterContentScripts({ ids }) {
            await mutate(( ) => {
                const removed = new Set(ids);
                visible = visible.filter(item => removed.has(item.id) === false);
            });
        },
    };
    const first = { ...clone(content), id: 'first' };
    const second = { ...clone(content), id: 'second' };
    await Promise.all([
        sandbox.reconcileUnderTest(scripting, [ sentinel, first ]),
        sandbox.reconcileUnderTest(scripting, [ sentinel, second ]),
    ]);
    assert.equal(maximumActiveMutations, 1);
    assert.deepEqual(visible.map(details => details.id).sort(), [
        'floorp-safari-registration-sentinel',
        'second',
    ]);
}

sandbox.setTimeout = callback => setTimeout(callback, 0);
const loggedErrors = [];
sandbox.ubolErr = message => loggedErrors.push(message);

function legacyRegistrationStore({ dropOnRegister = false, failRemoval = false } = {}) {
    const scriptlet = {
        ...clone(content),
        id: 'ublock-filters.main',
        matchOriginAsFallback: true,
        world: 'MAIN',
    };
    const legacy = clone(scriptlet);
    delete legacy.matchOriginAsFallback;
    let visible = [ clone(sentinel), clone(content), legacy ];
    const calls = { update: [], register: [], unregister: [] };
    const scripting = {
        async getRegisteredContentScripts() { return clone(visible); },
        async updateContentScripts(rows) {
            calls.update.push(clone(rows));
        },
        async registerContentScripts(rows) {
            calls.register.push(clone(rows));
            assert.ok(rows.every(row => !visible.some(other => other.id === row.id)));
            visible.push(...rows.map(row => {
                const saved = clone(row);
                if ( dropOnRegister ) { delete saved.matchOriginAsFallback; }
                return saved;
            }));
        },
        async unregisterContentScripts({ ids }) {
            calls.unregister.push(clone(ids));
            assert.ok(!ids.includes(sentinel.id), 'retain the database sentinel');
            assert.ok(!ids.includes(content.id), 'retain unchanged protection');
            visible = visible.filter(row => !ids.includes(row.id));
            assert.ok(visible.some(row => row.id === sentinel.id));
            if ( failRemoval ) {
                failRemoval = false;
                throw new Error('Safari rejected after removing the legacy row');
            }
        },
    };
    return { scripting, calls, desired: [ sentinel, content, scriptlet ] };
}

{
    const { scripting, calls, desired } = legacyRegistrationStore();
    await sandbox.reconcileUnderTest(scripting, desired);
    assert.equal(loggedErrors.length, 0, 'successful recovery must not report a runtime error');
    assert.ok(calls.update.length > 0, 'try ordinary updates before replacement');
    assert.deepEqual(calls.unregister, [[ 'ublock-filters.main' ]]);
    assert.deepEqual(calls.register.map(rows => rows.map(row => row.id)), [
        [ 'ublock-filters.main' ],
    ]);
    assert.equal(
        (await scripting.getRegisteredContentScripts()).find(row =>
            row.id === 'ublock-filters.main').matchOriginAsFallback,
        true
    );
    const before = clone(calls);
    await sandbox.reconcileUnderTest(scripting, desired);
    assert.deepEqual(calls, before, 'a converged wake must not rewrite scripts');
}

{
    const { scripting, desired } = legacyRegistrationStore({ dropOnRegister: true });
    await assert.rejects(
        sandbox.reconcileUnderTest(scripting, desired),
        error => /Safari content-script reconciliation did not converge/.test(error.message) &&
            /ublock-filters.main/.test(error.message) &&
            /matchOriginAsFallback/.test(error.message)
    );
    assert.equal(loggedErrors.length, 1, 'report the final failure after recovery is exhausted');
}

{
    const { scripting, desired } = legacyRegistrationStore({ failRemoval: true });
    await assert.rejects(
        sandbox.reconcileUnderTest(scripting, desired),
        /Safari rejected after removing the legacy row/
    );
    await sandbox.reconcileUnderTest(scripting, desired);
    const rows = await scripting.getRegisteredContentScripts();
    assert.deepEqual(rows.map(row => row.id).sort(), desired.map(row => row.id).sort());
}

{
    const { scripting, calls, desired } = legacyRegistrationStore();
    const read = scripting.getRegisteredContentScripts;
    const unregister = scripting.unregisterContentScripts;
    const stale = await read();
    let removed = false;
    scripting.unregisterContentScripts = async options => {
        await unregister(options);
        removed = true;
    };
    scripting.getRegisteredContentScripts = async () => removed ? clone(stale) : read();
    await assert.rejects(
        sandbox.reconcileUnderTest(scripting, desired),
        /Safari content-script removal did not converge/
    );
    assert.equal(calls.register.length, 0, 'do not register until removal is confirmed');
    scripting.getRegisteredContentScripts = read;
    await sandbox.reconcileUnderTest(scripting, desired);
}

{
    const { scripting, calls, desired } = legacyRegistrationStore();
    const read = scripting.getRegisteredContentScripts;
    const unregister = scripting.unregisterContentScripts;
    let removed = false;
    scripting.unregisterContentScripts = async options => {
        await unregister(options);
        removed = true;
    };
    scripting.getRegisteredContentScripts = async () => {
        const rows = await read();
        return removed ? rows.filter(row => row.id !== sentinel.id) : rows;
    };
    await assert.rejects(
        sandbox.reconcileUnderTest(scripting, desired),
        /Safari registration sentinel verification failed/
    );
    assert.equal(calls.register.length, 0, 'do not continue after losing the sentinel');
}

console.log('uBO Safari content-script reconciliation tests passed');
