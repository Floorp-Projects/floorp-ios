import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

if (process.argv.length !== 3) {
    throw new Error(
        "usage: node ubol_safari_regex_normalizer_test.mjs <extracted-archive-root>"
    );
}

const root = resolve(process.argv[2]);
const moduleSource = await readFile(
    resolve(root, "js/safari-regex-normalizer.js"),
    "utf8"
);
const moduleURL = `data:text/javascript;base64,${Buffer.from(moduleSource).toString("base64")}`;
const {
    fingerprintSafariRegexRule,
    normalizeSafariRegexRequestDomains,
} = await import(moduleURL);

const readRules = async name => JSON.parse(await readFile(
    resolve(root, `rulesets/regex/${name}.json`),
    "utf8"
));

const ublockRules = await readRules("ublock-filters");
const overlayRules = await readRules("annoyances-overlays");
const requestDomainRules = ublockRules.filter(rule =>
    rule.condition.regexFilter !== undefined &&
    rule.condition.requestDomains !== undefined
);

assert.equal(requestDomainRules.length, 52);
const sourceSnapshot = structuredClone(requestDomainRules);
const rejectedRules = [];
const normalizedRules = await normalizeSafariRegexRequestDomains(
    requestDomainRules,
    rejectedRules
);

// Ten audited source rules survive: four one-for-one and six expanded into
// 2 + 5 + 5 + 5 + 2 + 2 literal-domain rules.
assert.equal(normalizedRules.length, 25);
assert.equal(rejectedRules.length, 42);
assert.deepEqual(requestDomainRules, sourceSnapshot, "source rules must not mutate");
assert.equal(normalizedRules.some(rule =>
    rule.condition.regexFilter !== undefined &&
    rule.condition.requestDomains !== undefined
), false);

const rulesById = new Map(requestDomainRules.map(rule => [rule.id, rule]));

for (const id of [18, 30, 105, 114]) {
    const source = rulesById.get(id);
    const changedId = structuredClone(source);
    changedId.id += 100000;
    assert.equal(
        await fingerprintSafariRegexRule(source),
        await fingerprintSafariRegexRule(changedId),
        `rule ${id} fingerprint must not depend on its dynamic ID`
    );
    const output = await normalizeSafariRegexRequestDomains([changedId]);
    assert.equal(output.length, 1);
    const expected = structuredClone(changedId);
    delete expected.condition.requestDomains;
    assert.deepEqual(output[0], expected);
}

const expansionCases = new Map([
    [17, "\\.[ci][on]m?\\/"],
    [26, "\\.[cipx][nory][fmoz]?o?\\/"],
    [27, "\\.[cins][cehlo][imotu][cp]?k?\\/"],
    [29, "\\.[a-z]+\\/"],
    [53, "\\.[cr][ef][ds]t?\\/"],
    [54, "\\.[cr][ef][ds]t?\\/"],
]);

for (const [id, hostFragment] of expansionCases) {
    const source = rulesById.get(id);
    const domains = source.condition.requestDomains;
    assert.equal(source.condition.regexFilter.split(hostFragment).length, 2);
    for (const domain of domains) {
        assert.match(
            `.${domain}/`,
            new RegExp(`^${hostFragment}$`),
            `rule ${id} literal must belong to the original host language`
        );
    }

    const changedId = structuredClone(source);
    changedId.id += 100000;
    const output = await normalizeSafariRegexRequestDomains([changedId]);
    assert.equal(output.length, domains.length);
    for (let index = 0; index < domains.length; index++) {
        const expected = structuredClone(changedId);
        const literalHost = `\\.${domains[index].replaceAll(".", "\\.")}\\/`;
        expected.condition.regexFilter = expected.condition.regexFilter.replace(
            hostFragment,
            literalHost
        );
        delete expected.condition.requestDomains;
        assert.deepEqual(output[index], expected);
        assert.equal(output[index].condition.regexFilter.startsWith("^"), true);
    }
}

// These native-supported source rules cannot be exactly normalized.
for (const id of [3, 20, 28, 70]) {
    assert.deepEqual(
        await normalizeSafariRegexRequestDomains([rulesById.get(id)]),
        [],
        `rule ${id} must fail closed`
    );
}
const overlayRedirect = overlayRules.find(rule => rule.id === 2);
assert.deepEqual(
    await normalizeSafariRegexRequestDomains([overlayRedirect]),
    [],
    "path-only regex substitution must fail closed"
);

