#!/usr/bin/env node
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import { execFileSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync
} from "node:fs";
import path from "node:path";
import {
  indexAppleStrings,
  maskAppleStringValues,
  parseAppleStrings
} from "./lib/apple-strings.mjs";
import {
  maskIntentDescription,
  parseIntentDescription
} from "./lib/intentdefinition.mjs";
import {
  OverlayError,
  applyBrandTokens,
  canonicalJSON,
  compileOverlay,
  sha256,
  transformCoveredFile
} from "./lib/overlay.mjs";

const DEFAULT_MANIFEST = "floorp/l10n/manifest.json";
const DEFAULT_COVERAGE = "floorp/l10n/coverage.json";
const EXPECTED_EXTRACTION = {
  paths: 844,
  stringsFiles: 843,
  intentFiles: 1,
  semanticValues: 4032,
  rawKeyForms: 57,
  normalizedKeys: 55,
  brandTokens: 23,
  exactOverrides: 18,
  nonSemanticFiles: 0
};

const PATH_RULE_TEMPLATES = [
  {
    id: "client-info-plist",
    kind: "strings",
    pattern: "^firefox-ios/Client/[A-Za-z0-9-]+\\.lproj/InfoPlist\\.strings$"
  },
  {
    id: "action-extension-info-plist",
    kind: "strings",
    pattern: "^firefox-ios/Extensions/ActionExtension/[A-Za-z0-9-]+\\.lproj/InfoPlist\\.strings$"
  },
  {
    id: "shared-camera",
    kind: "strings",
    pattern: "^firefox-ios/Shared/Supporting Files/[A-Za-z0-9-]+\\.lproj/Camera\\.strings$"
  },
  {
    id: "shared-default-browser",
    kind: "strings",
    pattern: "^firefox-ios/Shared/[A-Za-z0-9-]+\\.lproj/Default Browser\\.strings$"
  },
  {
    id: "shared-intro",
    kind: "strings",
    pattern: "^firefox-ios/Shared/[A-Za-z0-9-]+\\.lproj/Intro\\.strings$"
  },
  {
    id: "shared-localizable",
    kind: "strings",
    pattern: "^firefox-ios/Shared/[A-Za-z0-9-]+\\.lproj/Localizable\\.strings$"
  },
  {
    id: "shared-private-browsing",
    kind: "strings",
    pattern: "^firefox-ios/Shared/[A-Za-z0-9-]+\\.lproj/PrivateBrowsing\\.strings$"
  },
  {
    id: "shared-today",
    kind: "strings",
    pattern: "^firefox-ios/Shared/[A-Za-z0-9-]+\\.lproj/Today\\.strings$"
  },
  {
    id: "widget-localizable",
    kind: "strings",
    pattern: "^firefox-ios/WidgetKit/[A-Za-z0-9-]+\\.lproj/Localizable\\.strings$"
  },
  {
    id: "widget-intents-strings",
    kind: "strings",
    pattern: "^firefox-ios/WidgetKit/[A-Za-z0-9-]+\\.lproj/WidgetIntents\\.strings$"
  },
  {
    id: "widget-intents-definition",
    kind: "intentdefinition",
    pattern: "^firefox-ios/WidgetKit/Base\\.lproj/WidgetIntents\\.intentdefinition$"
  }
];

const PROTECTED_TERMS = [
  "Firefox Accounts",
  "Firefox Account",
  "Firefox Suggest",
  "Firefox Relay",
  "Firefox Focus",
  "Firefox Klar",
  "Firefox Sync",
  "Mozilla Autopush",
  "Mozilla Account",
  "Remote Settings",
  "Mozilla",
  "Pocket",
  "Nimbus"
];

const FORBIDDEN_OUTPUT_TERMS = [
  "Floorp Accounts",
  "Floorp Account",
  "Floorp Suggest",
  "Floorp Relay",
  "Floorp Focus",
  "Floorp Klar",
  "Floorp Sync"
];

