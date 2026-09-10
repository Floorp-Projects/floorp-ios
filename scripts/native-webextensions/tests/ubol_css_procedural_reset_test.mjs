import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 3 ) {
    throw new Error(
        'usage: node ubol_css_procedural_reset_test.mjs <css-procedural-api.js>'
    );
}

const source = await readFile(process.argv[2], 'utf8');
const insertions = [];
const activations = [];
const registrations = [];
const unregistrations = [];
const forgottenOwners = [];
const fallbackGeneration = {};
let forgetResult = { ok: true };

class TestMutationObserver {
    observe() {}
    takeRecords() { return []; }
    disconnect() {}
}

const sandbox = {
    console,
    document: {
        documentElement: { id: 'document-a' },
        querySelectorAll() { return []; },
    },
    performance: { timeOrigin: 1000 },
    MutationObserver: TestMutationObserver,
    cancelAnimationFrame() {},
    requestAnimationFrame() { return 1; },
};
sandbox.self = sandbox;
sandbox.window = sandbox;
sandbox.cssAPI = {
    activateOwner(owner, generation, options) {
        activations.push({ owner, generation, options });
        return Promise.resolve({ ok: true });
    },
    currentDocumentGeneration() { return fallbackGeneration; },
    forgetOwner(owner, generation) {
        forgottenOwners.push({ owner, generation });
        return Promise.resolve(forgetResult);
    },
    insert(css, options) {
        insertions.push({ css, options });
        return Promise.resolve({ ok: true });
    },
    registerOwnerHook(owner, generation, hook, lane) {
        registrations.push({ owner, generation, hook, lane });
        return { ok: true };
    },
    unregisterOwnerHook(owner, generation, hook) {
        unregistrations.push({ owner, generation, hook });
        return { ok: true };
    },
};

const context = vm.createContext(sandbox);
const runProceduralAPI = ( ) => new vm.Script(source, {
    filename: 'js/scripting/css-procedural-api.js',
}).runInContext(context);

runProceduralAPI();
const ProceduralFiltererAPI = sandbox.ProceduralFiltererAPI;
assert.equal(typeof ProceduralFiltererAPI, 'function');
assert.equal(ProceduralFiltererAPI.documentTimeOrigin, 1000);

runProceduralAPI();
assert.equal(
    sandbox.ProceduralFiltererAPI,
    ProceduralFiltererAPI,
    'the same time-origin execution must reuse its procedural API class'
);

sandbox.document.documentElement = { id: 'same-document-replaced-root' };
runProceduralAPI();
assert.equal(
    sandbox.ProceduralFiltererAPI,
    ProceduralFiltererAPI,
    'a mutable documentElement must not be used as Document identity'
);

sandbox.performance.timeOrigin = 2000;
runProceduralAPI();
const nextDocumentProceduralAPI = sandbox.ProceduralFiltererAPI;
assert.notEqual(nextDocumentProceduralAPI, ProceduralFiltererAPI);
assert.equal(nextDocumentProceduralAPI.documentTimeOrigin, 2000);

sandbox.floorpCSSUserForceAPIReplay = {};
runProceduralAPI();
assert.notEqual(
    sandbox.ProceduralFiltererAPI,
    nextDocumentProceduralAPI,
    'an authoritative native-document replacement must force a new class'
);
sandbox.floorpCSSUserForceAPIReplay = undefined;

const declarative = {
    selector: '#floorp-declarative',
    action: [ 'style', 'display:none!important;' ],
};
const procedural = {
    raw: '##.floorp-procedural:style(visibility:hidden!important;)',
    selector: '.floorp-procedural',
    tasks: [],
    action: [ 'style', 'visibility:hidden!important;' ],
};

const outerPreserved = new sandbox.ProceduralFiltererAPI();
outerPreserved.addDeclaratives([ declarative ]);
assert.equal(outerPreserved.cssSheets.size, 1);
assert.equal(insertions.at(-1).options.owner, outerPreserved.cssOwner);
assert.equal(insertions.at(-1).options.generation, fallbackGeneration);
await outerPreserved.reset({ removeCSS: false });
assert.equal(outerPreserved.cssSheets.size, 0);
assert.equal(unregistrations.at(-1).owner, outerPreserved.cssOwner);
assert.equal(forgottenOwners.length, 0);

const innerPreserved = new sandbox.ProceduralFiltererAPI();
innerPreserved.addProcedurals([ procedural ]);
assert.equal(innerPreserved.proceduralFilterer.styleTokenMap.size, 1);
assert.equal(innerPreserved.proceduralFilterer.suspended, true);
assert.equal(activations.at(-1).owner, innerPreserved.cssOwner);
await innerPreserved.reset({ removeCSS: false });
assert.equal(innerPreserved.proceduralFilterer, null);
assert.equal(unregistrations.at(-1).owner, innerPreserved.cssOwner);

const outerRemoved = new sandbox.ProceduralFiltererAPI();
outerRemoved.addDeclaratives([ declarative ]);
await outerRemoved.reset();
assert.equal(forgottenOwners.at(-1).owner, outerRemoved.cssOwner);
assert.equal(forgottenOwners.at(-1).generation, fallbackGeneration);

const innerRemoved = new sandbox.ProceduralFiltererAPI();
innerRemoved.addProcedurals([ procedural ]);
await innerRemoved.reset();
assert.equal(forgottenOwners.at(-1).owner, innerRemoved.cssOwner);
assert.match(
    insertions.at(-1).css,
    /^\[[a-z][a-z0-9]+\]\n\{visibility:hidden!important;\}\n$/
);

const failingReset = new sandbox.ProceduralFiltererAPI();
failingReset.addDeclaratives([ declarative ]);
forgetResult = { ok: false, error: 'native removal failed' };
await assert.rejects(
    failingReset.reset(),
    /native removal failed/,
    'procedural reset must propagate owner-scoped native cleanup failure'
);

assert.equal(
    insertions.length,
    5,
    'each declarative and procedural inventory must enter its owner slot'
);

console.log('uBO procedural reset tests passed');
