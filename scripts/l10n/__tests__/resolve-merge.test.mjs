// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  symlinkSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { canonicalJSON, sha256 } from "../lib/overlay.mjs";

const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "floorp-l10n-overlay.mjs");
const l10nPath = "firefox-ios/Shared/en.lproj/Localizable.strings";
const manifestPath = "floorp/l10n/manifest.json";
const coveragePath = "floorp/l10n/coverage.json";
const baseL10n = '/* title */\n"Open" = "Open Firefox";\n"Untouched" = "Stable";\n';
const oursL10n = '/* title */\n"Open" = "Open Floorp";\n"Untouched" = "Stable";\n';
const theirsL10n = '/* upstream title */\n"Open" = "Launch Firefox now";\n"Untouched" = "Stable";\n';
const resolvedL10n = '/* upstream title */\n"Open" = "Launch Floorp now";\n"Untouched" = "Stable";\n';

function git(root, ...arguments_) {
  return execFileSync("git", arguments_, { cwd: root, encoding: "utf8" });
}

function write(root, filePath, contents) {
  const destination = path.join(root, filePath);
  mkdirSync(path.dirname(destination), { recursive: true });
  writeFileSync(destination, contents, "utf8");
}

function initializeRepository({ withOutsideConflict = false } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), "floorp-l10n-merge-"));
  execFileSync("git", ["init", "--quiet", root]);
  git(root, "config", "user.name", "Floorp L10n Test");
  git(root, "config", "user.email", "floorp-l10n@example.invalid");

  const manifest = {
    schemaVersion: 1,
    productName: "Floorp",
    protectedTerms: ["Firefox Sync"],
    forbiddenOutputTerms: ["Floorp Sync"],
    brandTokens: ["Firefox"],
    additionalBrandTokens: [],
    pathRules: [{
      id: "localizable",
      kind: "strings",
      pattern: "^firefox-ios/Shared/en\\.lproj/Localizable\\.strings$",
      keys: ["Open"]
    }],
    exactOverrides: []
  };
  const coverage = {
    schemaVersion: 1,
    files: {
      [l10nPath]: {
        kind: "strings",
        entries: {
          Open: {
            mode: "token",
            sourceSha256: sha256("Open Firefox"),
            resultSha256: sha256("Open Floorp")
          }
        }
      }
    }
  };
  write(root, manifestPath, canonicalJSON(manifest));
  write(root, coveragePath, canonicalJSON(coverage));
  write(root, l10nPath, baseL10n);
  if (withOutsideConflict) write(root, "outside.txt", "base\n");
  git(root, "add", ".");
  git(root, "commit", "--quiet", "-m", "base");
  const base = git(root, "rev-parse", "HEAD").trim();

  git(root, "checkout", "--quiet", "-b", "ours");
  write(root, l10nPath, oursL10n);
  if (withOutsideConflict) write(root, "outside.txt", "ours\n");
  git(root, "add", ".");
  git(root, "commit", "--quiet", "-m", "ours");

  git(root, "checkout", "--quiet", "-b", "theirs", base);
  write(root, l10nPath, theirsL10n);
  if (withOutsideConflict) write(root, "outside.txt", "theirs\n");
  git(root, "add", ".");
  git(root, "commit", "--quiet", "-m", "theirs");
  git(root, "checkout", "--quiet", "ours");
  const merge = spawnSync("git", ["merge", "--no-commit", "--no-ff", "theirs"], {
    cwd: root,
    encoding: "utf8"
  });
  assert.equal(merge.status, 1, `expected a merge conflict, got: ${merge.stdout}${merge.stderr}`);
  return root;
}

function runResolver(root) {
  return spawnSync(process.execPath, [
    cli,
    "resolve-merge",
    "--root", root,
    "--manifest", manifestPath,
    "--coverage", coveragePath,
    "--write",
    "--stage"
  ], { cwd: root, encoding: "utf8" });
}

test("resolve-merge reapplies the overlay to upstream and stages only a proven conflict", () => {
  const root = initializeRepository();
  const result = runResolver(root);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(path.join(root, l10nPath), "utf8"), resolvedL10n);
  assert.equal(git(root, "ls-files", "-u"), "");
  assert.match(git(root, "diff", "--cached", "--", l10nPath), /Launch Floorp now/u);
});