// Tokens present in the current reviewed base are inferred during extraction.
// Keep this list for future upstream spellings that appear after that base.
const ADDITIONAL_BRAND_TOKENS = [];
const BOOLEAN_OPTIONS = new Set(["check", "check-counts", "help", "stage", "write"]);

function parseArguments(arguments_) {
  const options = { _: [] };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (!argument.startsWith("--")) {
      options._.push(argument);
      continue;
    }
    const equals = argument.indexOf("=");
    if (equals !== -1) {
      options[argument.slice(2, equals)] = argument.slice(equals + 1);
      continue;
    }
    const name = argument.slice(2);
    if (arguments_[index + 1] && !arguments_[index + 1].startsWith("--")) {
      options[name] = arguments_[index + 1];
      index += 1;
    } else if (BOOLEAN_OPTIONS.has(name)) {
      options[name] = true;
    } else {
      throw new Error(`--${name} requires a value`);
    }
  }
  return options;
}

function git(root, arguments_, { encoding = "utf8" } = {}) {
  return execFileSync("git", arguments_, {
    cwd: root,
    encoding,
    maxBuffer: 128 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"]
  });
}

function repositoryRoot(requestedRoot) {
  if (requestedRoot) return realpathSync(path.resolve(requestedRoot));
  return realpathSync(git(process.cwd(), ["rev-parse", "--show-toplevel"]).trim());
}

function gitBlob(root, reference, filePath) {
  return git(root, ["show", `${reference}:${filePath}`]);
}

function coveredPath(root, filePath) {
  const destination = path.resolve(root, filePath);
  const relative = path.relative(root, destination);
  if (relative.length === 0 || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new OverlayError("UNSAFE_PATH", `${filePath} escapes the repository root`);
  }

  let current = root;
  for (const component of relative.split(path.sep)) {
    current = path.join(current, component);
    const metadata = lstatSync(current, { throwIfNoEntry: false });
    if (!metadata) break;
    if (metadata.isSymbolicLink()) {
      throw new OverlayError("UNSAFE_PATH", `${filePath} traverses a symbolic link`);
    }
  }
  return destination;
}

function atomicWrite(filePath, content, mode) {
  mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = path.join(
    path.dirname(filePath),
    `.${path.basename(filePath)}.floorp-l10n-${process.pid}`
  );
  try {
    writeFileSync(temporary, content, { encoding: "utf8", mode });
    renameSync(temporary, filePath);
  } finally {
    if (existsSync(temporary)) unlinkSync(temporary);
  }
}

