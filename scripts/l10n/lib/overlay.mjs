// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import { createHash } from "node:crypto";
import nodePath from "node:path";
import {
  indexAppleStrings,
  maskAppleStringValues,
  parseAppleStrings,
  replaceAppleStringValues
} from "./apple-strings.mjs";
import {
  maskIntentDescription,
  parseIntentDescription,
  replaceIntentDescription
} from "./intentdefinition.mjs";

export class OverlayError extends Error {
  constructor(code, message, details = {}) {
    super(`${code}: ${message}`);
    this.name = "OverlayError";
    this.code = code;
    this.details = details;
  }
}

export function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

export function canonicalJSON(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function assertStringArray(value, name, { allowEmpty = true } = {}) {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0) ||
      value.some((entry) => typeof entry !== "string" || entry.length === 0)) {
    throw new OverlayError("SCHEMA_VALUE", `${name} must be an array of non-empty strings`);
  }
  if (new Set(value).size !== value.length) {
    throw new OverlayError("SCHEMA_DUPLICATE", `${name} contains duplicate values`);
  }
}

function assertDigest(value, name) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/u.test(value)) {
    throw new OverlayError("SCHEMA_DIGEST", `${name} must be a lowercase SHA-256 digest`);
  }
}

function assertRepositoryPath(value, name) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\0") ||
      value.includes("\\") || nodePath.posix.isAbsolute(value) ||
      nodePath.win32.isAbsolute(value) || nodePath.posix.normalize(value) !== value ||
      value === "." || value.startsWith("../")) {
    throw new OverlayError("UNSAFE_PATH", `${name} is not a canonical repository-relative path`);
  }
}

function countOccurrences(value, needle) {
  if (needle.length === 0) return 0;
  return value.split(needle).length - 1;
}

function replaceEvery(value, search, replacement) {
  return value.split(search).join(replacement);
}

function protectedCounts(value, terms) {
  return new Map(terms.map((term) => [term, countOccurrences(value, term)]));
}

function assertProtectedCounts(before, after, terms, path, key) {
  const previous = protectedCounts(before, terms);
  const next = protectedCounts(after, terms);
  for (const term of terms) {
    if (previous.get(term) !== next.get(term)) {
      throw new OverlayError(
        "PROTECTED_TERM_CHANGED",
        `${path}:${key} changed protected term '${term}'`,
        { path, key, term, before: previous.get(term), after: next.get(term) }
      );
    }
  }
}

export function applyBrandTokens(value, manifest) {
  const protectedTerms = [...manifest.protectedTerms].sort((left, right) => right.length - left.length);
  const tokens = [
    ...manifest.brandTokens,
    ...(manifest.additionalBrandTokens ?? [])
  ].sort((left, right) => right.length - left.length);
  const sentinels = [];
  let protectedValue = value;

  protectedTerms.forEach((term, index) => {
    const sentinel = `\u{E000}FLOORP_PROTECTED_${index}\u{E001}`;
    if (protectedValue.includes(sentinel)) {
      throw new OverlayError("SENTINEL_COLLISION", `input contains reserved sentinel for '${term}'`);
    }
    const occurrences = countOccurrences(protectedValue, term);
    sentinels.push({ sentinel, term, occurrences });
    protectedValue = replaceEvery(protectedValue, term, sentinel);
  });

  let replacementCount = 0;
  for (const token of tokens) {
    const occurrences = countOccurrences(protectedValue, token);
    if (occurrences > 0) {
      replacementCount += occurrences;
      protectedValue = replaceEvery(protectedValue, token, manifest.productName);
    }
  }

  for (const { sentinel, term } of sentinels) {
    protectedValue = replaceEvery(protectedValue, sentinel, term);
  }
  return { value: protectedValue, replacementCount };
}