const chineseRules = await readRules("chn-0");
const excludedRequestDomainRule = chineseRules.find(rule =>
    rule.id === 14 &&
    rule.condition.regexFilter !== undefined &&
    rule.condition.excludedRequestDomains !== undefined
);
assert.deepEqual(
    await normalizeSafariRegexRequestDomains([excludedRequestDomainRule]),
    [],
    "inexact excludedRequestDomains translation must fail closed"
);

// Any semantic change invalidates the complete source fingerprint.
const modifiedWhitelistedRule = structuredClone(rulesById.get(18));
modifiedWhitelistedRule.priority += 1;
assert.deepEqual(
    await normalizeSafariRegexRequestDomains([modifiedWhitelistedRule]),
    []
);

const passThroughRule = ublockRules.find(rule =>
    rule.condition.regexFilter !== undefined &&
    rule.condition.requestDomains === undefined
);
const passThroughOutput = await normalizeSafariRegexRequestDomains([
    passThroughRule,
]);
assert.strictEqual(passThroughOutput[0], passThroughRule);
const emptyExcludedRequestDomains = structuredClone(passThroughRule);
emptyExcludedRequestDomains.condition.excludedRequestDomains = [];
assert.deepEqual(
    await normalizeSafariRegexRequestDomains([emptyExcludedRequestDomains]),
    [emptyExcludedRequestDomains]
);

// Safari 26 supports the standard initiator keys. The compatibility layer
// must not rewrite them to legacy document-domain aliases before submission.
const extCompatSource = await readFile(resolve(root, "js/ext-compat.js"), "utf8");
assert.doesNotMatch(
    extCompatSource,
    /condition\.domains\s*=\s*r\.condition\.initiatorDomains/
);
assert.doesNotMatch(
    extCompatSource,
    /condition\.excludedDomains\s*=\s*r\.condition\.excludedInitiatorDomains/
);
assert.match(extCompatSource, /rule0\.condition\.initiatorDomains = allowed/);
assert.match(
    extCompatSource,
    /rule0\.condition\.excludedInitiatorDomains = notAllowed/
);
assert.match(
    extCompatSource,
    /normalizeSafariDNRRules\(addRules\)/,
    "native updates must use the common Safari normalizer"
);

const dnrNormalizerSource = await readFile(
    resolve(root, "js/safari-dnr-normalizer.js"),
    "utf8"
);
const dnrNormalizerURL = `data:text/javascript;base64,${Buffer.from(
    dnrNormalizerSource
).toString("base64")}`;
const { normalizeSafariDNRRules } = await import(dnrNormalizerURL);

const polRules = JSON.parse(await readFile(
    resolve(root, "rulesets/regex/pol-0.json"),
    "utf8"
));
const polObjectRules = polRules.filter(rule =>
    rule.condition.resourceTypes?.includes("object")
);
assert.deepEqual(polObjectRules.map(rule => rule.id), [1, 36]);
const polSnapshot = structuredClone(polObjectRules);
const polDesired = normalizeSafariDNRRules(polObjectRules);
assert.deepEqual(polObjectRules, polSnapshot, "normalization must clone sources");
assert.equal(polDesired.length, 2);
assert.deepEqual(polDesired[0].condition.resourceTypes, ["image"]);
assert.deepEqual(polDesired[1].condition.resourceTypes, ["xmlhttprequest"]);
assert.deepEqual(
    normalizeSafariDNRRules(polDesired),
    polDesired,
    "desired and native normalization must converge"
);

const basicRule = {
    id: 1,
    action: { type: "block" },
    condition: { urlFilter: "example" },
};
const standardInitiatorRule = structuredClone(basicRule);
standardInitiatorRule.condition.initiatorDomains = ["example.com"];
standardInitiatorRule.condition.excludedInitiatorDomains = ["www.example.com"];
assert.deepEqual(
    normalizeSafariDNRRules([standardInitiatorRule]),
    [standardInitiatorRule],
    "Safari 26 standard initiator-domain keys must pass unchanged"
);

