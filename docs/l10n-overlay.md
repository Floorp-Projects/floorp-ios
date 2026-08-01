# Floorp localization overlay

Floorp's localized product-name changes are generated from a narrow, reviewed overlay. The generator does not perform a repository-wide `Firefox` replacement and does not treat Mozilla service names as Floorp products.

## Reviewed source of truth

`floorp/l10n/manifest.json` is reproducibly extracted from:

- reviewed base: `e58637e772e4456efcf7dbf3826f172c7da721ba`
- reviewed result: `9e46feb476739c508bb6d23a8ec92508d72adae0` (preserved by tag `rebranding-reviewed-l10n-v3-2026-08-01`)

The extracted scope is 849 localization resources (848 Apple `.strings` files and one intent definition), containing 4,074 changed semantic values. The parser normalizes 57 source key spellings to 55 keys. Twenty-four localized brand spellings are inferred from the reviewed change, and 18 values that cannot be represented as a token substitution are kept as exact overrides. This includes the camera-permission fallback key in all 50 locales that currently provide it.

`floorp/l10n/coverage.json` records every covered path and key, its transformation mode, and source/result hashes. The reviewed result changes only semantic value spans; formatting remains identical to the reviewed upstream base.

The current reviewed base includes both the Arabic spelling `فايرفوكس` and the Polish inflection `Firefoksowi`, so extraction infers both as narrow brand tokens. A spelling introduced by a later upstream revision still fails closed until it is reviewed and explicitly added.

Protected terms include Firefox Sync, Firefox Suggest, Firefox Relay, Firefox Focus/Klar, Mozilla Account/Autopush, Mozilla, Pocket, Nimbus, and Remote Settings. Corresponding invented names such as `Floorp Sync` are rejected.

## Commands

Use the Node version declared by `.nvmrc` (currently Node 24):

```sh
node scripts/l10n/floorp-l10n-overlay.mjs extract \
  --base e58637e772e4456efcf7dbf3826f172c7da721ba \
  --reviewed 9e46feb476739c508bb6d23a8ec92508d72adae0 \
  --check-counts --check

node scripts/l10n/floorp-l10n-overlay.mjs apply \
  --source-ref upstream/main --write

node scripts/l10n/floorp-l10n-overlay.mjs verify \
  --source-ref upstream/main

node --test scripts/l10n/__tests__/*.test.mjs
```

`extract --check` proves that the canonical JSON still represents the reviewed Git diff. Extraction also reapplies the resulting policy in memory and verifies all 4,074 reviewed values and their hashes. `apply` first validates all inputs, then writes only covered value spans. `verify` fails if any tracked generated output is stale. Running `apply --write` twice must produce zero changes on the second run.

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
