# 8. Floorp Directory Consolidation Architecture

Date: 2026-04-21

## Status

Accepted; amended 2026-08-01 to make tracked source plus tests the only hook implementation,
and 2026-08-03 to define narrow host-layout hooks for Floorp UI.

## Context

As described in [ADR-0007](0007-upstream-merge-rebrand-strategy.md), Floorp for iOS is forked from Firefox for iOS. Initially, Floorp customizations were applied by directly editing Firefox source files (e.g., inserting early returns into telemetry methods, modifying initialization code). While functional, this approach has several problems:

1. **Merge conflict surface area** — Each direct edit to a Firefox file creates a conflict point during upstream merges. When Mozilla changes the same file, the merge may fail or produce incorrect results.

2. **Scattered changes** — Floorp modifications were spread across 4+ Firefox files with no clear organizational structure. Developers must search the entire codebase to understand what Floorp has changed.

3. **No clear ownership boundary** — Without a physical separation between Firefox code and Floorp code, it is difficult to distinguish upstream code from project-specific customizations.

4. **Fragile sed patterns** — The rebrand script relied on complex multi-line sed patterns to inject code into Firefox files. These patterns are brittle and break when upstream reformats code.

The Firefox iOS codebase provides several extensibility mechanisms that make direct editing unnecessary:

- **DI container** (`AppContainer` using Dip) — Services registered at bootstrap time
- **Static flag checks** — Boolean flags checked at method entry points
- **Coordinator pattern** — Route-based navigation with protocol conformance
- **WKUserScript** — Web content modification via script injection
- **Modular architecture** — BrowserKit SPM package with 20+ framework libraries

## Decision

We adopt a **consolidated Floorp directory** architecture with flag-based hooks.

### Directory Structure

All Floorp-specific application code resides in `firefox-ios/Floorp/`:

```
firefox-ios/Floorp/
├── FloorpFlags.swift         # Feature flags checked at hook points
└── FloorpBootstrapper.swift  # Single entry point called at startup
```

### Hook Mechanism

Instead of directly modifying Firefox method bodies, we use a two-part system:

1. **FloorpBootstrapper** — Called from `DependencyHelper.bootstrapDependencies()` with a single line:

   ```swift
   FloorpBootstrapper.configure()
   ```

   This sets all Floorp feature flags before any Firefox code runs.

2. **FloorpFlags** — Static boolean flags checked at Firefox hook points:
   ```swift
   if FloorpFlags.isTelemetryDisabled { return }
   ```

### Original Firefox Files Modified (Bootstrap and Privacy Hook Points)

The original bootstrap and privacy boundary uses four minimal Firefox-file
modifications:

| File                     | Hook                                   | Purpose                      |
| ------------------------ | -------------------------------------- | ---------------------------- |
| `DependencyHelper.swift` | `FloorpBootstrapper.configure()`       | Entry point                  |
| `TelemetryWrapper.swift` | `FloorpFlags.isTelemetryDisabled` (×2) | Glean telemetry              |
| `MetricKitWrapper.swift` | `FloorpFlags.isTelemetryDisabled`      | Apple MetricKit              |
| `SentryWrapper.swift`    | Direct `return`                        | Sentry (BrowserKit boundary) |

### Host UI Integration Hooks

Floorp-owned UI may require a small typed integration at a Firefox-owned view
or lifecycle boundary when dependency injection, notifications, or a standalone
child controller cannot express the required layout behavior. These hooks are
accepted only when all of the following remain true:

- Floorp behavior, state, and policy stay in `firefox-ios/Floorp/`.
- The Firefox-owned edit only exposes or consumes a narrow typed boundary.
- The unconfigured path preserves upstream layout and behavior, with a direct
  regression test where practical.
- The hook is tracked source code reviewed by CI; build-time patch mutation is
  not introduced.
- Frequently changed upstream files are avoided or their edited surface is kept
  as small as the UIKit integration allows.

The adaptive panel sidebar is the first approved use of this exception. It
injects Floorp-owned full-width and safe-area-intersection layout guides into
the browser layout manager and constrains the browser content/chrome to those
guides while a pinned iPad sidebar is visible. The layout manager falls back to
the original view-edge and safe-area anchors when no Floorp guides are supplied.

### BrowserKit Constraint

`SentryWrapper` resides in `BrowserKit/Sources/Common/`, which is a separate SPM package. It cannot import the `Floorp` module directly. For this case, we keep a direct `return` statement (acceptable since the DSN key is also absent from Info.plist, providing double protection).

### Rebrand Script Integration

`scripts/rebrand-to-floorp.sh` Step 7 is updated to:

1. Ensure `Floorp/` directory and files exist (idempotent creation)
2. Inject hook comments into the 4 Firefox files (only if not already present)
3. Use grep-based idempotency checks to prevent duplicate injection

The hook points are tracked directly and verified by CI. The former `floorp/patches/` copies and `scripts/apply-floorp-patches.sh` were never invoked by a build or workflow and duplicated the same edits, so they were removed. Build-time patch mutation is not an accepted second implementation path.

## Consequences

### Positive

- **Controlled merge conflicts** — Bootstrap/privacy edits remain minimal, and
  host UI edits are limited to typed layout or lifecycle boundaries with tested
  upstream-compatible fallbacks.
- **Clear ownership** — All Floorp code is in one directory. Easy to audit, review, and maintain.
- **Easy onboarding** — New developers can find all Floorp customizations in `Floorp/` without searching the codebase.
- **Extensible** — Adding new customizations only requires adding flags to `FloorpFlags` and methods to `FloorpBootstrapper`.
- **Idempotent** — Rebrand script can be run multiple times safely.

### Negative

- **Flag overhead** — Each hook point requires a corresponding flag in `FloorpFlags`. For large numbers of customizations, the flags file may grow.
- **Runtime cost** — Flag checks add a negligible branch at each hook point (a static boolean comparison).
- **BrowserKit exception** — `SentryWrapper` cannot use the flag pattern and must use a direct return, which is slightly less clean.
- **Build dependency** — The `Floorp/` directory must be included in the Xcode project target for the code to compile.

### Risks and Mitigations

| Risk                                               | Mitigation                                                    |
| -------------------------------------------------- | ------------------------------------------------------------- |
| Upstream renames/removes a hooked method           | Rebrand script grep checks will fail gracefully with warnings |
| Floorp/ directory accidentally excluded from build | Document in rebrand script; verify in CI                      |
| Flag name collision with upstream code             | Use `Floorp` prefix consistently                              |