const excludedObjectOnly = structuredClone(basicRule);
excludedObjectOnly.condition.excludedResourceTypes = ["object"];
assert.deepEqual(
    normalizeSafariDNRRules([excludedObjectOnly]),
    [],
    "an unsupported excluded type must fail closed"
);
const excludedObjectMixed = structuredClone(basicRule);
excludedObjectMixed.condition.excludedResourceTypes = ["main_frame", "object"];
assert.deepEqual(
    normalizeSafariDNRRules([excludedObjectMixed]),
    [],
    "a mixed excluded type array must fail closed instead of broadening"
);
const excludedOtherMethod = structuredClone(basicRule);
excludedOtherMethod.condition.excludedRequestMethods = ["other"];
assert.deepEqual(
    normalizeSafariDNRRules([excludedOtherMethod]),
    [],
    "an unsupported excluded request method must fail closed"
);
for (const key of ["excludedResourceTypes", "excludedRequestMethods"]) {
    const emptyExclusion = structuredClone(basicRule);
    emptyExclusion.condition[key] = [];
    const output = normalizeSafariDNRRules([emptyExclusion]);
    assert.equal(output.length, 1);
    assert.equal(
        key in output[0].condition,
        false,
        `${key} empty no-op must be stripped`
    );
}

for (const conditionPatch of [
    { topDomains: ["example.com"] },
    { excludedTopDomains: ["example.com"] },
    { tabIds: [1] },
    { excludedTabIds: [1] },
    { responseHeaders: [{ header: "content-type" }] },
]) {
    const rule = structuredClone(basicRule);
    Object.assign(rule.condition, conditionPatch);
    assert.deepEqual(
        normalizeSafariDNRRules([rule]),
        [],
        `${Object.keys(conditionPatch)[0]} must fail closed`
    );
}
const emptyExcludedTopDomains = structuredClone(basicRule);
emptyExcludedTopDomains.condition.excludedTopDomains = [];
const emptyExcludedTopOutput = normalizeSafariDNRRules([
    emptyExcludedTopDomains,
]);
assert.equal(emptyExcludedTopOutput.length, 1);
assert.equal(
    "excludedTopDomains" in emptyExcludedTopOutput[0].condition,
    false,
    "an empty exclusion is the only safe unsupported-condition no-op"
);

for (const requestDomainPatch of [
    { requestDomains: ["example.com"] },
    { excludedRequestDomains: ["example.com"] },
]) {
    const allowAllRule = {
        id: 2,
        action: { type: "allowAllRequests" },
        condition: {
            resourceTypes: ["main_frame"],
            urlFilter: "example",
            ...requestDomainPatch,
        },
    };
    assert.deepEqual(
        normalizeSafariDNRRules([allowAllRule]),
        [],
        "unverified allowAllRequests request-domain constraints must fail closed"
    );
}
const allowAllEmptyExclusion = {
    id: 3,
    action: { type: "allowAllRequests" },
    condition: {
        excludedRequestDomains: [],
        resourceTypes: ["main_frame"],
        urlFilter: "example",
    },
};
const allowAllEmptyOutput = normalizeSafariDNRRules([
    allowAllEmptyExclusion,
]);
assert.equal(allowAllEmptyOutput.length, 1);
assert.equal(
    "excludedRequestDomains" in allowAllEmptyOutput[0].condition,
    false
);

const parserSource = await readFile(resolve(root, "js/dnr-parser.js"), "utf8");
const parserURL = `data:text/javascript;base64,${Buffer.from(parserSource).toString("base64")}`;
const {
    validateDNRRuleShape,
    validatedRulesFromText,
} = await import(parserURL);
for (const condition of [
    { requestDomains: ["example.com"] },
    { excludedRequestDomains: ["example.com"] },
]) {
    assert.match(validateDNRRuleShape({
        action: { type: "block" },
        condition: {
            regexFilter: "example",
            ...condition,
        },
    }), /unsupported by Safari 26\.0/);
}
assert.equal(validateDNRRuleShape({
    action: { type: "block" },
    condition: {
        regexFilter: "example",
        excludedRequestDomains: [],
    },
}), undefined);

