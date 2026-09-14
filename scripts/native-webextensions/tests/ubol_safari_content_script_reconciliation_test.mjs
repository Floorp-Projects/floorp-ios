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

console.log('uBO Safari content-script reconciliation tests passed');