test("resolve-merge refuses an unexpected conflict without changing files or index", () => {
  const root = initializeRepository({ withOutsideConflict: true });
  const indexBefore = git(root, "ls-files", "-u", "-z");
  const l10nBefore = readFileSync(path.join(root, l10nPath), "utf8");
  const outsideBefore = readFileSync(path.join(root, "outside.txt"), "utf8");

  const result = runResolver(root);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /outside Floorp l10n coverage/u);
  assert.equal(git(root, "ls-files", "-u", "-z"), indexBefore);
  assert.equal(readFileSync(path.join(root, l10nPath), "utf8"), l10nBefore);
  assert.equal(readFileSync(path.join(root, "outside.txt"), "utf8"), outsideBefore);
});

test("apply preflights every covered value before writing any file", () => {
  const root = mkdtempSync(path.join(tmpdir(), "floorp-l10n-apply-"));
  const validPath = "fixtures/a.strings";
  const invalidPath = "fixtures/b.strings";
  const validSource = '"Open" = "Open Firefox";\n';
  const invalidSource = '"Open" = "Open Browser";\n';
  const manifest = {
    schemaVersion: 1,
    productName: "Floorp",
    protectedTerms: [],
    forbiddenOutputTerms: [],
    brandTokens: ["Firefox"],
    additionalBrandTokens: [],
    pathRules: [{
      id: "fixtures",
      kind: "strings",
      pattern: "^fixtures/[ab]\\.strings$",
      keys: ["Open"]
    }],
    exactOverrides: []
  };
  const entry = (source, result) => ({
    mode: "token",
    sourceSha256: sha256(source),
    resultSha256: sha256(result)
  });
  const coverage = {
    schemaVersion: 1,
    files: {
      [validPath]: {
        kind: "strings",
        entries: { Open: entry("Open Firefox", "Open Floorp") }
      },
      [invalidPath]: {
        kind: "strings",
        entries: { Open: entry("Open Browser", "Open Floorp") }
      }
    }
  };
  write(root, manifestPath, canonicalJSON(manifest));
  write(root, coveragePath, canonicalJSON(coverage));
  write(root, validPath, validSource);
  write(root, invalidPath, invalidSource);

  const result = spawnSync(process.execPath, [
    cli,
    "apply",
    "--root", root,
    "--manifest", manifestPath,
    "--coverage", coveragePath,
    "--write"
  ], { cwd: root, encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /UNRECOGNIZED_SOURCE_BRAND/u);
  assert.equal(readFileSync(path.join(root, validPath), "utf8"), validSource);
  assert.equal(readFileSync(path.join(root, invalidPath), "utf8"), invalidSource);
});

test("apply refuses to traverse a symlinked localization directory", () => {
  const root = mkdtempSync(path.join(tmpdir(), "floorp-l10n-symlink-root-"));
  const outside = mkdtempSync(path.join(tmpdir(), "floorp-l10n-symlink-outside-"));
  const filePath = "fixtures/a.strings";
  const source = '"Open" = "Open Firefox";\n';
  const manifest = {
    schemaVersion: 1,
    productName: "Floorp",
    protectedTerms: [],
    forbiddenOutputTerms: [],
    brandTokens: ["Firefox"],
    additionalBrandTokens: [],
    pathRules: [{
      id: "fixture",
      kind: "strings",
      pattern: "^fixtures/a\\.strings$",
      keys: ["Open"]
    }],
    exactOverrides: []
  };
  const coverage = {
    schemaVersion: 1,
    files: {
      [filePath]: {
        kind: "strings",
        entries: {
          Open: {
            mode: "token",
            sourceSha256: sha256("Open Firefox"),
            resultSha256: sha256("Open Floorp")
          }
        }
      }
    }
  };
  write(root, manifestPath, canonicalJSON(manifest));
  write(root, coveragePath, canonicalJSON(coverage));
  write(outside, "a.strings", source);
  symlinkSync(outside, path.join(root, "fixtures"), "dir");

  const result = spawnSync(process.execPath, [
    cli,
    "apply",
    "--root", root,
    "--manifest", manifestPath,
    "--coverage", coveragePath,
    "--write"
  ], { cwd: root, encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /traverses a symbolic link/u);
  assert.equal(readFileSync(path.join(outside, "a.strings"), "utf8"), source);
});
