// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  indexAppleStrings,
  maskAppleStringValues,
  parseAppleStrings,
  replaceAppleStringValues
} from "../lib/apple-strings.mjs";
import { maskIntentDescription } from "../lib/intentdefinition.mjs";
import {
  OverlayError,
  applyBrandTokens,
  compileOverlay,
  sha256,
  transformCoveredFile
} from "../lib/overlay.mjs";

const fixtureRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "__fixtures__");

function fixture(name) {
  return readFileSync(path.join(fixtureRoot, name), "utf8");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function contextFor({
  filePath,
  kind = "strings",
  sourceValues,
  resultValues,
  modes,
  brandTokens = ["Firefox", "firefox", "Firefoksie"],
  additionalBrandTokens = ["فايرفوكس"],
  protectedTerms = ["Firefox Sync"],
  forbiddenOutputTerms = ["Floorp Sync"],
  exactOverrides = []
}) {
  const keys = Object.keys(sourceValues);
  const entries = Object.fromEntries(keys.map((key) => [key, {
    mode: modes?.[key] ?? "token",
    sourceSha256: sha256(sourceValues[key]),
    resultSha256: sha256(resultValues[key])
  }]));
  return compileOverlay({
    schemaVersion: 1,
    productName: "Floorp",
    protectedTerms,
    forbiddenOutputTerms,
    brandTokens,
    additionalBrandTokens,
    pathRules: [{
      id: "fixture",
      kind,
      pattern: `^${escapeRegExp(filePath)}$`,
      keys
    }],
    exactOverrides
  }, {
    schemaVersion: 1,
    files: { [filePath]: { kind, entries } }
  });
}

test("Apple strings parser handles a BOM, quoted keys, escapes, and literal newlines", () => {
  const text = `\uFEFF${fixture("quoted.strings")}`;
  const indexed = indexAppleStrings(parseAppleStrings(text, { file: "quoted.strings" }));
  assert.equal(indexed.get("Escaped\"Key").valueRaw, "Firefox says: \\\"hello\\\".\nSecond line.");

  const result = replaceAppleStringValues(text, new Map([["Welcome.Title", "Welcome to Floorp"]]));
  assert.ok(result.startsWith("\uFEFF/* Translator note"));
  assert.equal(result.replace("Welcome to Floorp", "Welcome to Firefox"), text);
});

test("Apple strings parser supports bare keys without reformatting the file", () => {
  const source = fixture("bare.strings");
  const expected = fixture("bare.expected.strings");
  const parsed = indexAppleStrings(parseAppleStrings(source, { file: "bare.strings" }));
  const replacements = new Map([
    ["NSCameraUsageDescription", "Floorp uses the camera."],
    ["BareKey", "Floorp private mode"]
  ]);
  assert.equal(replaceAppleStringValues(source, replacements), expected);
  assert.equal(parsed.get("NSCameraUsageDescription").keyToken, "NSCameraUsageDescription");
});

test("token replacement preserves protected Mozilla service names", () => {
  const manifest = {
    productName: "Floorp",
    protectedTerms: ["Firefox Sync"],
    brandTokens: ["Firefox"],
    additionalBrandTokens: []
  };
  assert.deepEqual(applyBrandTokens("Firefox Sync works with Firefox.", manifest), {
    value: "Firefox Sync works with Floorp.",
    replacementCount: 1
  });
});

test("overlay output is idempotent and byte-invariant outside allowlisted values", () => {
  const filePath = "fixtures/quoted.strings";
  const source = fixture("quoted.strings");
  const expected = fixture("quoted.expected.strings");
  const sourceEntries = indexAppleStrings(parseAppleStrings(source));
  const resultEntries = indexAppleStrings(parseAppleStrings(expected));
  const keys = [...sourceEntries.keys()];
  const context = contextFor({
    filePath,
    sourceValues: Object.fromEntries(keys.map((key) => [key, sourceEntries.get(key).valueRaw])),
    resultValues: Object.fromEntries(keys.map((key) => [key, resultEntries.get(key).valueRaw]))
  });

  const first = transformCoveredFile(context, filePath, source).text;
  const second = transformCoveredFile(context, filePath, first).text;
  assert.equal(first, expected);
  assert.equal(second, expected);
  assert.equal(maskAppleStringValues(source, keys), maskAppleStringValues(first, keys));
});

test("inflected and newly localized source spellings are explicit tokens", () => {
  const filePath = "fixtures/inflected.strings";
  const source = fixture("inflected.strings");
  const expected = fixture("inflected.expected.strings");
  const sourceEntries = indexAppleStrings(parseAppleStrings(source));
  const resultEntries = indexAppleStrings(parseAppleStrings(expected));
  const keys = [...sourceEntries.keys()];
  const context = contextFor({
    filePath,
    sourceValues: Object.fromEntries(keys.map((key) => [key, sourceEntries.get(key).valueRaw])),
    resultValues: Object.fromEntries(keys.map((key) => [key, resultEntries.get(key).valueRaw]))
  });
  assert.equal(transformCoveredFile(context, filePath, source).text, expected);
});

test("exact overrides reject source drift and remain idempotent", () => {
  const filePath = "fixtures/exact.strings";
  const key = "Open";
  const sourceValue = "Open Firefox from menu";
  const resultValue = "Open Floorp via menu";
  const context = contextFor({
    filePath,
    sourceValues: { [key]: sourceValue },
    resultValues: { [key]: resultValue },
    modes: { [key]: "exact" },
    exactOverrides: [{
      path: filePath,
      key,
      sourceSha256: sha256(sourceValue),
      resultSha256: sha256(resultValue),
      resultValue
    }]
  });
  const source = `"${key}" = "${sourceValue}";\n`;
  const result = `"${key}" = "${resultValue}";\n`;
  assert.equal(transformCoveredFile(context, filePath, source).text, result);
  assert.equal(transformCoveredFile(context, filePath, result).text, result);
  assert.throws(
    () => transformCoveredFile(context, filePath, `"${key}" = "Open Firefox now";\n`),
    (error) => error instanceof OverlayError && error.code === "EXACT_SOURCE_DRIFT"
  );
});

test("policy compilation rejects inconsistent exact hashes", () => {
  const filePath = "fixtures/exact.strings";
  const key = "Open";
  const sourceValue = "Open Firefox";
  const resultValue = "Open Floorp";
  assert.throws(
    () => contextFor({
      filePath,
      sourceValues: { [key]: sourceValue },
      resultValues: { [key]: resultValue },
      modes: { [key]: "exact" },
      exactOverrides: [{
        path: filePath,
        key,
        sourceSha256: sha256(sourceValue),
        resultSha256: sha256(resultValue),
        resultValue: "Tampered Floorp"
      }]
    }),
    (error) => error instanceof OverlayError && error.code === "EXACT_HASH"
  );
});

test("policy compilation rejects paths outside the repository", () => {
  const value = "Open Firefox";
  assert.throws(
    () => compileOverlay({
      schemaVersion: 1,
      productName: "Floorp",
      protectedTerms: [],
      forbiddenOutputTerms: [],
      brandTokens: ["Firefox"],
      additionalBrandTokens: [],
      pathRules: [{
        id: "outside",
        kind: "strings",
        pattern: "^\\.\\./outside\\.strings$",
        keys: ["Open"]
      }],
      exactOverrides: []
    }, {
      schemaVersion: 1,
      files: {
        "../outside.strings": {
          kind: "strings",
          entries: {
            Open: {
              mode: "token",
              sourceSha256: sha256(value),
              resultSha256: sha256("Open Floorp")
            }
          }
        }
      }
    }),
    (error) => error instanceof OverlayError && error.code === "UNSAFE_PATH"
  );
});

test("forbidden invented service names fail closed", () => {
  const filePath = "fixtures/service.strings";
  const context = contextFor({
    filePath,
    sourceValues: { Service: "Use Firefox Sync" },
    resultValues: { Service: "Use Floorp Sync" },
    protectedTerms: []
  });
  assert.throws(
    () => transformCoveredFile(context, filePath, '"Service" = "Use Firefox Sync";\n'),
    (error) => error instanceof OverlayError && error.code === "FORBIDDEN_OUTPUT_TERM"
  );
});

test("intent overlay changes only the reviewed description", () => {
  const filePath = "fixtures/WidgetIntents.intentdefinition";
  const source = fixture("WidgetIntents.intentdefinition");
  const expected = fixture("WidgetIntents.expected.intentdefinition");
  const context = contextFor({
    filePath,
    kind: "intentdefinition",
    sourceValues: { ctDNmu: "Open Firefox from the widget" },
    resultValues: { ctDNmu: "Open Floorp from the widget" }
  });
  const result = transformCoveredFile(context, filePath, source).text;
  assert.equal(result, expected);
  assert.equal(maskIntentDescription(source), maskIntentDescription(result));
});
