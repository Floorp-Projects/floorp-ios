import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

if ( process.argv.length !== 3 ) {
    throw new Error(
        'usage: node ubol_css_user_navigation_test.mjs <css-user.js>'
    );
}

const source = await readFile(process.argv[2], 'utf8');

function deferred() {
    let resolve;
    const promise = new Promise(resolvePromise => {
        resolve = resolvePromise;
    });
    return { promise, resolve };
}

const nextTask = ( ) => new Promise(resolve => setImmediate(resolve));

async function waitFor(predicate, description) {
    for ( let attempt = 0; attempt < 50; attempt++ ) {
        await nextTask();
        if ( predicate() ) { return; }
    }
    assert.fail(`timed out waiting for ${description}`);
}

const firstReply = deferred();
const oldDetails = {
    plainSelectors: [ '#old-document-filter' ],
    proceduralSelectors: [],
};
const newDetails = {
    plainSelectors: [ '#new-document-filter' ],
    proceduralSelectors: [],
};
const thirdDetails = {
    plainSelectors: [ '#third-document-filter' ],
    proceduralSelectors: [],
};
const ack = (request, details) => ({
    ok: true,
    schema: 1,
    requestId: request.requestId,
    ...details,
});
const messages = [];
const insertions = [];
const listeners = new Map();
const unhandledRejections = [];
const onUnhandledRejection = reason => {
    unhandledRejections.push(reason);
};
process.on('unhandledRejection', onUnhandledRejection);

const sandbox = {
    URL,
    console,
    setTimeout,
    clearTimeout,
    crypto: {
        randomUUID() {
            return `css-user-request-${messages.length + 1}`;
        },
    },
    performance,
    document: {
        documentElement: {},
        location: { hostname: 'old.example' },
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
sandbox.top = sandbox;
sandbox.chrome = {
    runtime: {
        sendMessage(request) {
            messages.push(structuredClone(request));
            if ( request.what === 'floorpCSSDocumentIdentity' ) {
                return Promise.resolve({
                    ok: true,
                    schema: 1,
                    requestId: request.requestId,
                    documentId: `${sandbox.document.location.hostname}-document`,
                    frameId: 0,
                });
            }
            if ( request.what !== 'injectCustomFilters' ) {
                throw new Error(`unexpected runtime message: ${request.what}`);
            }
            if ( request.hostname === 'old.example' ) {
                return firstReply.promise;
            }
            if ( request.hostname === 'new.example' ) {
                return Promise.resolve(ack(request, newDetails));
            }
            if ( request.hostname === 'third.example' ) {
                return Promise.resolve(ack(request, thirdDetails));
            }
            throw new Error(`unexpected hostname: ${request.hostname}`);
        },
    },
};
const makeCSSAPI = (label, documentId) => ({
    documentId,
    frameId: 0,
    suspendForIdentity() {},
    resumeForIdentity(record, receivedDocumentId, frameId) {
        if ( receivedDocumentId !== documentId || frameId !== 0 ) {
            return false;
        }
        if ( sandbox.floorpCSSUserIdentityPendingRecord === record ) {
            sandbox.floorpCSSUserIdentityPendingRecord = undefined;
        }
        return true;
    },
    insert(css) {
        insertions.push({ document: label, css });
        return Promise.resolve({
            ok: true,
            schema: 1,
            requestId: `${label}-css-insert`,
            documentId,
        });
    },
    commit() {
        return Promise.resolve({ ok: true, committed: true });
    },
});
sandbox.cssAPI = makeCSSAPI('old', 'old.example-document');

const context = vm.createContext(sandbox);
const script = new vm.Script(source, { filename: 'js/scripting/css-user.js' });

try {
    script.runInContext(context);
    await waitFor(
        ( ) => messages.some(message => message.hostname === 'old.example'),
        'the first document custom-filter request'
    );

    const firstPendingOp = sandbox.cssUserPendingOp;
    assert.equal(typeof firstPendingOp?.then, 'function');

    sandbox.document = {
        documentElement: {},
        location: { hostname: 'new.example' },
    };
    sandbox.cssAPI = makeCSSAPI('new', 'new.example-document');
    vm.runInContext(
        `self.customProceduralFiltererAPI = {
            reset(options) {
                self.previousFiltererResetCount += 1;
                self.previousFiltererResetOptions = options;
                if ( options?.removeCSS !== false ) {
                    return new Promise(( ) => {});
                }
            }
        };`,
        context
    );
    sandbox.previousFiltererResetCount = 0;

    script.runInContext(context);
    await waitFor(
        ( ) => sandbox.customFilters?.plainSelectors?.[0] ===
            '#new-document-filter',
        'the second document custom filters'
    );

    assert.equal(sandbox.previousFiltererResetCount, 1);
    assert.equal(sandbox.previousFiltererResetOptions.removeCSS, false);
    assert.deepEqual(
        messages
            .filter(message => message.what === 'injectCustomFilters')
            .map(message => message.hostname),
        [ 'old.example', 'new.example' ]
    );
    assert.deepEqual(insertions, [ {
        document: 'new',
        css: '#new-document-filter{display:none!important;}',
    } ]);
    assert.notEqual(sandbox.cssUserPendingOp, firstPendingOp);

    sandbox.document = {
        documentElement: {},
        location: { hostname: 'third.example' },
    };
    sandbox.cssAPI = makeCSSAPI('third', 'third.example-document');
    vm.runInContext(
        `self.customProceduralFiltererAPI = {
            reset() {
                self.throwingFiltererResetCount += 1;
                throw new Error('stale filterer reset failed synchronously');
            }
        };`,
        context
    );
    sandbox.throwingFiltererResetCount = 0;

    script.runInContext(context);
    await waitFor(
        ( ) => sandbox.customFilters?.plainSelectors?.[0] ===
            '#third-document-filter',
        'the third document custom filters after a synchronous reset failure'
    );
    assert.equal(sandbox.throwingFiltererResetCount, 1);

    const currentPendingOp = sandbox.cssUserPendingOp;
    firstReply.resolve(ack(
        messages.find(message =>
            message.what === 'injectCustomFilters' &&
            message.hostname === 'old.example'
        ),
        oldDetails
    ));
    await firstPendingOp;
    await nextTask();

    assert.equal(
        sandbox.customFilters.plainSelectors[0],
        '#third-document-filter'
    );
    assert.equal(sandbox.cssUserPendingOp, currentPendingOp);
    assert.deepEqual(insertions, [
        {
            document: 'new',
            css: '#new-document-filter{display:none!important;}',
        },
        {
            document: 'third',
            css: '#third-document-filter{display:none!important;}',
        },
    ]);
    assert.deepEqual(unhandledRejections, []);
} finally {
    process.off('unhandledRejection', onUnhandledRejection);
}

console.log('uBO css-user navigation tests passed');
