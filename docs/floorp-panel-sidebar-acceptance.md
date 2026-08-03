# Floorp Panel Sidebar release acceptance

This is the runtime evidence record for the functional contract in
[`floorp-panel-sidebar-parity.md`](floorp-panel-sidebar-parity.md). Copy this
checklist forward for each release candidate. Replace `PENDING` only with
observed values; do not reuse evidence from another source SHA or build.

Acceptance and distribution are separate statuses. An Internal TestFlight
candidate may be uploaded solely to collect evidence while acceptance remains
`PENDING`; upload, processing, assignment, or installation is not acceptance.
Until the final shipping decision is accepted, the only permitted distribution
status is **Internal evidence collection only**, assigned to **Floorp Internal**.
Do not add an external tester group, public link, Beta App Review, App Store
submission, or public release.

## Release candidate identity

Acceptance status: **PENDING**

Distribution status: **PENDING**

| Field | Recorded value |
| --- | --- |
| Candidate source SHA | `PENDING` |
| Pull request URL | `PENDING` |
| Source branch/tag | `PENDING` |
| Marketing version | `PENDING` |
| Build number | `PENDING` |
| Archive/upload timestamp (UTC) | `PENDING` |
| Internal TestFlight build URL or App Store Connect build ID | `PENDING` |
| Assigned internal tester group (must be `Floorp Internal`) | `PENDING` |
| Acceptance owner | `PENDING` |
| Acceptance date (UTC) | `PENDING` |

- [ ] The local checkout, CI runs, archive, and TestFlight binary all identify
      the same candidate source SHA.
- [ ] The build is available only to `Floorp Internal` for evidence collection.
- [ ] No external TestFlight, public link, Beta App Review, or App Store release
      was enabled by this checklist.

## CI evidence

| Required run | Workflow/run URL | Candidate source SHA shown by run | Result |
| --- | --- | --- | --- |
| Build and `FloorpCI` unit tests | `PENDING` | `PENDING` | `PENDING` |
| iPhone adaptive sidebar UI tests | `PENDING` | `PENDING` | `PENDING` |
| iPad adaptive sidebar UI tests | `PENDING` | `PENDING` | `PENDING` |
| Archive/export or deployment validation | `PENDING` | `PENDING` | `PENDING` |

- [ ] Every content-mode and unified reload-arbiter test named in the parity
      contract is selected by `FloorpCI` and passed on the candidate source
      SHA, including the exact `about:blank` lifecycle cases.
- [ ] Every media-pause test named in the parity contract is selected by
      `FloorpCI` and passed on the candidate source SHA.
- [ ] `FloorpAdaptiveUI.xctestplan` ran all four selected adaptive UI tests.
- [ ] Localization catalogs parsed and the English/Japanese Floorp strings used
      by panel actions were present.
- [ ] `git diff --check` passed on the candidate source diff.

## Device and OS matrix

Record simulator versus physical hardware explicitly. Add rows rather than
overwriting a result when more than one OS is tested.

