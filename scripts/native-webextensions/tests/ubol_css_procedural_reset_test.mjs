import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 3 ) {
    throw new Error(
        'usage: node ubol_css_procedural_reset_test.mjs <css-procedural-api.js>'
    );
}

const source = await readFile(process.argv[2], 'utf8');
const insertedCSS = [];
const runtimeMessages = [];

class TestMutationObserver {
    observe() {
    }

    takeRecords() {
        return [];
    }

    disconnect() {
    }
}

const sandbox = {
    console,
    document: {
        documentElement: { id: 'document-a' },
        querySelectorAll() {
            return [];
        },
    },
    performance: { timeOrigin: 1000 },
    MutationObserver: TestMutationObserver,
    cancelAnimationFrame() {
    },
};
sandbox.self = sandbox;
sandbox.cssAPI = {
    insert(css) {
        insertedCSS.push(css);
    },
};
sandbox.chrome = {
    runtime: {
        sendMessage(request) {
            runtimeMessages.push(structuredClone(request));
            return Promise.resolve();
        },
    },
};

const context = vm.createContext(sandbox);
new vm.Script(source, {
    filename: 'js/scripting/css-procedural-api.js',
}).runInContext(context);

const ProceduralFiltererAPI = sandbox.ProceduralFiltererAPI;
assert.equal(typeof ProceduralFiltererAPI, 'function');
assert.equal(ProceduralFiltererAPI.documentElement, sandbox.document.documentElement);
assert.equal(ProceduralFiltererAPI.documentTimeOrigin, 1000);

new vm.Script(source, {
    filename: 'js/scripting/css-procedural-api.js',
}).runInContext(context);
assert.equal(
    sandbox.ProceduralFiltererAPI,
    ProceduralFiltererAPI,
    'the same document generation should reuse its procedural API class'
);

sandbox.document.documentElement = { id: 'document-b' };
sandbox.performance.timeOrigin = 2000;
new vm.Script(source, {
    filename: 'js/scripting/css-procedural-api.js',
}).runInContext(context);
const nextDocumentProceduralAPI = sandbox.ProceduralFiltererAPI;
assert.notEqual(
    nextDocumentProceduralAPI,
    ProceduralFiltererAPI,
    'a shared isolated global must rebuild the class for a new document'
);
assert.equal(
    nextDocumentProceduralAPI.documentElement,
    sandbox.document.documentElement
);
assert.equal(nextDocumentProceduralAPI.documentTimeOrigin, 2000);

sandbox.floorpCSSUserAPIIdleReplay = true;
new vm.Script(source, {
    filename: 'js/scripting/css-procedural-api.js',
}).runInContext(context);
assert.notEqual(
    sandbox.ProceduralFiltererAPI,
    nextDocumentProceduralAPI,
    'origin-fallback idle replay must force an API rebuild'
);
sandbox.floorpCSSUserAPIIdleReplay = undefined;

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

const outerPreserved = new ProceduralFiltererAPI();
outerPreserved.addDeclaratives([ declarative ]);
assert.equal(outerPreserved.cssSheets.size, 1);
await outerPreserved.reset({ removeCSS: false });
assert.equal(runtimeMessages.length, 0);
assert.equal(outerPreserved.cssSheets.size, 0);

const innerPreserved = new ProceduralFiltererAPI();
innerPreserved.addProcedurals([ procedural ]);
assert.equal(innerPreserved.proceduralFilterer.styleTokenMap.size, 1);
await innerPreserved.reset({ removeCSS: false });
assert.equal(runtimeMessages.length, 0);
assert.equal(innerPreserved.proceduralFilterer, null);

const outerRemoved = new ProceduralFiltererAPI();
outerRemoved.addDeclaratives([ declarative ]);
await outerRemoved.reset();
assert.deepEqual(runtimeMessages.splice(0), [ {
    what: 'removeCSS',
    css: '#floorp-declarative\n{display:none!important;}',
} ]);

const innerRemoved = new ProceduralFiltererAPI();
innerRemoved.addProcedurals([ procedural ]);
await innerRemoved.reset();
assert.equal(runtimeMessages.length, 1);
assert.equal(runtimeMessages[0].what, 'removeCSS');
assert.match(
    runtimeMessages[0].css,
    /^\[[a-z][a-z0-9]+\]\n\{visibility:hidden!important;\}\n$/
);

assert.equal(
    insertedCSS.length,
    4,
    'each declarative and procedural inventory must have real inserted CSS'
);

console.log('uBO procedural reset tests passed');