function validateOutput(before, after, manifest, path, key) {
  assertProtectedCounts(before, after, manifest.protectedTerms, path, key);
  for (const term of manifest.forbiddenOutputTerms) {
    if (after.includes(term)) {
      throw new OverlayError(
        "FORBIDDEN_OUTPUT_TERM",
        `${path}:${key} produced forbidden service name '${term}'`,
        { path, key, term }
      );
    }
  }
  if (!after.includes(manifest.productName)) {
    throw new OverlayError(
      "PRODUCT_NAME_MISSING",
      `${path}:${key} does not contain '${manifest.productName}' after transformation`,
      { path, key }
    );
  }

  let unprotected = after;
  for (const term of manifest.protectedTerms) unprotected = replaceEvery(unprotected, term, "");
  for (const token of [...manifest.brandTokens, ...(manifest.additionalBrandTokens ?? [])]) {
    if (unprotected.includes(token)) {
      throw new OverlayError(
        "LEGACY_TOKEN_REMAINS",
        `${path}:${key} still contains legacy token '${token}'`,
        { path, key, token }
      );
    }
  }
}

export function compileOverlay(manifest, coverage) {
  if (!manifest || !coverage || manifest.schemaVersion !== 1 || coverage.schemaVersion !== 1) {
    throw new OverlayError("SCHEMA_VERSION", "unsupported manifest or coverage schema");
  }
  if (typeof manifest.productName !== "string" || manifest.productName.length === 0) {
    throw new OverlayError("SCHEMA_VALUE", "productName must be a non-empty string");
  }
  assertStringArray(manifest.protectedTerms, "protectedTerms");
  assertStringArray(manifest.forbiddenOutputTerms, "forbiddenOutputTerms");
  assertStringArray(manifest.brandTokens, "brandTokens", { allowEmpty: false });
  assertStringArray(manifest.additionalBrandTokens ?? [], "additionalBrandTokens");
  const allTokens = [...manifest.brandTokens, ...(manifest.additionalBrandTokens ?? [])];
  if (new Set(allTokens).size !== allTokens.length || allTokens.includes(manifest.productName)) {
    throw new OverlayError(
      "SCHEMA_DUPLICATE",
      "brand token lists must be disjoint and must not contain productName"
    );
  }
  if (!Array.isArray(manifest.pathRules) || manifest.pathRules.length === 0) {
    throw new OverlayError("SCHEMA_VALUE", "pathRules must be a non-empty array");
  }
  if (!Array.isArray(manifest.exactOverrides)) {
    throw new OverlayError("SCHEMA_VALUE", "exactOverrides must be an array");
  }
  if (!coverage.files || typeof coverage.files !== "object" || Array.isArray(coverage.files)) {
    throw new OverlayError("SCHEMA_VALUE", "coverage.files must be an object");
  }

  const ruleIDs = new Set();
  const rules = manifest.pathRules.map((rule, index) => {
    if (!rule || typeof rule.id !== "string" || rule.id.length === 0 || ruleIDs.has(rule.id)) {
      throw new OverlayError("SCHEMA_DUPLICATE", `pathRules[${index}] has an invalid or duplicate id`);
    }
    ruleIDs.add(rule.id);
    if (rule.kind !== "strings" && rule.kind !== "intentdefinition") {
      throw new OverlayError("FILE_KIND", `path rule '${rule.id}' has unsupported kind '${rule.kind}'`);
    }
    if (typeof rule.pattern !== "string" || rule.pattern.length === 0) {
      throw new OverlayError("SCHEMA_VALUE", `path rule '${rule.id}' has no pattern`);
    }
    assertStringArray(rule.keys, `path rule '${rule.id}' keys`, { allowEmpty: false });
    return { ...rule, expression: new RegExp(rule.pattern, "u") };
  });

  const exactOverrides = new Map();
  for (const [index, entry] of manifest.exactOverrides.entries()) {
    if (!entry || typeof entry.key !== "string" || entry.key.length === 0 ||
        typeof entry.resultValue !== "string") {
      throw new OverlayError("SCHEMA_VALUE", `exactOverrides[${index}] is incomplete`);
    }
    assertRepositoryPath(entry.path, `exactOverrides[${index}].path`);
    assertDigest(entry.sourceSha256, `exactOverrides[${index}].sourceSha256`);
    assertDigest(entry.resultSha256, `exactOverrides[${index}].resultSha256`);
    if (sha256(entry.resultValue) !== entry.resultSha256) {
      throw new OverlayError("EXACT_HASH", `${entry.path}:${entry.key} resultValue hash does not match`);
    }
    const pair = `${entry.path}\u0000${entry.key}`;
    if (exactOverrides.has(pair)) {
      throw new OverlayError("EXACT_DUPLICATE", `${entry.path}:${entry.key} has duplicate exact overrides`);
    }
    exactOverrides.set(pair, entry);
  }
  const files = new Map(Object.entries(coverage.files));

  for (const [filePath, fileCoverage] of files) {
    assertRepositoryPath(filePath, "coverage path");
    if (!fileCoverage || typeof fileCoverage !== "object" ||
        !fileCoverage.entries || typeof fileCoverage.entries !== "object" ||
        Array.isArray(fileCoverage.entries) || Object.keys(fileCoverage.entries).length === 0) {
      throw new OverlayError("SCHEMA_VALUE", `${filePath} has invalid or empty coverage entries`);
    }
    const matchingRules = rules.filter((rule) => rule.expression.test(filePath));
    if (matchingRules.length !== 1) {
      throw new OverlayError(
        "PATH_RULE",
        `${filePath} must match exactly one path rule, matched ${matchingRules.length}`,
        { path: filePath }
      );
    }
    const rule = matchingRules[0];
    if (rule.kind !== fileCoverage.kind) {
      throw new OverlayError("PATH_KIND", `${filePath} coverage kind does not match its rule`);
    }
    const allowed = new Set(rule.keys);
    for (const [key, entryCoverage] of Object.entries(fileCoverage.entries)) {
      if (key.length === 0 || !entryCoverage || typeof entryCoverage !== "object") {
        throw new OverlayError("SCHEMA_VALUE", `${filePath} contains invalid entry coverage`);
      }
      if (!allowed.has(key)) {
        throw new OverlayError("KEY_RULE", `${filePath}:${key} is not allowlisted by ${rule.id}`);
      }
      if (entryCoverage.mode !== "token" && entryCoverage.mode !== "exact") {
        throw new OverlayError("COVERAGE_MODE", `${filePath}:${key} has unknown mode '${entryCoverage.mode}'`);
      }
      assertDigest(entryCoverage.sourceSha256, `${filePath}:${key} sourceSha256`);
      assertDigest(entryCoverage.resultSha256, `${filePath}:${key} resultSha256`);
      const exact = exactOverrides.get(`${filePath}\u0000${key}`);
      if (entryCoverage.mode === "exact") {
        if (!exact || exact.sourceSha256 !== entryCoverage.sourceSha256 ||
            exact.resultSha256 !== entryCoverage.resultSha256) {
          throw new OverlayError("EXACT_COVERAGE", `${filePath}:${key} exact policy and coverage differ`);
        }
      } else if (exact) {
        throw new OverlayError("EXACT_COVERAGE", `${filePath}:${key} token coverage has an exact override`);
      }
    }
  }

  for (const [pair, exact] of exactOverrides) {
    const fileCoverage = files.get(exact.path);
    if (!fileCoverage?.entries?.[exact.key] || fileCoverage.entries[exact.key].mode !== "exact") {
      throw new OverlayError("EXACT_COVERAGE", `${pair.replace("\u0000", ":")} exact override is not covered`);
    }
  }

  if (manifest.generatedFrom && coverage.generatedFrom &&
      (manifest.generatedFrom.base !== coverage.generatedFrom.base ||
       manifest.generatedFrom.reviewed !== coverage.generatedFrom.reviewed)) {
    throw new OverlayError("GENERATED_FROM", "manifest and coverage were extracted from different revisions");
  }

  return { manifest, coverage, rules, exactOverrides, files };
}