for (const condition of [
    { topDomains: ["example.com"] },
    { excludedTopDomains: ["example.com"] },
]) {
    assert.match(validateDNRRuleShape({
        action: { type: "block" },
        condition: { urlFilter: "example", ...condition },
    }), /unsupported by Safari/);
}
assert.match(validateDNRRuleShape({
    action: { type: "allowAllRequests" },
    condition: {
        requestDomains: ["example.com"],
        resourceTypes: ["main_frame"],
        urlFilter: "example",
    },
}), /does not support requestDomains/);

const draftResult = validatedRulesFromText(`action:
  type: block
condition:
  urlFilter: ||example.com/
---
action:
  type:
`);
assert.equal(draftResult.rules.length, 1);
assert.equal(draftResult.bad.length, 1);
assert.deepEqual(
    draftResult.shapeErrors,
    [],
    "parser-bad draft documents stay ignored while effective rules validate"
);
const broadeningResult = validatedRulesFromText(`action:
  type: block
condition:
  excludedTopDomains:
    - example.com
  urlFilter: example
`);
assert.equal(broadeningResult.bad.length, 0);
assert.match(broadeningResult.shapeErrors[0], /excludedTopDomains|topDomains/);

const rulesetManagerSource = await readFile(
    resolve(root, "js/ruleset-manager.js"),
    "utf8"
);
const liveUpdateStart = rulesetManagerSource.indexOf(
    "async function updateUserRules"
);
const liveUpdateEnd = rulesetManagerSource.indexOf(
    "/******************************************************************************/",
    liveUpdateStart
);
const liveUpdateSource = rulesetManagerSource.slice(
    liveUpdateStart,
    liveUpdateEnd
);
assert.ok(liveUpdateSource.indexOf("shapeErrors.length") !== -1);
assert.ok(
    liveUpdateSource.indexOf("shapeErrors.length") <
    liveUpdateSource.indexOf("sandboxRules.forEach")
);
assert.ok(
    liveUpdateSource.indexOf("return out;") <
    liveUpdateSource.indexOf("removeRuleIds")
);
assert.match(liveUpdateSource, /if \( throwOnError \) \{ throw reason; \}/);
assert.match(
    rulesetManagerSource,
    /normalizeSafariDNRRules\([\s\S]*compatibilityRejected/
);

const makeLiveUserRuleUpdater = ({ rejectAt }) => {
    let installedRules = [{
        id: 1_000_000,
        priority: 100,
        action: { type: "block" },
        condition: { urlFilter: "installed.example" },
    }];
    const originalInstalledRules = structuredClone(installedRules);
    const nativeUpdates = [];
    const storageMutations = [];
    const candidateRules = [
        {
            action: { type: "block" },
            condition: { regexFilter: "accepted" },
        },
        {
            action: { type: "block" },
            condition: { regexFilter: "rejected" },
        },
    ];
    const dependencies = {
        getEffectiveUserRules: async () => structuredClone(installedRules),
        localRead: async key => key === "userDnrRules" ? "candidate rules" : undefined,
        rulesetConfig: { developerMode: true },
        validatedRulesFromText: () => ({
            rules: structuredClone(candidateRules),
            shapeErrors: [],
        }),
        USER_RULES_PRIORITY: 100,
        pruneInvalidRegexRules: async (_label, rules, rejected) => {
            if ( rejectAt === "regex" ) {
                rejected.push({
                    regex: rules[1].condition.regexFilter,
                    reason: "unsupported regex",
                });
                return rules.slice(0, 1);
            }
            return rules;
        },
        normalizeSafariDNRRules: (rules, rejected) => {
            if ( rejectAt === "compatibility" ) {
                rejected.push({ reason: "unsupported Safari condition" });
                return rules.slice(0, 1);
            }
            return rules;
        },
        localRemove: async key => storageMutations.push(["remove", key]),
        localWrite: async (key, value) => storageMutations.push([
            "write",
            key,
            value,
        ]),
        USER_RULES_BASE_RULE_ID: 1_000_000,
        deepEquals: (left, right) => JSON.stringify(left) === JSON.stringify(right),
        dnr: {
            updateDynamicRules: async update => {
                nativeUpdates.push(structuredClone(update));
                if ( rejectAt === "rollback-error" && nativeUpdates.length === 2 ) {
                    throw new Error("mock rollback failure");
                }
                if (
                    rejectAt === "update-error-partial" &&
                    nativeUpdates.length === 1
                ) {
                    installedRules = structuredClone(update.addRules.slice(0, 1));
                    throw new Error("mock initial update failure");
                }
                if (
                    ["readback", "rollback-error"].includes(rejectAt) &&
                    nativeUpdates.length === 1
                ) {
                    installedRules = structuredClone(update.addRules.slice(0, 1));
                } else {
                    installedRules = structuredClone(update.addRules || []);
                }
            },
        },
        ubolLog: () => undefined,
        ubolErr: () => undefined,
    };
    const dependencyNames = Object.keys(dependencies);
    const factory = new Function(
        ...dependencyNames,
        `"use strict";\n${liveUpdateSource}\nreturn updateUserRules;`
    );
    return {
        updateUserRules: factory(...Object.values(dependencies)),
        state: () => ({
            installedRules,
            nativeUpdates,
            originalInstalledRules,
            storageMutations,
        }),
    };
};

for (const rejectAt of ["regex", "compatibility"]) {
    for (const throwOnError of [false, true]) {
        const { updateUserRules, state } = makeLiveUserRuleUpdater({ rejectAt });
        let result;
        let failure;
        try {
            result = await updateUserRules(throwOnError);
        } catch (reason) {
            failure = reason;
        }
        if ( throwOnError ) {
            assert.match(
                failure?.message || "",
                /User DNR compatibility validation failed/
            );
        } else {
            assert.equal(failure, undefined);
            assert.equal(result.added, 0);
            assert.equal(result.removed, 0);
            assert.equal(result.errors.length, 1);
        }
        const finalState = state();
        assert.deepEqual(
            finalState.nativeUpdates,
            [],
            `${rejectAt} rejection must not call WebKit updateDynamicRules`
        );
        assert.deepEqual(
            finalState.installedRules,
            finalState.originalInstalledRules,
            `${rejectAt} rejection must retain the installed user DNR set`
        );
        assert.deepEqual(
            finalState.storageMutations,
            [],
            `${rejectAt} rejection must not rewrite installed-rule metadata`
        );
    }
}

for (const throwOnError of [false, true]) {
    const { updateUserRules, state } = makeLiveUserRuleUpdater({
        rejectAt: "readback",
    });
    let result;
    let failure;
    try {
        result = await updateUserRules(throwOnError);
    } catch (reason) {
        failure = reason;
    }
    if ( throwOnError ) {
        assert.match(failure?.message || "", /User-rule DNR readback mismatch/);
    } else {
        assert.equal(failure, undefined);
        assert.equal(result.added, 0);
        assert.equal(result.removed, 0);
        assert.match(result.errors[0], /User-rule DNR readback mismatch/);
    }
    const finalState = state();
    assert.equal(
        finalState.nativeUpdates.length,
        2,
        "a silent partial apply must be followed by one native rollback"
    );
    assert.deepEqual(
        finalState.installedRules,
        finalState.originalInstalledRules,
        "a silent partial apply must restore the complete installed snapshot"
    );
    assert.deepEqual(
        finalState.storageMutations,
        [["write", "userDnrRuleCount", 1]],
        "successful rollback must retain the installed-rule count"
    );
}

for (const throwOnError of [false, true]) {
    const { updateUserRules, state } = makeLiveUserRuleUpdater({
        rejectAt: "update-error-partial",
    });
    let result;
    let failure;
    try {
        result = await updateUserRules(throwOnError);
    } catch (reason) {
        failure = reason;
    }
    if ( throwOnError ) {
        assert.match(failure?.message || "", /mock initial update failure/);
    } else {
        assert.equal(failure, undefined);
        assert.match(result.errors[0], /mock initial update failure/);
    }
    const finalState = state();
    assert.equal(
        finalState.nativeUpdates.length,
        2,
        "a throwing partial apply must still trigger one native rollback"
    );
    assert.deepEqual(
        finalState.installedRules,
        finalState.originalInstalledRules,
        "a throwing partial apply must restore the installed snapshot"
    );
}

for (const throwOnError of [false, true]) {
    const { updateUserRules, state } = makeLiveUserRuleUpdater({
        rejectAt: "rollback-error",
    });
    let result;
    let failure;
    try {
        result = await updateUserRules(throwOnError);
    } catch (reason) {
        failure = reason;
    }
    if ( throwOnError ) {
        assert.equal(failure instanceof AggregateError, true);
        assert.match(failure.message, /installed-rule rollback failed/);
    } else {
        assert.equal(failure, undefined);
        assert.match(result.errors[0], /installed-rule rollback failed/);
    }
    assert.equal(
        state().nativeUpdates.length,
        2,
        "rollback failure must remain explicit after the recovery attempt"
    );
}

const sessionUpdateStart = rulesetManagerSource.indexOf(
    "async function updateSessionRules"
);
const sessionUpdateEnd = rulesetManagerSource.indexOf(
    "async function clearSessionRules",
    sessionUpdateStart
);
const sessionUpdateSource = rulesetManagerSource.slice(
    sessionUpdateStart,
    sessionUpdateEnd
);
const sessionSnapshot = [
    {
        id: 1,
        action: { type: "block" },
        condition: { urlFilter: "first.installed.example" },
    },
    {
        id: 2,
        action: { type: "block" },
        condition: { urlFilter: "second.installed.example" },
    },
];
let installedSessionRules = structuredClone(sessionSnapshot);
const sessionNativeUpdates = [];
const sessionDependencies = {
    dnr: {
        MAX_NUMBER_OF_REGEX_RULES: 1_000,
        getSessionRules: async () => structuredClone(installedSessionRules),
        updateSessionRules: async update => {
            sessionNativeUpdates.push(structuredClone(update));
            installedSessionRules = sessionNativeUpdates.length === 1
                ? []
                : structuredClone(update.addRules || []);
        },
    },
    updateStrictBlockRules: async (currentRules, addRules, removeRuleIds) => {
        removeRuleIds.push(...currentRules.map(rule => rule.id));
        addRules.push({
            action: { type: "block" },
            condition: { urlFilter: "desired.example" },
        });
    },
    normalizeDesiredRules: rules => structuredClone(rules),
    getDynamicRegexRuleCount: async () => 0,
    deepEquals: (left, right) => JSON.stringify(left) === JSON.stringify(right),
    ubolLog: () => undefined,
    ubolErr: () => undefined,
};
const sessionFactory = new Function(
    ...Object.keys(sessionDependencies),
    `"use strict";\n${sessionUpdateSource}\nreturn updateSessionRules;`
);
const updateSessionRules = sessionFactory(...Object.values(sessionDependencies));
const sessionResult = await updateSessionRules();
assert.match(sessionResult.error, /Session DNR readback mismatch/);
assert.equal(
    sessionNativeUpdates.length,
    2,
    "a silent partial session apply must be followed by one native rollback"
);
assert.deepEqual(
    installedSessionRules,
    sessionSnapshot,
    "session rollback must restore and verify the complete native snapshot"
);

assert.equal(
    (rulesetManagerSource.match(
        /if \( webextFlavor === 'safari' \) \{ return; \}/g
    ) || []).length,
    1,
    "strict-block Safari early return must occur exactly once"
);

const backupRestoreSource = await readFile(
    resolve(root, "js/backup-restore.js"),
    "utf8"
);
assert.match(
    backupRestoreSource,
    /The finalizer auto-completes a rollingBack journal[\s\S]*if \( reconciliation\.rolledBack === true \) \{[\s\S]*rollback = \{ rolledBack: true \};[\s\S]*else \{[\s\S]*what: 'rollbackSettingsRestore',[\s\S]*id: transaction\.id,[\s\S]*if \( rollback\?\.rolledBack !== true \)/,
    "foreground rollback must accept finalizer completion or resend the same ID"
);

const backgroundSource = await readFile(
    resolve(root, "js/background.js"),
    "utf8"
);
assert.match(
    backgroundSource,
    /what === 'floorpFinalizeForegroundReconciliation'[\s\S]*rolledBack: result\?\.rolledBack === true/,
    "the background finalizer must mark an auto-completed rollback"
);
const foregroundReconcileSource = await readFile(
    resolve(root, "js/floorp-reconcile.js"),
    "utf8"
);
assert.match(
    foregroundReconcileSource,
    /rolledBack: finalized\?\.rolledBack === true/,
    "the foreground realm must propagate finalizer rollback state"
);

console.log("Safari DNR compatibility tests passed");
