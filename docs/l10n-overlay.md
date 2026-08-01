# Floorp localization overlay

Floorp's localized product-name changes are generated from a narrow, reviewed overlay. The generator does not perform a repository-wide `Firefox` replacement and does not treat Mozilla service names as Floorp products.

## Reviewed source of truth

`floorp/l10n/manifest.json` is reproducibly extracted from:

- reviewed base: `b1f6991d551fe072abd975fed9330b205a317802`
- reviewed result: `rebranding-reviewed-2026-08-01`

The extracted scope is 794 localization resources (793 Apple `.strings` files and one intent definition), containing 3,982 changed semantic values. The parser normalizes 56 source key spellings to 54 keys. Twenty-one localized brand spellings are inferred from the reviewed change, and 19 values that cannot be represented as a token substitution are kept as exact overrides.

`floorp/l10n/coverage.json` records every covered path and key, its transformation mode, and source/result hashes. One reviewed Italian file also removed a blank line; that nonsemantic edit is recorded but deliberately not generated.

Upstream added the Arabic spelling `فايرفوكس` after the reviewed base. It is separately allowlisted as an additional source token, so the current translation can be preserved without broadening matching rules.

Protected terms include Firefox Sync, Firefox Suggest, Firefox Relay, Firefox Focus/Klar, Mozilla Account/Autopush, Mozilla, Pocket, Nimbus, and Remote Settings. Corresponding invented names such as `Floorp Sync` are rejected.

## Commands

Use the Node version declared by `.nvmrc` (currently Node 24):

```sh
node scripts/l10n/floorp-l10n-overlay.mjs extract \
  --base b1f6991d551fe072abd975fed9330b205a317802 \
  --reviewed rebranding-reviewed-2026-08-01 \
  --check-counts --check

node scripts/l10n/floorp-l10n-overlay.mjs apply \
  --source-ref upstream/main --write

node scripts/l10n/floorp-l10n-overlay.mjs verify \
  --source-ref upstream/main

node --test scripts/l10n/__tests__/*.test.mjs
```

`extract --check` proves that the canonical JSON still represents the reviewed Git diff. Extraction also reapplies the resulting policy in memory and verifies all 3,982 reviewed values and their hashes. `apply` first validates all inputs, then writes only covered value spans. `verify` fails if any tracked generated output is stale. Running `apply --write` twice must produce zero changes on the second run.

Policy loading also rejects duplicate or inconsistent path rules, malformed digests, mismatched exact overrides, and non-canonical repository paths. Covered resources may not traverse a symbolic link. CI must run the pinned `extract --check --check-counts` command before any `apply --write`; tests or `verify` alone do not authorize a changed manifest.

Exact overrides fail with `EXACT_SOURCE_DRIFT` if upstream changes their source text. A newly translated or inflected product spelling also fails closed until it is explicitly reviewed and allowlisted.

## Merge conflict resolver

During an upstream merge, run the resolver only after Git has populated ordinary three-stage conflicts:

```sh
node scripts/l10n/floorp-l10n-overlay.mjs resolve-merge --write --stage
```

The resolver accepts a conflict only when all of these conditions hold:

- the path and key set are in `coverage.json`;
- stages 1, 2, and 3 are present as regular, non-executable files;
- the covered path is canonical, repository-relative, and has no symbolic-link ancestor;
- the `ours` blob is exactly the reviewed overlay applied to the merge base;
- the upstream (`theirs`) blob passes every token, protected-term, and exact-hash check.

It then applies the overlay to the complete upstream blob, preserving upstream formatting and unrelated translations. All conflicts are preflighted before any file is written. A conflict outside the overlay, a hand-edited `ours` blob, a rename/delete conflict, or source drift stops the command without staging anything. The command never commits or pushes.

Generated localization files remain tracked in Git so Xcode builds and translators see normal resources. CI should run extraction, tests, and `verify` to prevent the generated files from drifting from the policy or the selected upstream input.