function transformCoveredValue(context, path, key, sourceValue, entryCoverage) {
  const { manifest, exactOverrides } = context;
  const exact = exactOverrides.get(`${path}\u0000${key}`);
  let result;

  if (entryCoverage.mode === "exact") {
    if (!exact) throw new OverlayError("EXACT_OVERRIDE_MISSING", `${path}:${key} has no exact override`);
    const currentHash = sha256(sourceValue);
    if (currentHash === exact.resultSha256) return sourceValue;
    if (currentHash !== exact.sourceSha256) {
      throw new OverlayError(
        "EXACT_SOURCE_DRIFT",
        `${path}:${key} changed upstream; the reviewed exact override must be updated`,
        { path, key, expected: exact.sourceSha256, actual: currentHash }
      );
    }
    result = exact.resultValue;
  } else if (entryCoverage.mode === "token") {
    const transformed = applyBrandTokens(sourceValue, manifest);
    if (transformed.replacementCount === 0 && !sourceValue.includes(manifest.productName)) {
      throw new OverlayError(
        "UNRECOGNIZED_SOURCE_BRAND",
        `${path}:${key} has no known brand token`,
        { path, key, sourceHash: sha256(sourceValue) }
      );
    }
    result = transformed.value;
  } else {
    throw new OverlayError("COVERAGE_MODE", `${path}:${key} has unknown mode '${entryCoverage.mode}'`);
  }

  validateOutput(sourceValue, result, manifest, path, key);
  return result;
}

