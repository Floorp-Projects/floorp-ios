import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

if (process.argv.length !== 3) {
    throw new Error("usage: node ubol_dnr_validator_test.mjs <dnr-parser.mjs>");
}

const { rulesFromText, validateDNRRuleShape } = await import(
    pathToFileURL(process.argv[2]).href
);

const rule = (condition = {}, action = { type: "block" }) => ({
    action,
    condition: { urlFilter: "*", ...condition },
});
const errorFor = candidate => validateDNRRuleShape(candidate) ?? "";

for (const key of [
    "excludedInitiatorDomains",
    "excludedRequestDomains",
    "excludedResourceTypes",
]) {
    assert.equal(errorFor(rule({ [key]: [] })), "", `${key} must allow []`);
}

for (const key of [
    "initiatorDomains",
    "requestDomains",
    "requestMethods",
    "resourceTypes",
]) {
    assert.match(errorFor(rule({ [key]: [] })), /non-empty/, key);
}

assert.equal(errorFor(rule({ urlFilter: "" })), "");
assert.equal(errorFor(rule({ urlFilter: "||*example.com" })), "");
assert.match(errorFor(rule({ urlFilter: 1 })), /must be a string/);
assert.match(
    errorFor(rule({ urlFilter: undefined, regexFilter: "" })),
    /non-empty/
);
assert.match(errorFor(rule({ urlFilter: "例.example" })), /ASCII/);
assert.match(errorFor(rule({ initiatorDomains: ["例.example"] })), /ASCII/);
assert.match(
    errorFor(rule({
        urlFilter: undefined,
        regexFilter: ".*",
        requestDomains: ["example.com"],
    })),
    /unsupported/
);
assert.equal(
    errorFor(rule({
        urlFilter: undefined,
        regexFilter: ".*",
        excludedRequestDomains: [],
    })),
    ""
);
assert.match(
    errorFor(rule({
        urlFilter: undefined,
        regexFilter: ".*",
        excludedRequestDomains: ["example.com"],
    })),
    /unsupported/
);
assert.match(errorFor(rule({ topDomains: ["example.com"] })), /unsupported/);
assert.equal(errorFor(rule({ excludedTopDomains: [] })), "");
assert.match(errorFor(rule({ excludedTopDomains: ["example.com"] })), /unsupported/);
assert.equal(errorFor(rule({ requestMethods: ["get"] })), "");
assert.equal(errorFor(rule({ excludedRequestMethods: ["post"] })), "");
assert.match(errorFor(rule({ excludedRequestMethods: [] })), /non-empty/);
assert.equal(
    errorFor(rule({ requestMethods: ["get"], excludedRequestMethods: ["post"] })),
    ""
);
assert.match(errorFor(rule({ requestMethods: ["other"] })), /unsupported/);
assert.equal(errorFor(rule({ requestMethods: ["trace"] })), "");
assert.match(errorFor(rule({ tabIds: [1] })), /unsupported/);
assert.match(errorFor(rule({ excludedTabIds: [] })), /unsupported/);
assert.match(errorFor(rule({ resourceTypes: ["object"] })), /unsupported/);
assert.match(errorFor(rule({ excludedResourceTypes: ["webtransport"] })), /unsupported/);
assert.match(errorFor(rule({ resourceTypes: ["made_up"] })), /unsupported/);
assert.match(
    errorFor(rule(
        { responseHeaders: [{ header: "content-type" }] },
    )),
    /unsupported/
);
assert.match(
    errorFor(rule({}, {
        type: "modifyHeaders",
        requestHeaders: [{ header: "x-test", operation: "set", value: "1" }],
    })),
    /unsupported/
);

assert.match(
    errorFor(rule({}, {
        type: "redirect",
        redirect: { regexSubstitution: "https://example.com/\\1" },
    })),
    /requires condition\.regexFilter/
);
assert.match(
    errorFor(rule({}, {
        type: "redirect",
        redirect: { extensionPath: "asset.js" },
    })),
    /must start/
);
assert.match(
    errorFor(rule({}, {
        type: "redirect",
        redirect: { url: "ftp://example.com/file" },
    })),
    /http or https/
);
for (const [transform, expected] of [
    [{ fragment: "section" }, /start with #/],
    [{ query: "a=1" }, /start with \?/],
    [{ port: "65536" }, /uint16/],
    [{ port: "not-a-port" }, /uint16/],
    [{ scheme: "javascript" }, /invalid/],
    [{ scheme: "1https" }, /invalid/],
]) {
    assert.match(
        errorFor(rule({}, { type: "redirect", redirect: { transform } })),
        expected
    );
}
for (const transform of [
    { fragment: "#section" },
    { query: "?a=1" },
    { port: "65535" },
    { scheme: "https" },
    {
        queryTransform: {
            addOrReplaceParams: [{ key: "", value: "value" }],
        },
    },
]) {
    assert.equal(
        errorFor(rule({}, { type: "redirect", redirect: { transform } })),
        ""
    );
}
assert.match(
    errorFor(rule({}, { type: "allowAllRequests" })),
    /requires resourceTypes/
);
assert.match(
    errorFor(rule(
        { resourceTypes: ["script"] },
        { type: "allowAllRequests" },
    )),
    /only main_frame/
);
assert.equal(
    errorFor(rule(
        { resourceTypes: ["main_frame"] },
        { type: "allowAllRequests" },
    )),
    ""
);
assert.match(
    errorFor(rule(
        { resourceTypes: ["sub_frame"] },
        { type: "allowAllRequests" },
    )),
    /only main_frame/
);
assert.match(
    errorFor(rule(
        { resourceTypes: ["main_frame"], requestMethods: ["get"] },
        { type: "allowAllRequests" },
    )),
    /does not support requestMethods/
);
assert.match(
    errorFor(rule(
        { resourceTypes: ["main_frame"], excludedRequestMethods: ["post"] },
        { type: "allowAllRequests" },
    )),
    /does not support excludedRequestMethods/
);
for (const condition of [
    { resourceTypes: ["main_frame"], domainType: "thirdParty" },
    { resourceTypes: ["main_frame"], initiatorDomains: ["example.com"] },
    { resourceTypes: ["main_frame"], excludedInitiatorDomains: ["example.com"] },
]) {
    assert.match(
        errorFor(rule(condition, { type: "allowAllRequests" })),
        /does not support/
    );
}
assert.equal(
    errorFor(rule(
        { resourceTypes: ["main_frame"], excludedInitiatorDomains: [] },
        { type: "allowAllRequests" },
    )),
    ""
);
assert.match(
    errorFor(rule(
        {
            resourceTypes: ["main_frame"],
            isUrlFilterCaseSensitive: true,
        },
        { type: "allowAllRequests" },
    )),
    /case-sensitive/
);

const parsedEmptyExclusion = rulesFromText([
    "action:",
    "  type: block",
    "condition:",
    "  urlFilter: '*'",
    "  excludedInitiatorDomains:",
].join("\n"));
assert.deepEqual(parsedEmptyExclusion.bad, []);
assert.equal(parsedEmptyExclusion.rules.length, 1);
assert.equal(errorFor(parsedEmptyExclusion.rules[0]), "");

console.log("uBO Safari DNR validator tests passed");