function readJSON(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function sortedObject(entries) {
  return Object.fromEntries([...entries].sort(([left], [right]) => left.localeCompare(right, "en")));
}

function matchingTemplate(filePath, kind) {
  const matches = PATH_RULE_TEMPLATES.filter(
    (rule) => rule.kind === kind && new RegExp(rule.pattern, "u").test(filePath)
  );
  if (matches.length !== 1) throw new Error(`${filePath}: expected one path rule, found ${matches.length}`);
  return matches[0];
}

function changedPaths(root, base, reviewed) {
  const output = git(
    root,
    ["diff", "--name-only", "-z", `${base}..${reviewed}`, "--", ":(glob)**/*.lproj/**"],
    { encoding: "buffer" }
  );
  return output.toString("utf8").split("\0").filter(Boolean).sort();
}

function inferToken(sourceValue, reviewedValue) {
  if (reviewedValue.split("Floorp").length - 1 !== 1) return undefined;
  const [prefix, suffix] = reviewedValue.split("Floorp", 2);
  if (!sourceValue.startsWith(prefix) || !sourceValue.endsWith(suffix)) return undefined;
  const end = sourceValue.length - suffix.length;
  const token = sourceValue.slice(prefix.length, end);
  return token.length > 0 ? token : undefined;
}

function replaceTokens(value, tokens) {
  let result = value;
  for (const token of tokens) result = result.split(token).join("Floorp");
  return result;
}

function extractOverlay(root, base, reviewed, checkCounts) {
  const paths = changedPaths(root, base, reviewed);
  const records = [];
  const reviewedFiles = new Map();
  const rawKeyForms = new Set();
  const normalizedKeys = new Set();
  const nonSemanticDifferences = [];
  const ruleKeys = new Map(PATH_RULE_TEMPLATES.map((rule) => [rule.id, new Set()]));
  let stringsFiles = 0;
  let intentFiles = 0;

  for (const filePath of paths) {
    const source = gitBlob(root, base, filePath);
    const result = gitBlob(root, reviewed, filePath);
    reviewedFiles.set(filePath, { source, result });
    if (filePath.endsWith(".strings")) {
      stringsFiles += 1;
      const sourceEntries = indexAppleStrings(parseAppleStrings(source, { file: `${base}:${filePath}` }), {
        file: `${base}:${filePath}`
      });
      const resultEntries = indexAppleStrings(parseAppleStrings(result, { file: `${reviewed}:${filePath}` }), {
        file: `${reviewed}:${filePath}`
      });
      if (sourceEntries.size !== resultEntries.size ||
          [...sourceEntries.keys()].some((key) => !resultEntries.has(key))) {
        throw new Error(`${filePath}: reviewed rebrand added or removed localization keys`);
      }
      const changedKeys = [];
      for (const [key, resultEntry] of resultEntries) {
        const sourceEntry = sourceEntries.get(key);
        if (sourceEntry.valueRaw === resultEntry.valueRaw) continue;
        changedKeys.push(key);
        rawKeyForms.add(sourceEntry.keyToken);
        normalizedKeys.add(key);
        const rule = matchingTemplate(filePath, "strings");
        ruleKeys.get(rule.id).add(key);
        records.push({
          path: filePath,
          kind: "strings",
          key,
          sourceValue: sourceEntry.valueRaw,
          resultValue: resultEntry.valueRaw
        });
      }
      if (maskAppleStringValues(source, changedKeys, { file: `${base}:${filePath}` }) !==
          maskAppleStringValues(result, changedKeys, { file: `${reviewed}:${filePath}` })) {
        nonSemanticDifferences.push(filePath);
      }
      continue;
    }

    if (filePath.endsWith(".intentdefinition")) {
      intentFiles += 1;
      const sourceEntry = parseIntentDescription(source, { file: `${base}:${filePath}` });
      const resultEntry = parseIntentDescription(result, { file: `${reviewed}:${filePath}` });
      if (sourceEntry.valueRaw === resultEntry.valueRaw) {
        throw new Error(`${filePath}: diff does not change the reviewed intent description`);
      }
      normalizedKeys.add(sourceEntry.key);
      const rule = matchingTemplate(filePath, "intentdefinition");
      ruleKeys.get(rule.id).add(sourceEntry.key);
      records.push({
        path: filePath,
        kind: "intentdefinition",
        key: sourceEntry.key,
        sourceValue: sourceEntry.valueRaw,
        resultValue: resultEntry.valueRaw
      });
      if (maskIntentDescription(source, { file: `${base}:${filePath}` }) !==
          maskIntentDescription(result, { file: `${reviewed}:${filePath}` })) {
        nonSemanticDifferences.push(filePath);
      }
      continue;
    }
    throw new Error(`${filePath}: unsupported localization resource`);
  }

  const inferred = new Set(records.map((entry) => inferToken(entry.sourceValue, entry.resultValue)).filter(Boolean));
  const tokens = [...inferred].sort((left, right) => right.length - left.length || left.localeCompare(right, "en"));
  const exactRecords = records.filter(
    (entry) => replaceTokens(entry.sourceValue, tokens) !== entry.resultValue
  );
  const exactKeys = new Set(exactRecords.map((entry) => `${entry.path}\u0000${entry.key}`));

  const manifest = {
    schemaVersion: 1,
    productName: "Floorp",
    generatedFrom: { base, reviewed },
    summary: {
      paths: paths.length,
      stringsFiles,
      intentFiles,
      semanticValues: records.length,
      rawKeyForms: rawKeyForms.size,
      normalizedKeys: normalizedKeys.size,
      brandTokens: tokens.length,
      exactOverrides: exactRecords.length
    },
    protectedTerms: PROTECTED_TERMS,
    forbiddenOutputTerms: FORBIDDEN_OUTPUT_TERMS,
    brandTokens: tokens,
    additionalBrandTokens: ADDITIONAL_BRAND_TOKENS,
    pathRules: PATH_RULE_TEMPLATES.map((rule) => ({
      ...rule,
      keys: [...ruleKeys.get(rule.id)].sort((left, right) => left.localeCompare(right, "en"))
    })),
    exactOverrides: exactRecords.map((entry) => ({
      path: entry.path,
      key: entry.key,
      sourceSha256: sha256(entry.sourceValue),
      resultSha256: sha256(entry.resultValue),
      resultValue: entry.resultValue
    })).sort((left, right) =>
      left.path.localeCompare(right.path, "en") || left.key.localeCompare(right.key, "en"))
  };

  const fileMap = new Map();
  for (const entry of records) {
    if (!fileMap.has(entry.path)) fileMap.set(entry.path, { kind: entry.kind, entries: new Map() });
    fileMap.get(entry.path).entries.set(entry.key, {
      mode: exactKeys.has(`${entry.path}\u0000${entry.key}`) ? "exact" : "token",
      sourceSha256: sha256(entry.sourceValue),
      resultSha256: sha256(entry.resultValue)
    });
  }
  const coverageFiles = new Map();
  for (const [filePath, value] of fileMap) {
    coverageFiles.set(filePath, {
      kind: value.kind,
      entries: sortedObject(value.entries)
    });
  }
  const coverage = {
    schemaVersion: 1,
    generatedFrom: { base, reviewed },
    summary: {
      paths: paths.length,
      semanticValues: records.length,
      nonSemanticDifferences: nonSemanticDifferences.length
    },
    nonSemanticDifferencePaths: nonSemanticDifferences.sort(),
    files: sortedObject(coverageFiles)
  };

  // Re-apply the extracted overlay to the reviewed base before accepting it.
  // This proves both that every one of the reviewed semantic values is
  // reproduced and that the generated form excludes incidental formatting
  // edits such as the known Italian blank-line deletion.
  const context = compileOverlay(manifest, coverage);
  for (const [filePath, fileCoverage] of context.files) {
    const { source, result } = reviewedFiles.get(filePath);
    const generated = transformCoveredFile(context, filePath, source).text;
    let sourceEntries;
    let generatedEntries;
    let reviewedEntries;
    if (fileCoverage.kind === "strings") {
      sourceEntries = indexAppleStrings(parseAppleStrings(source, { file: `${base}:${filePath}` }), {
        file: `${base}:${filePath}`
      });
      generatedEntries = indexAppleStrings(parseAppleStrings(generated, { file: `generated:${filePath}` }), {
        file: `generated:${filePath}`
      });
      reviewedEntries = indexAppleStrings(parseAppleStrings(result, { file: `${reviewed}:${filePath}` }), {
        file: `${reviewed}:${filePath}`
      });
    }

    for (const [key, entryCoverage] of Object.entries(fileCoverage.entries)) {
      const sourceValue = fileCoverage.kind === "strings"
        ? sourceEntries.get(key)?.valueRaw
        : parseIntentDescription(source, { file: `${base}:${filePath}`, id: key }).valueRaw;
      const generatedValue = fileCoverage.kind === "strings"
        ? generatedEntries.get(key)?.valueRaw
        : parseIntentDescription(generated, { file: `generated:${filePath}`, id: key }).valueRaw;
      const reviewedValue = fileCoverage.kind === "strings"
        ? reviewedEntries.get(key)?.valueRaw
        : parseIntentDescription(result, { file: `${reviewed}:${filePath}`, id: key }).valueRaw;
      if (sha256(sourceValue) !== entryCoverage.sourceSha256) {
        throw new Error(`${filePath}:${key}: extracted source hash does not match the reviewed base`);
      }
      if (generatedValue !== reviewedValue || sha256(generatedValue) !== entryCoverage.resultSha256) {
        throw new Error(`${filePath}:${key}: extracted overlay does not reproduce the reviewed value`);
      }
    }
  }

  if (checkCounts) {
    const actual = {
      paths: paths.length,
      stringsFiles,
      intentFiles,
      semanticValues: records.length,
      rawKeyForms: rawKeyForms.size,
      normalizedKeys: normalizedKeys.size,
      brandTokens: tokens.length,
      exactOverrides: exactRecords.length,
      nonSemanticFiles: nonSemanticDifferences.length
    };
    for (const [name, expected] of Object.entries(EXPECTED_EXTRACTION)) {
      if (actual[name] !== expected) {
        throw new Error(`reviewed extraction ${name}: expected ${expected}, found ${actual[name]}`);
      }
    }
  }
  return { manifest, coverage };
}

function loadOverlay(root, options) {
  const manifestPath = path.resolve(root, options.manifest ?? DEFAULT_MANIFEST);
  const coveragePath = path.resolve(root, options.coverage ?? DEFAULT_COVERAGE);
  return {
    manifestPath,
    coveragePath,
    context: compileOverlay(readJSON(manifestPath), readJSON(coveragePath))
  };
}

function sourceText(root, sourceReference, filePath) {
  return sourceReference
    ? gitBlob(root, sourceReference, filePath)
    : readFileSync(coveredPath(root, filePath), "utf8");
}

function applyOverlay(root, options, verifyOnly) {
  const { context } = loadOverlay(root, options);
  const sourceReference = options["source-ref"];
  let changedFiles = 0;
  let transformedEntries = 0;
  const mismatches = [];
  const plans = [];
  const errors = [];

  for (const filePath of [...context.files.keys()].sort()) {
    const source = sourceText(root, sourceReference, filePath);
    let transformed;
    try {
      transformed = transformCoveredFile(context, filePath, source);
    } catch (error) {
      errors.push(error);
      continue;
    }
    transformedEntries += transformed.transformedEntries;
    const destination = coveredPath(root, filePath);
    const current = existsSync(destination) ? readFileSync(destination, "utf8") : undefined;
    if (current === transformed.text) continue;
    changedFiles += 1;
    if (verifyOnly) {
      mismatches.push(filePath);
    } else if (options.write) {
      const mode = existsSync(destination) ? statSync(destination).mode & 0o777 : 0o644;
      plans.push({ destination, text: transformed.text, mode });
    }
  }

  if (errors.length > 0) {
    const messages = errors.map((error) => error.message ?? String(error));
    throw new Error(`localization overlay rejected ${errors.length} source value(s):\n${messages.join("\n")}`);
  }

  if (verifyOnly && mismatches.length > 0) {
    throw new Error(`localization overlay is stale in ${mismatches.length} file(s):\n${mismatches.join("\n")}`);
  }
  for (const plan of plans) atomicWrite(plan.destination, plan.text, plan.mode);
  return { files: context.files.size, changedFiles, transformedEntries, sourceReference: sourceReference ?? "worktree" };
}

function unmergedEntries(root) {
  const output = git(root, ["ls-files", "-u", "-z"], { encoding: "buffer" }).toString("utf8");
  const grouped = new Map();
  for (const record of output.split("\0").filter(Boolean)) {
    const match = /^(\d+) ([0-9a-f]+) ([123])\t([\s\S]+)$/u.exec(record);
    if (!match) throw new Error(`cannot parse unmerged index record: ${record}`);
    const [, mode, object, stage, filePath] = match;
    if (!grouped.has(filePath)) grouped.set(filePath, new Map());
    grouped.get(filePath).set(Number(stage), { mode, object });
  }
  return grouped;
}

function resolveMerge(root, options) {
  const { context } = loadOverlay(root, options);
  const conflicts = unmergedEntries(root);
  const plans = [];

  for (const [filePath, stages] of conflicts) {
    if (!context.files.has(filePath)) {
      throw new Error(`unexpected merge conflict outside Floorp l10n coverage: ${filePath}`);
    }
    if (stages.size !== 3 || ![1, 2, 3].every((stage) => stages.has(stage))) {
      throw new Error(`${filePath}: only ordinary UU conflicts can be auto-resolved`);
    }
    for (const { mode } of stages.values()) {
      if (mode !== "100644") throw new Error(`${filePath}: symlink, executable, or non-regular conflict rejected`);
    }

    const base = git(root, ["cat-file", "blob", stages.get(1).object]);
    const ours = git(root, ["cat-file", "blob", stages.get(2).object]);
    const theirs = git(root, ["cat-file", "blob", stages.get(3).object]);
    const expectedOurs = transformCoveredFile(context, filePath, base).text;
    if (ours !== expectedOurs) {
      throw new Error(`${filePath}: ours contains changes not generated by the reviewed overlay`);
    }
    const result = transformCoveredFile(context, filePath, theirs).text;
    plans.push({ filePath, result });
  }

  if (options.write) {
    for (const plan of plans) atomicWrite(coveredPath(root, plan.filePath), plan.result, 0o644);
    if (options.stage) {
      for (const plan of plans) git(root, ["add", "--", plan.filePath]);
    }
  }
  return { conflicts: conflicts.size, resolved: plans.length, wrote: Boolean(options.write), staged: Boolean(options.stage) };
}

function writeOrCheck(filePath, value, options) {
  const content = canonicalJSON(value);
  if (options.check) {
    if (!existsSync(filePath) || readFileSync(filePath, "utf8") !== content) {
      throw new Error(`${filePath} is not the canonical reviewed extraction`);
    }
  }
  if (options.write) atomicWrite(filePath, content, 0o644);
}

function help() {
  return `Floorp localization overlay\n\n` +
    `  extract --base REF --reviewed REF [--write|--check] [--check-counts]\n` +
    `  apply [--source-ref REF] [--write]\n` +
    `  verify [--source-ref REF]\n` +
    `  resolve-merge [--write] [--stage]\n\n` +
    `All commands accept --root, --manifest, and --coverage.\n`;
}

function main() {
  const [command, ...arguments_] = process.argv.slice(2);
  const options = parseArguments(arguments_);
  if (!command || command === "help" || options.help) {
    process.stdout.write(help());
    return;
  }
  const root = repositoryRoot(options.root);
  let result;

  if (command === "extract") {
    if (!options.base || !options.reviewed) throw new Error("extract requires --base and --reviewed");
    if (!options.write && !options.check) throw new Error("extract requires --write or --check");
    const extracted = extractOverlay(root, options.base, options.reviewed, Boolean(options["check-counts"]));
    const manifestPath = path.resolve(root, options.manifest ?? DEFAULT_MANIFEST);
    const coveragePath = path.resolve(root, options.coverage ?? DEFAULT_COVERAGE);
    writeOrCheck(manifestPath, extracted.manifest, options);
    writeOrCheck(coveragePath, extracted.coverage, options);
    result = extracted.manifest.summary;
  } else if (command === "apply") {
    result = applyOverlay(root, options, false);
  } else if (command === "verify") {
    result = applyOverlay(root, options, true);
  } else if (command === "resolve-merge") {
    if (options.stage && !options.write) throw new Error("--stage requires --write");
    result = resolveMerge(root, options);
  } else {
    throw new Error(`unknown command '${command}'`);
  }

  process.stdout.write(`${canonicalJSON(result)}`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exitCode = 1;
}