| Role | Hardware or simulator | Exact device model | OS version/build | Window/orientation | Result | Evidence ID |
| --- | --- | --- | --- | --- | --- | --- |
| Compact iPhone, top address bar | `PENDING` | `PENDING` | `PENDING` | Portrait | `PENDING` | `PENDING` |
| Compact iPhone, bottom address bar | `PENDING` | `PENDING` | `PENDING` | Portrait | `PENDING` | `PENDING` |
| Regular iPad adaptive migration | `PENDING` | `PENDING` | `PENDING` | Portrait and landscape | `PENDING` | `PENDING` |
| Regular iPad RTL and resize | `PENDING` | `PENDING` | `PENDING` | Landscape RTL | `PENDING` | `PENDING` |
| iPad supported Split View width | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` |
| Multiwindow/private isolation | `PENDING` | `PENDING` | `PENDING` | Two windows | `PENDING` | `PENDING` |

## P0 runtime acceptance

### Registry and window ownership

- [ ] Add a Web panel with a non-default curated icon.
- [ ] Edit its title, URL, and icon; reorder it; relaunch; verify all persisted.
- [ ] Remove the Web panel with confirmation and restore a removed built-in
      without changing unrelated panels.
- [ ] Open two browser windows with different selected panels and current URLs.
      Hide/show and switch panels; verify each window preserves its own state.
- [ ] Repeat normal/private switching and confirm neither session, current URL,
      nor restoration snapshot crosses the privacy boundary.

Evidence IDs or notes: `PENDING`

### Web navigation, toolbar, and Find

Fixture origin and revision: `PENDING`

- [ ] Navigate through at least three fixture pages and verify Back, Forward,
      Reload/Stop, Home, Open in Main, and Close.
- [ ] Open in Main uses the exact current safe URL and the owning privacy mode.
- [ ] Find covers zero, one, and multiple matches, next/previous wrap, dynamic
      content, Cmd-F, Escape, keyboard avoidance, and teardown after switching
      or unloading.
- [ ] VoiceOver labels, state, focus movement, and announcements are usable.

Evidence IDs or notes: `PENDING`

### Profile, content blocking, and main-history isolation

Use a controlled local HTTPS fixture. Record its source revision and server
logs so the cookie/blocking assertions are reproducible.

| Assertion | Result | Evidence ID or log URL |
| --- | --- | --- |
| Cookie/login created in a normal tab is visible in a normal Web panel | `PENDING` | `PENDING` |
| Private and normal cookies remain isolated in both directions | `PENDING` | `PENDING` |
| Main tab and Web panel apply the same selected content-blocking policy | `PENDING` | `PENDING` |
| Block Images changes affect loaded normal/private panels and survive unload | `PENDING` | `PENDING` |
| Panel-only navigation adds no URL or count to main browsing history | `PENDING` | `PENDING` |
| HTTP(S) and exact `about:blank` work; unsupported schemes are rejected | `PENDING` | `PENDING` |
| Download, file picker, media permission, and HTTP auth use the documented main-open boundary | `PENDING` | `PENDING` |

P0-4 acceptance: **PENDING**

### Adaptive presentation

- [ ] iPhone overlay remains above the top address bar and cannot focus the
      covered address bar.
- [ ] iPhone overlay remains above the bottom address bar and cannot focus the
      covered address bar.
- [ ] iPad migrates portrait overlay to landscape pinned and back without
      losing selected panel or entered state.
- [ ] Pinned resize keeps browser content, header, and address bar outside the
      drawer in LTR and RTL.
- [ ] The supported Split View width follows the documented overlay/pinned
      resolver and remains dismissible.

Expected XCUITest attachment names (names alone are not pass evidence):

- `iphone-top-toolbar-overlay`
- `iphone-bottom-toolbar-overlay`
- `ipad-portrait-overlay`
- `ipad-landscape-pinned-resized`
- `ipad-portrait-overlay-restored`
- `ipad-rtl-pinned-resized`

Evidence IDs or notes: `PENDING`

### Lifecycle and built-ins

- [ ] Hide/show retains the active session and current page.
- [ ] Explicit unload releases the Web view and restores the last safe URL once
      only after exact panel reselection.
- [ ] Auto-unload releases a hidden session and restores the last safe URL once.
- [ ] A memory warning evicts inactive sessions, retains visible sessions, and
      never restores private state into normal browsing.
- [ ] Notes, Bookmarks, History, and Downloads each render on iPhone and iPad;
      empty/error states and opening an item are covered.
- [ ] Window close releases its session store. No process-restoration behavior
      beyond persisted registry/preferences is claimed.

Memory evidence or notes: `PENDING`

## P1 runtime acceptance

- [ ] Curated Web-panel icons render in selected/unselected and light/dark
      states and survive relaunch. No favicon network request is observed.
- [ ] Web-panel width persists across switch, window recreation, and relaunch;
      a built-in width resets after its browser window is destroyed.
- [ ] Zoom visibly changes the fixture, respects bounds, resets to 100%, and
      survives switch, unload, and relaunch without changing main-tab zoom.
- [ ] Desktop/mobile mode changes the fixture's reported effective mode and
      user agent, reloads once, coalesces rapid changes, and survives unload and
      relaunch.
- [ ] Content-mode, Block Images, and manual reload requests share one arbiter,
      coalesce without duplicate loads, retire the matching HTTP(S) or exact
      `about:blank` navigation, and retry nil/failure only after an explicit
      trigger.
- [ ] Long press and iPad pointer expose only applicable actions; destructive
      removal requires confirmation; equivalent VoiceOver actions work.
- [ ] Pause Panel Media stops all audio and video playback and Resume Panel
      Media continues it; the state survives hide/show in the same loaded
      session, stays isolated by window/privacy/session, and resets after
      unload. This is intentionally not recorded as audio-only mute parity.
- [ ] A stale menu or VoiceOver action cannot mutate a replacement session.

Evidence IDs or notes: `PENDING`

## Notes and accessibility acceptance

- [ ] Create, search, edit, reorder, delete, and relaunch a local note.
- [ ] Exercise H1-H3, bold, italic, underline, strike, ordered/unordered lists,
      alignment, undo/redo, and bounded image insertion.
- [ ] Verify Dynamic Type, VoiceOver, keyboard focus, and RTL for the drawer,
      registry, Web toolbar, Find, and Notes paths used above.
- [ ] Verify English and Japanese action titles and announcements.
- [ ] Confirm `FloorpNotesSyncReleaseGate.isNetworkSyncEnabled` is false for
      this build unless a separately reviewed release record supplies every
      exact desktop, fixture, migration, and linked transport value.
- [ ] Confirm the acceptance run generated no Notes network traffic while the
      gate is false.

Evidence IDs or notes: `PENDING`

## Screenshot and artifact inventory

Each evidence ID must resolve to a retained CI artifact, App Store Connect
artifact, or repository-controlled file. Local ephemeral paths are not enough.

| Evidence ID | Artifact name | URL or retained path | Device and OS | Related checks | Reviewer |
| --- | --- | --- | --- | --- | --- |
| `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` |

## Sign-off

| Role | Name | Decision | Date (UTC) | Notes |
| --- | --- | --- | --- | --- |
| Engineering | `PENDING` | `PENDING` | `PENDING` | `PENDING` |
| Runtime acceptance | `PENDING` | `PENDING` | `PENDING` | `PENDING` |
| Internal TestFlight owner | `PENDING` | `PENDING` | `PENDING` | `PENDING` |

Final shipping decision: **PENDING**

Do not change the final shipping decision to accepted while any required
checkbox, identity field, CI URL, device/OS record, screenshot, sign-off, or
P0-4 fixture assertion is pending. An Internal TestFlight evidence candidate
may exist while this decision and the acceptance status remain `PENDING`, but
its distribution must remain limited to `Floorp Internal` as described above.