function stringsEntries(text, path) {
  const parsed = parseAppleStrings(text, { file: path });
  return indexAppleStrings(parsed, { file: path });
}

export function transformCoveredFile(context, path, sourceText) {
  const fileCoverage = context.files.get(path);
  if (!fileCoverage) throw new OverlayError("PATH_NOT_COVERED", `${path} is outside the localization overlay`);
  const replacements = new Map();

  if (fileCoverage.kind === "strings") {
    const indexed = stringsEntries(sourceText, path);
    for (const [key, entryCoverage] of Object.entries(fileCoverage.entries)) {
      const sourceEntry = indexed.get(key);
      if (!sourceEntry) throw new OverlayError("KEY_MISSING", `${path}:${key} is missing upstream`);
      replacements.set(
        key,
        transformCoveredValue(context, path, key, sourceEntry.valueRaw, entryCoverage)
      );
    }
    const result = replaceAppleStringValues(sourceText, replacements, { file: path });
    const allowedKeys = Object.keys(fileCoverage.entries);
    if (maskAppleStringValues(sourceText, allowedKeys, { file: path }) !==
        maskAppleStringValues(result, allowedKeys, { file: path })) {
      throw new OverlayError("NON_ALLOWLIST_CHANGE", `${path} changed outside allowlisted values`);
    }
    return { text: result, transformedEntries: replacements.size };
  }

  if (fileCoverage.kind === "intentdefinition") {
    const keys = Object.keys(fileCoverage.entries);
    if (keys.length !== 1) throw new OverlayError("INTENT_COVERAGE", `${path} must cover one intent key`);
    const key = keys[0];
    const sourceEntry = parseIntentDescription(sourceText, { file: path, id: key });
    const value = transformCoveredValue(
      context,
      path,
      key,
      sourceEntry.valueRaw,
      fileCoverage.entries[key]
    );
    const result = replaceIntentDescription(sourceText, value, { file: path, id: key });
    if (maskIntentDescription(sourceText, { file: path, id: key }) !==
        maskIntentDescription(result, { file: path, id: key })) {
      throw new OverlayError("NON_ALLOWLIST_CHANGE", `${path} changed outside the intent description`);
    }
    return { text: result, transformedEntries: 1 };
  }

  throw new OverlayError("FILE_KIND", `${path} has unsupported kind '${fileCoverage.kind}'`);
}
