#!/usr/bin/env python3

"""Fail closed when Floorp's bundled WKWebExtension assets drift."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile


DEFAULT_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]

EXPECTED = (
    {
        "display_name": "Dark Reader",
        "archive": "darkreader-floorp-ios-mv3-4.9.129.zip",
        "license_file": "darkreader-floorp-ios-mv3-4.9.129.LICENSE",
        "license_marker": "MIT License",
        "review_license_marker": "MIT",
        "provenance_file": "darkreader-floorp-ios-mv3-4.9.129.provenance.json",
        "support_files": {
            "firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.patch": "0be2a2d45b51e2d4b2bc24ae139dddfb71c5386f6a5466702c0412d7376a9e07",
            "scripts/package-darkreader-ios.sh": "059760bc09a4668c2edf835cfe34f0d548961341be5457adb8eaa4f114f81eac",
        },
        "provenance": {
            "asset": "darkreader-floorp-ios-mv3-4.9.129.zip",
            "buildScript": "scripts/package-darkreader-ios.sh",
            "changes": [
                {
                    "description": "Use the iOS-compatible nonpersistent background-page form, load the Floorp compatibility primitives before Dark Reader, and expose a same-extension readiness document for native lifecycle probes.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "manifest.json",
                },
                {
                    "description": "Add bounded retries limited to transient WebKit unknown errors, a local-storage sentinel, per-area recovering serialization, flushable debounce and mutation queues, and deterministic deep comparison for persisted readback.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "background/floorp-compat.js",
                },
                {
                    "description": "Route Dark Reader storage through the compatibility layer; reject failed reads and writes instead of substituting defaults; keep UI mutation responses alive through durable storage; recover queue tails after failure; and report readiness only after startup, flush, and settings readback all succeed.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "background/index.js",
                },
                {
                    "description": "Send popup and options mutations with an explicit response callback, retain failures without unhandled rejections, remove the popup's independent storage read, expose a native close-preparation handshake, track pending tab and window routes through that handshake, await API acknowledgement before explicitly closing a route-opening popup, and disable shortcut configuration links that iOS cannot represent.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "ui/popup/index.js",
                },
                {
                    "description": "Keep options-page mutation messages alive through their durable background response, expose the same native close-preparation handshake, disable shortcut configuration links, and omit the empty Hotkeys tab on iOS.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "ui/options/index.js",
                },
                {
                    "description": "Hide popup shortcut wrappers and descriptions so unsupported shortcut controls leave no dead UI on iOS.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "ui/popup/style.css",
                },
                {
                    "description": "Keep developer-tools mutation messages alive through their durable background response and expose the same native close-preparation handshake.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "ui/devtools/index.js",
                },
                {
                    "description": "Keep stylesheet-editor mutation messages alive through their durable background response and expose the same native close-preparation handshake.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "ui/stylesheet-editor/index.js",
                },
                {
                    "description": "Provide a side-effect-free same-extension page from which Floorp can request background readiness after process eviction or before closing a surface.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "floorp-readiness.html",
                },
            ],
            "license": "MIT",
            "release": "v4.9.129",
            "sha256": "92f40f485205f61233185d1fb7cfb84b1dec243ebefc181d5f53943adc3c97c6",
            "sourceCommit": "c2a707302a39b8047543712e9c582bac07835d34",
            "upstreamAsset": "darkreader-chrome-mv3.zip",
            "upstreamDownloadURL": "https://github.com/darkreader/darkreader/releases/download/v4.9.129/darkreader-chrome-mv3.zip",
            "upstreamSHA256": "20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64",
        },
        "manifest": {
            "background": {
                "persistent": False,
                "scripts": ["background/floorp-compat.js", "background/index.js"],
            },
            "manifest_version": 3,
            "name": "Dark Reader",
            "version": "4.9.129",
        },
        "static_action_popup_path": "ui/popup/index.html",
        "archive_text_requirements": {
            "ui/popup/index.js": (
                "const pendingExtensionPageRoutes = new Set();",
                "function trackExtensionPageRoute(operation)",
                "async function prepareExtensionPageRoutesToClose()",
                "async function preparePopupToClose(connector)",
                "const route = trackExtensionPageRoute(async () => {",
                "await chrome.tabs.update(",
                "await chrome.tabs.create(",
                "await chrome.windows.update(",
                "await chrome.windows.create(",
                "await route;",
                "globalThis.floorpOpenExtensionPage = openExtensionPage;",
                "preparePopupToClose(connector);",
                "function ShortcutLink() {\n        return null;",
            ),
            "ui/options/index.js": (
                "function ShortcutLink() {\n        return null;",
            ),
            "ui/popup/style.css": (
                ".header__more-settings__shortcut-wrapper,\n"
                ".header__more-settings__shortcut-wrapper + "
                ".header__more-settings__description,\n"
                ".site-list-settings__shortcut {\n"
                "    display: none !important;\n"
                "}",
            ),
        },
        "archive_text_forbidden_requirements": {
            "ui/popup/index.js": (
                "chrome://extensions/configureCommands",
                "edge://extensions/shortcuts",
            ),
            "ui/options/index.js": (
                "chrome://extensions/configureCommands",
                "edge://extensions/shortcuts",
                'id: "hotkeys"',
            ),
        },
        "archive_text_order_requirement_groups": {
            "ui/popup/index.js": (
                (
                    "const route = trackExtensionPageRoute(async () => {",
                    "await route;",
                    "window.close();",
                ),
                (
                    "connector.prepareToClose(),",
                    "                prepareExtensionPageRoutesToClose()\n"
                    "            ]);",
                ),
            ),
        },
        "review_required_values": {
            "Floorp-derived",
            "background.service_worker",
            "background.scripts",
            "unsupported shortcut UI",
        },
    },
    {
        "display_name": "uBlock Origin Lite",
        "archive": "uBOLite-floorp-ios-2026.825.1619.zip",
        "license_file": "uBOLite-floorp-ios-2026.825.1619.LICENSE",
        "license_marker": "GNU GENERAL PUBLIC LICENSE",
        "review_license_marker": "GNU GPL v3.0 or later",
        "provenance_file": "uBOLite-floorp-ios-2026.825.1619.provenance.json",
        "support_files": {
            "firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.patch": "ea4367b6a41087b921d8ef1bb8ae5b6f430dd2f27cd060eeb65ab434731eddfc",
            "scripts/package-ubol-ios.sh": "f60cc1bca59e9894c24fa28345169ebfe9b5794a3bfde7aba0ea4e170dfc26b0",
        },
        "provenance": {
            "asset": "uBOLite-floorp-ios-2026.825.1619.zip",
            "buildScript": "scripts/package-ubol-ios.sh",
            "changes": [
                {
                    "description": "Declare WebKit's public declarativeNetRequestFeedback permission so uBO Lite's upstream Developer mode can expose its Matched rules diagnostics, and set the derived package's strict Safari minimum to 26.0 where DNR allow-priority ordering is corrected.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "path": "manifest.json",
                },
                {
                    "description": "Propagate the active tab's numeric logical window ID and incognito state when opening Matched rules and Report; adapt upstream Matched rules windows.create to an awaited active tabs.create in the source window; scope Report lookup, reuse, and creation to the same window and privacy realm; verify the created realm; return explicit opened/error responses; track every Matched rules, Report, and Options route through native close preparation; and close the Page Action only after the route acknowledgement so WebKit does not strand popup message ports.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": ["js/background.js", "js/ext-utils.js", "js/popup.js"],
                },
                {
                    "description": "Serialize Safari local/session storage with bounded retries limited to WebKit unknown errors; retain hidden, collision-protected dynamic/session DNR keeper rules and reserve their two slots from WebKit's combined quota, while capping each public store at floor(native limit / 2) - 1 so Safari 26's current-plus-final target-store quota check accepts every normal replacement/removal; keep legacy at-capacity rules readable and static-operable while deferring a missing keeper only after exact combined and target-store quota readback, preflight doomed updates before native mutation, permit only explicit non-empty sufficiently large reductions, and fold a target keeper into a capacity-opening update without silently removing protection rules; preserve native Promise pass-through outside Safari; hide keepers from facade reads and match feedback; serialize native DNR operations across realms when Web Locks are available and converge simultaneous first-use without them; make local configuration authoritative with revisioned exact readback; normalize native submission and desired/readback through one clone-only Safari 26 rule normalizer; preserve exact-fingerprinted official regex/request-domain rules and fail closed on unproven or WebKit-ignored conditions; recover poisoned queues; order realm markers around verified native DNR mutations; and reject missing, malformed, or runtime-error DNR readbacks instead of treating them as empty success.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": [
                        "js/alarms.js",
                        "js/config.js",
                        "js/ext-compat.js",
                        "js/ext.js",
                        "js/ruleset-manager.js",
                        "js/safari-dnr-normalizer.js",
                        "js/safari-regex-normalizer.js",
                    ],
                },
                {
                    "description": "Make startup, wake, permission, filtering-mode, static/derived/user DNR, imported-list, content-script, and user-script reconciliation durable and fail closed: use an immutable registered-content sentinel, case-normalize WebKit registration readback, and apply bounded ID-diff convergence; validate resources before mutation; use atomic or rollback-verified DNR updates; reconcile all protection surfaces from durable state before ready; and request a visible extension-page foreground reconciliation when WebKit rejects static ruleset updates from an MV3 background page.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": [
                        "js/admin.js",
                        "js/background.js",
                        "js/compiled-filters.js",
                        "js/fetch.js",
                        "js/floorp-reconcile.js",
                        "js/imported-lists.js",
                        "js/mode-manager.js",
                        "js/ruleset-manager.js",
                        "js/safari-registration-sentinel.js",
                        "js/scripting-manager.js",
                    ],
                },
                {
                    "description": "Protect settings restore/reset and live user-DNR/custom-filter edits with snapshots, durable recovery journals, strict commit/rollback responses, foreground-completed Safari static-ruleset rollback/readback, restored badge/alarm side effects, authoritative state rebroadcast across concurrent dashboards, and retryable queues; preserve incomplete parser drafts but reject effective Safari-incompatible live or imported user DNR before native mutation without removing installed rules, and keep Safari static-ruleset transitions after dynamic-rule validation; track delayed FileReader, editor, filter-list, and dashboard writes to a fixed point so a failed or interrupted operation cannot be reported as saved.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": [
                        "js/background.js",
                        "js/backup-restore.js",
                        "js/compiled-filters.js",
                        "js/develop.js",
                        "js/dnr-parser.js",
                        "js/filter-lists.js",
                        "js/filter-manager-ui.js",
                        "js/filter-manager.js",
                        "js/imported-lists.js",
                        "js/rw-dnr-editor.js",
                        "js/settings.js",
                    ],
                },
                {
                    "description": "Scope the CSS API's inserted-state and page-reveal handler plus isolated hostname contexts to the current document; serialize cleanup of replaced list/custom procedural filterers before later-document injection; and guard per-execution asynchronous cosmetic work so Safari isolated-world and document-wrapper reuse cannot leak prior-host CSS or skip custom/procedural reinjection after normal, cross-host, or private navigation.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": [
                        "js/scripting/css-api.js",
                        "js/scripting/css-specific.js",
                        "js/scripting/css-user.js",
                        "js/scripting/isolated-api.js",
                    ],
                },
                {
                    "description": "Expose host-awaited dashboard and popup close handshakes that drain in-flight mutations, reconcile/read back protection, preserve harmless immediate no-edit popup close, begin host-permission requests in the original Page Action user-gesture stack before awaiting serialized mutations, avoid host-permission requests for pages without hostnames, never derive an empty ruleset selection from the dashboard's deferred unrendered Filter lists pane, normalize DOM collections before selection readback, keep failed surfaces open for retry or explicit native escape, roll controls back without reloading on error, present accessible runtime errors, and use bounded retries when Page Action initialization receives missing or schema-invalid active-tab or popup-panel data, including route identifiers, privacy state, booleans, arrays, a nonnegative custom-filter count, and the blocking-level range; normalize only an omitted initial disabled-features value to an empty array while rejecting every other malformed value.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": [
                        "css/popup.css",
                        "css/settings.css",
                        "dashboard.html",
                        "js/dashboard.js",
                        "js/develop.js",
                        "js/ext.js",
                        "js/filter-lists.js",
                        "js/filter-manager-ui.js",
                        "js/popup.js",
                        "js/settings.js",
                        "popup.html",
                    ],
                }
            ],
            "license": "GPL-3.0-or-later",
            "release": "2026.825.1619",
            "sha256": "b755a66e93f63dd6c18b14a264837509c8b99c8215fa5abdd794a70c0c73372e",
            "sourceCommit": "080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b",
            "strictMinimumSafariVersion": "26.0",
            "upstreamAsset": "uBOLite_2026.825.1619.safari.zip",
            "upstreamDownloadURL": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.825.1619/uBOLite_2026.825.1619.safari.zip",
            "upstreamSHA256": "89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94",
        },
        "manifest": {
            "browser_specific_settings": {
                "safari": {"strict_min_version": "26.0"},
            },
            "manifest_version": 3,
            "name": "__MSG_extName__",
            "permissions": [
                "activeTab",
                "alarms",
                "declarativeNetRequest",
                "declarativeNetRequestFeedback",
                "declarativeNetRequestWithHostAccess",
                "scripting",
                "storage",
                "unlimitedStorage",
            ],
            "version": "2026.825.1619",
        },
        "static_action_popup_path": "popup.html",
        "archive_required_members": (
            "js/safari-dnr-normalizer.js",
            "js/safari-regex-normalizer.js",
        ),
        "archive_text_requirements": {
            "js/popup.js": (
                "assertSuccessfulMessageResponse,",
                "async function completePopupRoute(",
                "const pendingPopupRoutes = new Set();",
                "function trackPopupRoute(route)",
                "async function settlePopupRoutes()",
                "await settlePopupRoutes();",
                "await trackPopupRoute((async ( ) => {",
                "self.floorpCompletePopupRoute = completePopupRoute;",
                "void completePopupRoute(sendMessage({",
                "void completePopupRoute(runtime.openOptionsPage(), false);",
                "self.close();",
                "what: 'showMatchedRules'",
                "windowId: currentTab.windowId",
                "incognito: currentTab.incognito === true",
                "what: 'gotoURL'",
                "export function commitFilteringMode(",
                "permissionRequester = origins => browser.permissions.request({ origins })",
                "if ( targetHostname === '' ) { return Promise.resolve(false); }",
                "permissionRequest = capturePopupRequest(permissionRequester([",
                "return queuePopupMutation(( ) => commitFilteringModeNow(",
                "let popupMutationTail = Promise.resolve();",
                "self.floorpPrepareToClose = async ( ) => {",
                "return { ready: true, noMutation: true };",
                "await settlePopupMutations();",
                "what: 'floorpReadiness'",
                "actualLevel = assertSuccessfulMessageResponse(await messageSender({",
                "setFilteringMode(beforeLevel);",
                "showRuntimeError(reason);",
                "return false;",
                "typeof reloadTab === 'function'",
                "throw new Error('Active tab is unavailable');",
                "Number.isInteger(tab.id) === false",
                "Number.isInteger(tab.windowId) === false",
                "typeof tab.incognito !== 'boolean'",
                "throw new Error('Active tab routing data is unavailable');",
                "throw new Error('Active tab URL is unavailable');",
                "const response = assertSuccessfulMessageResponse(await sendMessage({",
                "response.disabledFeatures === undefined",
                "? []",
                ": response?.disabledFeatures;",
                "Number.isInteger(response.level) === false",
                "response.level < 0",
                "response.level > BLOCKING_MODE_MAX",
                "typeof response.hasOmnipotence !== 'boolean'",
                "typeof response.autoReload !== 'boolean'",
                "typeof response.isSideloaded !== 'boolean'",
                "typeof response.developerMode !== 'boolean'",
                "Array.isArray(disabledFeatures) === false",
                "disabledFeatures.some(feature => typeof feature !== 'string')",
                "Number.isInteger(response.hasCustomFilters) === false",
                "response.hasCustomFilters < 0",
                "throw new Error('Invalid popup panel data');",
                "Object.assign(popupPanelData, response, { disabledFeatures });",
                "async function tryInit(attempt = 1)",
                "if ( attempt >= 20 ) { throw reason; }",
                "return tryInit(attempt + 1);",
            ),
            "js/background.js": (
                "case 'showMatchedRules':",
                "await browser.tabs.create({",
                "active: true",
                "Number.isInteger(request.windowId)",
                "windowId: request.windowId",
                "return { opened: true }",
                "return { opened: false, error }",
                "case 'gotoURL': {",
                "sender?.tab?.windowId",
                "sender?.tab?.incognito",
                "return { opened: true, ...result }",
                "ubolErr(`gotoURL/${error}`)",
                "ubolErr(`onMessage/${request.what}/${error}`)",
                "callback({ error })",
                "request.what === 'floorpReadiness'",
                "sender?.id !== runtime.id",
                "sender?.origin?.toLowerCase() !== UBOL_ORIGIN",
                "await ensureFullyInitialized()",
                "releaseRealmRulesetStartupGate",
                "await isFullyInitialized",
                "await waitForRealmRulesetUpdates()",
                "ready: false",
                "stockUpdated !== true && isNewVersion",
                "else if ( stockUpdated !== true )",
                "await updateDynamicAndSessionRules()",
                "registerContentScripts(true)",
                "updateUserRules(true)",
                "if ( result.error ) { throw new Error(result.error); }",
                "const result = await setStrictBlockMode(request.state, true);",
                "if ( result?.error ) { throw new Error(result.error); }",
                "const rollback = await setStrictBlockMode(beforeState, true);",
                "strict-block rollback failed:",
                "setPopupBlockMode(request.state, true)",
                "setFilteringMode(request.hostname, request.level, true)",
                "setDefaultFilteringMode(request.level, true)",
                "setFilteringModeDetails(request.modes, true)",
                "async function mutateFilteringModeAndScripts(mutation)",
                "filtering-mode rollback failed:",
                "popup-mode rollback failed:",
                "return updateUserRules(true);",
                "setDefaultFilteringMode(MODE_BASIC, true)",
                "await browser.userScripts.configureWorld({ messaging: true })",
                "const sessionResult = await startSession(webextFlavor !== 'safari');",
                "foregroundRulesetReconciliationRequired = true;",
                "what === 'floorpFinalizeForegroundReconciliation'",
                "reconcileSettingsState({\n                    reloadStorage: true,\n                    fullDNR: true,\n                    allowStaticMutation: false,",
                "const reconcileResult = await reconcileSettingsState({\n"
                "        reloadStorage: true,\n"
                "        fullDNR: true,\n"
                "    });",
                "const SETTINGS_RESTORE_JOURNAL_KEY = 'floorp.settingsRestoreJournal.v1';",
                "case 'validateSettingsRestore':",
                "targetConfig.developerMode === true",
                "async function restoreRolledBackSettingsSideEffects()",
                "displayActionCountAsBadgeText: rulesetConfig.showBlockedCount",
                "await resetJobsAlarm();",
                "rollback?.foregroundReconciliationRequired === true",
                "if ( rollback?.rolledBack !== true )",
                "Interrupted settings rollback response was invalid",
                "async function commitSettingsRestore(id)",
                "if ( journal?.id !== id )",
                "return { committed: true };",
                "async function rollbackSettingsRestore(id)",
                "phase: 'rollingBack',",
                "await localReplace(journal.beforeLocal, [ SETTINGS_RESTORE_JOURNAL_KEY ]);",
                "await restoreRolledBackSettingsSideEffects();",
                "return { rolledBack: true };",
                "if ( journal?.phase === 'rollingBack' )",
                "rolledBack: result?.rolledBack === true,",
                "enabledRulesets: confirmedRulesets",
            ),
            "js/config.js": (
                "const CONFIG_ENVELOPE_VERSION = 1;",
                "const current = pendingOpPromise\n        .catch(( ) => undefined)",
                "await localWrite('rulesetConfig', envelope);",
                "const confirmed = await localRead('rulesetConfig');",
                "Durable ruleset configuration readback mismatch",
                "await sessionWrite('rulesetConfig', envelope);",
                "await sessionRemove('rulesetConfig').catch(( ) => undefined);",
            ),
            "js/ext.js": (
                "export function assertSuccessfulMessageResponse(response)",
                "typeof response.error === 'string'",
                "reason.response = response;",
                "throw reason;",
                "return assertSuccessfulMessageResponse(response);",
                "runStorageOperation,",
                "safariLocalStorageSentinelKey,",
                "key => key !== safariLocalStorageSentinelKey",
                "runStorageOperation('local'",
                "runStorageOperation('session'",
                "if ( webextFlavor === 'safari' ) { throw reason; }",
                "export function recordOptionsOperationError(reason)",
                "recordOptionsOperationError(reason);",
            ),
            "js/settings.js": (
                "assertSuccessfulMessageResponse,",
                "export async function onFilteringModeChange(ev, messageSender = sendMessage)",
                "data.defaultFilteringMode = previousLevel;",
                "showRuntimeError(reason);",
                "export async function restoreSettingsFromObject(",
                "await restore(targetConfig);",
                "recordOptionsOperationError(reason);",
                "return false;",
                "input.checked = before;",
            ),
            "js/develop.js": (
                "saved = await this.editor.saveEditorText(this);",
                "dom.text('#runtimeError', message);",
                "return false;",
            ),
            "js/filter-lists.js": (
                "dom.text('#runtimeError', message);",
                "await renderFilterLists(true);",
                "dom.cl.remove(dom.body, 'committing');",
                "const confirmedRulesets = await sendMessage({",
                "what: 'getEnabledRulesets'",
                "Enabled rulesets did not match the requested selection",
                "Array.from(rulesetEntries).some",
                "void enqueue(false, targetRevision);",
                "schedule.flush = async ( ) => {",
                "if ( revision === 0 ) {",
                "Array.isArray(enabledRulesets) === false",
                "await applyTail;",
                "if ( timer === undefined ) { return; }",
                "void schedule.flush();",
                "self.floorpPrepareToClose = async ( ) => {",
                "what: 'floorpReconcileDashboardState'",
                "const final = await settleOptionsOperations();",
                "return { ready: false, error: message };",
            ),
            "popup.html": (
                "id=\"runtimeError\"",
                "role=\"alert\"",
                "aria-live=\"assertive\"",
            ),
            "dashboard.html": (
                "id=\"runtimeError\"",
                "role=\"alert\"",
                "aria-live=\"assertive\"",
            ),
            "css/popup.css": ("#runtimeError",),
            "css/settings.css": ("#runtimeError",),
            "js/ext-utils.js": (
                "export async function gotoURL(url, type, windowId, incognito)",
                "query.windowId = windowId",
                "tab.incognito === incognito",
                "browser.tabs.update(id, { active: true })",
                "Private tab creation requires a numeric source window ID",
                "...(Number.isInteger(windowId) ? { windowId } : {})",
                "createdTab?.incognito !== incognito",
                "Created tab privacy realm does not match the source tab",
            ),
            "js/admin.js": (
                "adminReadEx(key, fresh = false)",
                "await applyAdminConfig",
                "await Promise.all([",
                "webextFlavor !== 'safari'",
                "Foreground ruleset reconciliation is required",
                "registerContentScripts(true)",
                "const result = await setStrictBlockMode(strictBlockMode, true);",
                "if ( result?.error ) { throw new Error(result.error); }",
            ),
            "js/ruleset-manager.js": (
                "await localWrite('defaultRulesetIds', newDefaultIds)",
                "import { dnr, normalizeSafariDNRRules } from './ext-compat.js';",
                "import { validatedRulesFromText } from './dnr-parser.js';",
                "import { normalizeSafariRegexRequestDomains } from './safari-regex-normalizer.js';",
                "async function validateUserDnrRules(text, developerMode = true)",
                "const { rules, bad, shapeErrors } = validatedRulesFromText(text);",
                "const acceptedRules = await pruneInvalidRegexRules(",
                "ignoredLineCount: bad.length",
                "validRules = await normalizeSafariRegexRequestDomains(",
                "'Safari normalized regexes',",
                "function normalizeDesiredRules(addRules, realm)",
                "const normalizedRules = normalizeSafariDNRRules(addRules, rejectedRules) || [];",
                "const desiredRules = normalizeDesiredRules(addRules, 'dynamic');",
                "for ( const rule of desiredRules ) {",
                "const desiredManagedRules = desiredRules",
                "addRules: desiredRules,",
                "if ( deepEquals(confirmedManagedRules, desiredManagedRules) === false )",
                "const compatibleRules = normalizeDesiredRules(addRulesUnfiltered, 'session');",
                "for ( const rule of compatibleRules ) {",
                "const addRules = compatibleRules.filter(a => a.id !== 0);",
                "await dnr.updateSessionRules({ addRules, removeRuleIds });",
                "const { rules, shapeErrors } = validatedRulesFromText(effectiveRulesText);",
                "`User DNR validation failed: ${shapeErrors.join('; ')}`",
                "out.errors.push(...shapeErrors);\n        return out;",
                "const removeRuleIds = [ ...userRules.map(a => a.id) ];",
                "const addRules = normalizeSafariDNRRules(\n"
                "        probedRules,\n"
                "        compatibilityRejected\n"
                "    ) || [];",
                "if ( rejectedRegexes.length !== 0 || compatibilityRejected.length !== 0 ) {",
                "`User DNR compatibility validation failed: ${out.errors.join('; ')}`",
                "if ( throwOnError ) { throw reason; }\n        return out;",
                "const installedAfterFailure = (await getEffectiveUserRules())",
                "addRules: currentSorted,",
                "User-rule DNR rollback readback mismatch",
                "User-rule DNR update failed and installed-rule rollback failed",
                "for ( const rule of addRules ) {",
                "const desiredRules = addRules;",
                "if ( deepEquals(confirmedRules, desiredSorted) === false )",
                "Settings restore DNR preflight failed:",
                "updateUserRules(throwOnError = false)",
                "if ( throwOnError ) { throw reason; }",
                "Enabled ruleset readback mismatch",
                "Session DNR readback mismatch",
                "Session DNR rollback readback mismatch",
                "Dynamic DNR rollback readback mismatch",
                "Session ruleset rollback readback mismatch",
                "const RULESET_RECONCILIATION_KEY = 'floorp.rulesetReconciliation.v1';",
                "allowStaticMutation = true",
            ),
            "js/dnr-parser.js": (
                "export function validateDNRRuleShape(rule)",
                "rule condition is required",
                "redirect action requires exactly one redirect target",
                "modifyHeaders requires requestHeaders or responseHeaders",
                "urlFilter and regexFilter are mutually exclusive",
                "regexFilter with request-domain conditions is unsupported by Safari 26.0",
                "modifyHeaders user rules are unsupported by Safari",
                "response-header conditions are unsupported by Safari",
                "topDomains user rules are unsupported by Safari",
                "for ( const key of [ 'requestMethods', 'excludedRequestMethods' ] )",
                "for ( const key of [ 'resourceTypes', 'excludedResourceTypes' ] )",
                "allowAllRequests does not support excludedRequestDomains on Safari",
                "allowAllRequests supports only main_frame on Safari",
                "redirect.transform.port must be empty or a valid uint16",
                "redirect.transform.scheme is invalid",
                "export function getDNRRuleShapeErrors(rules)",
                "export function validatedRulesFromText(text)",
                "shapeErrors: getDNRRuleShapeErrors(parsed.rules),",
            ),
            "js/mode-manager.js": (
                "startupFresh = false",
                "await filteringModesToDNR(userModes, startupFresh)",
                "setFilteringModeDetails(details, throwOnDNRError = false)",
                "await filteringModesToDNR(unserializeModeDetails(data), throwOnDNRError)",
                "await saveRulesetConfig()",
            ),
            "js/ext-compat.js": (
                "import { normalizeSafariDNRRules } from './safari-dnr-normalizer.js';",
                "export { normalizeSafariDNRRules };",
                "const safariStorageOperationTails = new Map()",
                "export const safariLocalStorageSentinelKey = '__floorpSafariStorageSentinel'",
                "webext.storage.local.set({ [safariLocalStorageSentinelKey]: true })",
                "export function runStorageOperation(areaName, operation)",
                "return retrySafariStorageOperation(operation);",
                "/unknown error/i.test(message) === false",
                "runStorageOperation('session', ( ) =>\n"
                "    webext.storage.session.get('safari.seenRealms')",
                "webext.storage.session.set({ 'safari.seenRealms': nextSeenRealms })",
                "runStorageOperation('session', ( ) =>\n"
                "                webext.storage.session.remove('safari.seenRealms')",
                "throwOnError = false",
                "if ( throwOnError ) { throw reason; }",
                "const safariDNROperationLockName = 'floorp.ubol.safari-dnr.v1';",
                "export const safariDNRKeeperRuleCount = 2;",
                "nativeDynamicAndSessionRuleLimit - safariDNRKeeperRuleCount",
                "export const safariDNRPublicRuleLimit = isSafari",
                "export const safariDNRPublicRuleLimitPerStore = isSafari",
                "Math.floor(nativeDynamicAndSessionRuleLimit / 2) - 1",
                "export const safariDNRKeeperRuleId = 7000000;",
                "urlFilter: '|https://floorp.invalid/.well-known/ubol-dnr-keeper|'",
                "const lockManager = self.navigator?.locks;",
                "return lockManager.request(",
                "function updateNativeDynamicRules(options)",
                "return nativeDNR.updateDynamicRules(options);",
                "function updateNativeSessionRules(options)",
                "return nativeDNR.updateSessionRules(options);",
                "function updateNativeEnabledRulesets(...args)",
                "return nativeDNR.updateEnabledRulesets(...args);",
                "async function ensureSafariDNRKeeper(storageType)",
                "if ( isSafariDNRKeeperCapacityBlocked(storageType, stores) )",
                "await updateRules({ addRules: [ structuredClone(safariDNRKeeperRule) ] });",
                "stores = await readNativeDNRStores();\n"
                "        rules = rulesForSafariDNRStorage(stores, storageType);",
                "async function ensureSafariDNRKeeperWithCapacityDeferral(storageType)",
                "isConfirmedSafariDNRCapacityBlock(reason, storageType, stores)",
                "async function ensureSafariDNRKeepers({ allowCapacityDeferral = false } = {})",
                "function assertNoSafariDNRKeeperCollision(options)",
                "Safari DNR keeper rule cannot be removed",
                "Safari DNR keeper rule ID is reserved",
                "await ensureSafariDNRKeepers({ allowCapacityDeferral: true });",
                "(options.addRules?.length || 0) === 0",
                "(options.removeRuleIds?.length || 0) === 0",
                "await ensureSafariDNRKeeperWithCapacityDeferral('dynamic');",
                "await ensureSafariDNRKeeperWithCapacityDeferral('session');",
                "function projectSafariDNRUpdate(rules, options)",
                "Safari DNR capacity reserves ${safariDNRKeeperRuleCount} hidden",
                "projectedTargetPublicRuleCount + visibleOtherRules.length",
                "projectedTargetPublicRuleCount > safariDNRPublicRuleLimitPerStore",
                "if ( isPureReduction === false || hasDeletionAnchor === false )",
                "projection.retainedRules.length === 0",
                "const optionsWithKeeper = targetKeeper === undefined",
                "await ensureSafariDNRKeepers({ allowCapacityDeferral: true });",
                "rule => rule.id !== safariDNRKeeperRuleId",
                "const result = await runSafariDNROperation(( ) =>",
                "rulesMatchedInfo: result.rulesMatchedInfo.filter(info =>",
                "info?.rule?.ruleId !== safariDNRKeeperRuleId",
                "? safariDNRPublicRuleLimitPerStore",
                "await updateNativeEnabledRulesets",
                "export function readNativeEnabledRulesets(",
                "Invalid enabled static DNR readback",
                "Realm static DNR refresh readback mismatch",
                "Static ruleset update readback mismatch",
                "return getNativeDynamicRules(...args);",
                "return getNativeSessionRules(...args);",
                "return getNativeEnabledRulesets(...args);",
                "return updateNativeDynamicRules(optionsBefore);",
                "return updateNativeSessionRules(optionsBefore);",
                "return updateNativeEnabledRulesets(...args);",
                "async function resolveRealm(windowId)",
                "windows.getAll({ windowTypes: [ 'normal' ] })",
                "currentRealm => ({ succeeded: true, currentRealm })",
                "releaseRealmRulesetStartupGate",
                "export async function waitForRealmRulesetUpdates()",
                "await startupGate",
                "pending === realmRulesetUpdates",
                "realmRulesetUpdateError",
                "realmRulesetUpdateError = undefined;",
                "realmRulesetStartupError ??= reason;",
                "isRealmRulesetStartupPending = false;",
                "const prepareUpdateRules = optionsBefore => {",
                "assertNoSafariDNRKeeperCollision(optionsBefore);",
                "? normalizeSafariDNRRules(addRules)",
                "if ( addRulesAfter?.length ) { optionsAfter.addRules = addRulesAfter; }",
                "return updateSafariDNRRules('dynamic', optionsAfter);",
                "return updateSafariDNRRules('session', optionsAfter);",
                "rule0.condition.initiatorDomains = allowed;",
                "rule0.condition.excludedInitiatorDomains = notAllowed;",
            ),
            "js/safari-dnr-normalizer.js": (
                "const supportedActionTypes = new Set([",
                "const supportedConditionKeys = new Set([",
                "const unsupportedIncludedConditionKeys = new Set([",
                "const unsupportedExcludedConditionKeys = new Set([",
                "'excludedTopDomains',",
                "[ 'domains', 'initiatorDomains' ]",
                "[ 'excludedDomains', 'excludedInitiatorDomains' ]",
                "sameArray(condition[legacyKey], condition[standardKey]) === false",
                "delete condition[legacyKey];",
                "function normalizeExcludedEnumArray(condition, key, supportedValues)",
                "// Removing an excluded value broadens the rule.",
                "if ( values.some(value => supportedValues.has(value) === false) ) {\n"
                "        return `${key} contains values unsupported by Safari`;\n"
                "    }",
                "if ( Array.isArray(condition[key]) && condition[key].length === 0 ) {\n"
                "                delete condition[key];\n"
                "                continue;\n"
                "            }\n"
                "            return `${key} is unsupported`;",
                "owns(condition, 'requestDomains') ||\n"
                "            owns(condition, 'excludedRequestDomains')",
                "return 'regexFilter with request-domain conditions is unsupported';",
                "return `allowAllRequests with ${key} is unsupported`;",
                "return 'case-sensitive allowAllRequests is unsupported';",
                "sameArray(condition.resourceTypes, [ 'main_frame' ]) === false",
                "export function normalizeSafariDNRRules(rules, rejectedRules = [])",
                "const rule = structuredClone(sourceRule);",
                "const reason = normalizeAction(rule) || normalizeCondition(rule);",
                "rejectedRules.push({ rule: sourceRule, reason });",
                "out.push(rule);",
            ),
            "js/safari-regex-normalizer.js": (
                "function canonicalJSON(value)",
                "export async function fingerprintSafariRegexRule(rule)",
                "if ( key === 'id' ) { continue; }",
                "subtle.digest(\n        'SHA-256',",
                "const exactRuleActions = new Map([",
                "{ type: 'removeRequestDomains' }",
                "type: 'expandRequestDomains'",
                "export async function normalizeSafariRegexRequestDomains(",
                "const hasUnsafeExcludedRequestDomains =",
                "excludedRequestDomains.length !== 0",
                "const fingerprint = await fingerprintSafariRegexRule(rule);",
                "const action = exactRuleActions.get(fingerprint);",
                "if ( action === undefined ) {\n            rejectedRules.push(rule);",
                "const normalized = structuredClone(rule);",
                "delete normalized.condition.requestDomains;",
                "regexFilter.split(action.hostFragment).length !== 2",
                "const expanded = structuredClone(normalized);",
                "delete expanded.condition.requestDomains;",
            ),
            "js/scripting-manager.js": (
                "registerContentScripts(throwOnError = false)",
                "registerContentScripts.pendingOp = operation.catch",
                "rulesetsDetails.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0)",
                "export async function reconcileSafariContentScripts(scripting, desired)",
                "for ( let attempt = 1; attempt <= 3; attempt++ )",
                "await scripting.getRegisteredContentScripts()",
                "floorp-safari-registration-sentinel",
                "matches: [ 'https://floorp.invalid/*' ]",
                "js/safari-registration-sentinel.js",
                "persistAcrossSessions: true",
                "await scripting.registerContentScripts([ sentinel ])",
                "details.id !== safariRegistrationSentinelId",
                "await scripting.registerContentScripts(toRegister);\n            }\n            if ( toUpdate.length !== 0 ) {",
                "scripting.updateContentScripts(toUpdate)",
                "scripting.unregisterContentScripts({ ids: removeIds })",
                "registrationMismatch(after, desired)",
                "details.world.toUpperCase()",
                "await reconcileSafariContentScripts(browser.scripting, toAdd)",
                "if ( webextFlavor === 'safari' || throwOnError ) { throw reason; }",
            ),
            "js/scripting/css-api.js": (
                "const documentElement = document.documentElement;",
                "const documentTimeOrigin = performance.timeOrigin;",
                "api.documentElement === documentElement &&",
                "api.documentTimeOrigin === documentTimeOrigin",
                "self.removeEventListener('pagereveal', api.pageRevealHandler);",
                "const inserted = new Set();",
                "pageRevealHandler,",
                "self.addEventListener('pagereveal', pageRevealHandler);",
            ),
            "js/scripting/css-specific.js": (
                "const cssSpecificDocumentGeneration = {};",
                "const previousResetTail = self.cssSpecificResetTail;",
                "const previousListsProceduralFilterer = self.listsProceduralFiltererAPI;",
                "self.listsProceduralFiltererAPI = undefined;",
                "const cssSpecificResetTail = Promise.resolve(previousResetTail)",
                ".then(( ) => previousListsProceduralFilterer instanceof Object",
                "? previousListsProceduralFilterer.reset()",
                "self.cssSpecificResetTail = cssSpecificResetTail;",
                "await cssSpecificResetTail;",
                "self.cssSpecificDocumentGeneration === cssSpecificDocumentGeneration;",
                "if ( isCurrentDocument() === false ) { return; }",
            ),
            "js/scripting/css-user.js": (
                "const cssUserDocumentGeneration = {};",
                "self.removeEventListener('pagereveal', self.cssUserStartHandler);",
                "self.cssUserDocumentGeneration = cssUserDocumentGeneration;",
                "const previousProceduralFilterer = self.customProceduralFiltererAPI;",
                "const previousPendingOp = self.cssUserPendingOp;",
                "const cssUserCleanupOp = Promise.resolve(previousPendingOp)",
                ".then(( ) => previousProceduralFilterer instanceof Object",
                "? previousProceduralFilterer.reset()",
                "self.cssUserPendingOp = cssUserCleanupOp;",
                "const pendingOp = Promise.resolve(self.cssUserPendingOp)",
                "self.cssUserPendingOp = pendingOp.catch(( ) => undefined);",
                "self.cssUserDocumentGeneration === cssUserDocumentGeneration &&",
                "self.cssUserStartHandler === uBOL_cssUserStart;",
                "if ( isCurrentDocument() === false ) { return; }",
            ),
            "js/scripting/isolated-api.js": (
                "const documentElement = document.documentElement;",
                "const documentTimeOrigin = performance.timeOrigin;",
                "api.documentElement === documentElement &&",
                "api.documentTimeOrigin === documentTimeOrigin",
                "isolatedAPI.documentElement = documentElement;",
                "isolatedAPI.documentTimeOrigin = documentTimeOrigin;",
            ),
            "js/safari-registration-sentinel.js": (
                "'use strict';",
            ),
            "js/floorp-reconcile.js": (
                "globalThis.floorpReconcileProtection = reconcileProtection;",
                "await saveRulesetConfig();",
                "await enableRulesets(",
                "Foreground static ruleset readback mismatch",
                "what: 'floorpFinalizeForegroundReconciliation'",
                "foregroundReconciliationRequired: true",
                "rolledBack: finalized?.rolledBack === true,",
            ),
            "js/fetch.js": (
                "if ( response.ok !== true )",
                "Missing JSON data",
                "throw reason;",
            ),
            "js/compiled-filters.js": (
                "Compiling filters timed out",
                "runtime.onMessage.removeListener(handler);",
                "export async function reconcileUserScripts(userScripts, toAdd)",
                "User-script rollback readback mismatch",
                "const current = pendingRegister\n        .catch(( ) => undefined)",
            ),
            "js/filter-manager.js": (
                "pendingStorageOp = operation.catch(( ) => undefined);",
                "export async function mutateCustomFiltersAtomically(",
                "Custom-filter mutation and rollback both failed",
            ),
            "js/backup-restore.js": (
                "what: 'validateSettingsRestore'",
                "what: 'beginSettingsRestore'",
                "what: 'commitSettingsRestore'",
                "transaction?.foregroundReconciliationRequired === true",
                "Settings restore transaction response was invalid",
                "commit?.foregroundReconciliationRequired === true",
                "commit?.committed !== true",
                "what: 'rollbackSettingsRestore'",
                "rollback?.foregroundReconciliationRequired === true",
                "const reconciliation = await reconcileProtection();",
                "if ( reconciliation.rolledBack === true )",
                "rollback = { rolledBack: true };",
                "if ( rollback?.rolledBack !== true )",
                "Settings rollback response was invalid",
                "Settings rollback did not become ready",
            ),
        },
        "archive_text_order_requirements": {
            "js/popup.js": (
                "permissionRequest = capturePopupRequest(permissionRequester([",
                "return queuePopupMutation(( ) => commitFilteringModeNow(",
            ),
        },
        "archive_text_order_requirement_groups": {
            "js/popup.js": (
                (
                    "await settlePopupRoutes();",
                    "if ( popupMutationRevision === 0 )",
                ),
                (
                    "await trackPopupRoute((async ( ) => {",
                    "self.close();",
                ),
            ),
            "js/backup-restore.js": (
                (
                    "what: 'validateSettingsRestore'",
                    "what: 'beginSettingsRestore'",
                ),
                (
                    "what: 'updateUserDnrRules'",
                    "const reconciliation = await reconcileProtection({\n"
                    "        enabledRulesets: Array.from(enabledRulesets),",
                ),
                (
                    "let transaction = await sendMessage({ what: 'beginSettingsRestore' });",
                    "if ( transaction?.foregroundReconciliationRequired === true )",
                    "\n        transaction = await sendMessage({ "
                    "what: 'beginSettingsRestore' });",
                    "if ( typeof transaction?.id !== 'string' || transaction.id === '' )",
                ),
                (
                    "let commit = await sendMessage({",
                    "if ( commit?.foregroundReconciliationRequired === true )",
                    "            commit = await sendMessage({",
                    "if ( commit?.committed !== true )",
                ),
                (
                    "let rollback = await sendMessage({\n"
                    "                what: 'rollbackSettingsRestore',",
                    "if ( rollback?.foregroundReconciliationRequired === true ) {\n"
                    "                const reconciliation = await reconcileProtection();",
                    "if ( reconciliation.rolledBack === true )",
                    "rollback = { rolledBack: true };",
                    "rollback = await sendMessage({\n"
                    "                        what: 'rollbackSettingsRestore',",
                    "if ( rollback?.rolledBack !== true )",
                    "const readiness = await sendMessage({ what: 'floorpReadiness' });",
                ),
            ),
            "js/background.js": (
                (
                    "async function commitSettingsRestore(id)",
                    "if ( journal?.id !== id )",
                    "const result = await reconcileSettingsState({",
                    "await localRemove(SETTINGS_RESTORE_JOURNAL_KEY);",
                    "return { committed: true };",
                ),
                (
                    "async function rollbackSettingsRestore(id)",
                    "phase: 'rollingBack',",
                    "await localReplace(journal.beforeLocal, [ SETTINGS_RESTORE_JOURNAL_KEY ]);",
                    "const result = await reconcileSettingsState({ resetSession: true });",
                    "await restoreRolledBackSettingsSideEffects();",
                    "await localRemove(SETTINGS_RESTORE_JOURNAL_KEY);\n"
                    "    return { rolledBack: true };",
                ),
                (
                    "if ( request.what === 'floorpFinalizeForegroundReconciliation' )",
                    "if ( journal?.phase === 'rollingBack' )",
                    "result = await rollbackSettingsRestore(journal.id);",
                    "rolledBack: result?.rolledBack === true,",
                ),
            ),
            "js/ruleset-manager.js": (
                (
                    "const desiredRules = normalizeDesiredRules(addRules, 'dynamic');",
                    "for ( const rule of desiredRules ) {",
                    "const desiredManagedRules = desiredRules",
                    "addRules: desiredRules,",
                    "if ( deepEquals(confirmedManagedRules, desiredManagedRules) === false )",
                ),
                (
                    "const compatibleRules = normalizeDesiredRules(addRulesUnfiltered, 'session');",
                    "for ( const rule of compatibleRules ) {",
                    "const addRules = compatibleRules.filter(a => a.id !== 0);",
                    "await dnr.updateSessionRules({ addRules, removeRuleIds });",
                ),
                (
                    "const { rules, shapeErrors } = validatedRulesFromText(effectiveRulesText);",
                    "out.errors.push(...shapeErrors);\n        return out;",
                    "if ( Array.isArray(sandboxRules) )",
                    "const removeRuleIds = [ ...userRules.map(a => a.id) ];",
                    "const addRules = normalizeSafariDNRRules(",
                    "for ( const rule of addRules ) {",
                    "const desiredRules = addRules;",
                    "await dnr.updateDynamicRules({\n"
                    "            addRules: desiredRules,",
                    "if ( deepEquals(confirmedRules, desiredSorted) === false )",
                ),
            ),
        },
        "archive_text_forbidden_requirements": {
            "js/background.js": ("    'validateSettingsRestore',",),
            "js/ext-compat.js": (
                "const isSupportedRule = r => {",
                "structuredClone(addRules).filter(isSupportedRule)",
                "r.condition.domains = r.condition.requestDomains;",
                "r.condition.domains = r.condition.initiatorDomains;",
                "r.condition.excludedDomains = r.condition.excludedInitiatorDomains;",
                "rule0.condition.domains = allowed;",
                "rule0.condition.excludedDomains = notAllowed;",
            ),
            "js/ruleset-manager.js": (
                "Settings restore DNR preflight failed: invalid syntax at line(s)",
            ),
        },
        "review_required_values": {
            "Floorp-derived",
            "declarativeNetRequestFeedback",
            "floorp.invalid",
            "hidden DNR keeper",
            "incognito",
            "deterministic startup",
            "uBOLite-floorp-ios-2026.825.1619.patch",
        },
    },
)


def fail(message: str) -> None:
    raise RuntimeError(message)


def load_json(path: Path, repository_root: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read valid JSON from {path.relative_to(repository_root)}: {error}")
    if not isinstance(value, dict):
        fail(f"{path.relative_to(repository_root)} must contain a JSON object")
    return value


def checked_repository_path(relative_path: str, repository_root: Path) -> Path:
    posix_path = PurePosixPath(relative_path)
    if posix_path.is_absolute() or ".." in posix_path.parts or "\\" in relative_path:
        fail(f"unsafe repository-relative path: {relative_path}")
    return repository_root.joinpath(*posix_path.parts)


def verify_support_files(entry: dict[str, object], repository_root: Path) -> None:
    support_files = entry.get("support_files", {})
    assert isinstance(support_files, dict)
    for relative_path, expected_digest in support_files.items():
        path = checked_repository_path(str(relative_path), repository_root)
        if not path.is_file():
            fail(f"missing bundled-extension support file: {relative_path}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected_digest:
            fail(f"unexpected SHA-256 for support file {relative_path}: {digest}")


def javascript_without_comments(source: str) -> str:
    """Remove JS comments while preserving strings and source whitespace."""
    output: list[str] = []
    quote: str | None = None
    escaped = False
    in_block_comment = False
    index = 0
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if in_block_comment:
            if character == "*" and following == "/":
                output.extend("  ")
                index += 2
                in_block_comment = False
                continue
            output.append("\n" if character == "\n" else " ")
            index += 1
            continue
        if quote is not None:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            index += 1
            continue
        if character in ("'", '"', "`"):
            quote = character
            output.append(character)
            index += 1
            continue
        if character == "/" and following == "/":
            while index < len(source) and source[index] != "\n":
                output.append(" ")
                index += 1
            continue
        if character == "/" and following == "*":
            output.extend("  ")
            index += 2
            in_block_comment = True
            continue
        output.append(character)
        index += 1
    return "".join(output)


def verify_ubol_safari_dnr_keeper(
    package: zipfile.ZipFile,
    names: list[str],
    archive_name: str,
) -> None:
    source = package.read("js/ext-compat.js").decode("utf-8")
    raw_root_tokens: list[tuple[str, int]] = []
    computed_raw_roots: list[tuple[str, int]] = []
    uncommented_javascript: dict[str, str] = {}
    raw_root_token_pattern = re.compile(r"\bdeclarativeNetRequest\b")
    computed_raw_root_pattern = re.compile(
        r"\[\s*(['\"])declarative\1\s*\+\s*"
        r"(['\"])NetRequest\2\s*\]"
    )
    for member in names:
        if not member.startswith("js/") or not member.endswith((".js", ".mjs")):
            continue
        member_source = package.read(member).decode("utf-8")
        uncommented_source = javascript_without_comments(member_source)
        uncommented_javascript[member] = uncommented_source
        raw_root_tokens.extend(
            (member, uncommented_source.count("\n", 0, match.start()) + 1)
            for match in raw_root_token_pattern.finditer(uncommented_source)
        )
        computed_raw_roots.extend(
            (member, uncommented_source.count("\n", 0, match.start()) + 1)
            for match in computed_raw_root_pattern.finditer(uncommented_source)
        )
    canonical_raw_root_pattern = re.compile(
        r"\bconst\s+nativeDNR\s*=\s*webext\s*\.\s*"
        r"declarativeNetRequest\s*;"
    )
    if (
        len(raw_root_tokens) != 1 or
        raw_root_tokens[0][0] != "js/ext-compat.js" or
        computed_raw_roots
    ):
        fail(
            f"{archive_name} bypasses the Safari DNR facade: acquire the raw "
            "DNR root only through the single reviewed ext-compat alias"
        )
    if len(canonical_raw_root_pattern.findall(javascript_without_comments(source))) != 1:
        fail(f"{archive_name} must define exactly one reviewed raw DNR root")

    direct_updates = (
        "updateDynamicRules",
        "updateSessionRules",
        "updateEnabledRulesets",
    )
    for method in direct_updates:
        member_access_pattern = re.compile(
            rf"\bnativeDNR\s*(?:\?\.|\.)\s*{method}\b"
        )
        direct_call_pattern = re.compile(
            rf"\bnativeDNR\s*(?:\?\.|\.)\s*{method}\s*\("
        )
        member_accesses: list[tuple[str, int]] = []
        direct_calls: list[tuple[str, int]] = []
        for member, uncommented_source in uncommented_javascript.items():
            member_accesses.extend(
                (member, uncommented_source.count("\n", 0, match.start()) + 1)
                for match in member_access_pattern.finditer(uncommented_source)
            )
            direct_calls.extend(
                (member, uncommented_source.count("\n", 0, match.start()) + 1)
                for match in direct_call_pattern.finditer(uncommented_source)
            )
        if (
            len(member_accesses) != 1 or
            member_accesses[0][0] != "js/ext-compat.js" or
            len(direct_calls) != 1 or
            direct_calls[0][0] != "js/ext-compat.js"
        ):
            fail(
                f"{archive_name} must route every native {method} call through "
                "its single Safari DNR gate helper"
            )
    if any(
        re.search(r"\bnativeDNR\s*(?:\?\.\s*)?\[", member_source)
        for member_source in uncommented_javascript.values()
    ):
        fail(f"{archive_name} bypasses the Safari DNR gate through bracket access")

    update_names = "|".join(direct_updates)
    native_update_extractions = (
        re.compile(
            rf"\b(?:const|let|var)\s+\w+\s*=\s*nativeDNR\b"
            rf"(?!\s*[.\[])"
        ),
        re.compile(
            rf"\b(?:const|let|var)\s*\{{[^;{{}}]*"
            rf"\b(?:{update_names})\b[^;{{}}]*\}}\s*=\s*nativeDNR\b",
            re.DOTALL,
        ),
        re.compile(
            rf"\bReflect\s*\.\s*get\s*\(\s*nativeDNR\s*,\s*"
            rf"(['\"])(?:{update_names})\1"
        ),
    )
    if any(
        pattern.search(member_source)
        for member_source in uncommented_javascript.values()
        for pattern in native_update_extractions
    ):
        fail(f"{archive_name} extracts a raw native DNR update method")
    native_dnr_alias_pattern = re.compile(
        r"\b([A-Za-z_$][\w$]*)\s*=\s*nativeDNR\b"
        r"(?!\s*(?:\?\.|\.|\[))"
    )
    native_dnr_aliases = [
        (member, match.group(1))
        for member, member_source in uncommented_javascript.items()
        for match in native_dnr_alias_pattern.finditer(member_source)
    ]
    if native_dnr_aliases != [
        ("js/ext-compat.js", "api"),
        ("js/ext-compat.js", "api"),
    ]:
        fail(f"{archive_name} extracts or aliases the raw native DNR object")

    for member in names:
        if not member.startswith("js/") or not member.endswith((".js", ".mjs")):
            continue
        member_source = package.read(member).decode("utf-8")
        for method in direct_updates:
            if f"declarativeNetRequest.{method}(" in member_source:
                fail(
                    f"{archive_name} bypasses the Safari DNR facade in {member}: "
                    f"{method}"
                )

    def section(start: str, end: str) -> str:
        start_index = source.find(start)
        end_index = source.find(end, start_index + len(start))
        if start_index == -1 or end_index == -1:
            fail(f"{archive_name} omits the Safari DNR keeper section: {start}")
        return source[start_index:end_index]

    def require_ordered(label: str, body: str, values: tuple[str, ...]) -> None:
        cursor = 0
        for value in values:
            position = body.find(value, cursor)
            if position == -1:
                fail(
                    f"{archive_name} orders the Safari DNR keeper incorrectly in "
                    f"{label}: {values}"
                )
            cursor = position + len(value)

    ensure_body = section(
        "async function ensureSafariDNRKeeper(storageType)",
        "async function ensureSafariDNRKeeperWithCapacityDeferral(storageType)",
    )
    require_ordered(
        "concurrent first-use recovery",
        ensure_body,
        (
            "await updateRules({ addRules:",
            "} catch(reason) {",
            "stores = await readNativeDNRStores();",
            "keeper = findSafariDNRKeeper(rules, storageType);",
        ),
    )
    require_ordered(
        "capacity-preserving update",
        section(
            "async function updateSafariDNRRules(storageType, options)",
            "// Workaround for:",
        ),
        (
            "await ensureSafariDNRKeepers({ allowCapacityDeferral: true });",
            "(options.addRules?.length || 0) === 0",
            "(options.removeRuleIds?.length || 0) === 0",
            "const projection = projectSafariDNRUpdate",
            "projectedTargetPublicRuleCount > safariDNRPublicRuleLimitPerStore",
            "projectedPublicRuleCount > safariDNRPublicRuleLimit",
            "if ( isPureReduction === false || hasDeletionAnchor === false )",
            "projection.retainedRules.length === 0",
            "const optionsWithKeeper = targetKeeper === undefined",
            "await updateNative",
            "confirmedKeeper === undefined",
            "await ensureSafariDNRKeepers({ allowCapacityDeferral: true });",
        ),
    )
    for function_name, end_marker in (
        ("async function forceEnableRulesets(currentRealm)", "let realmRulesetUpdates"),
        (
            "async function updateEnabledRulesetsAndResetRealms(options)",
            "const prepareUpdateRules",
        ),
    ):
        require_ordered(
            function_name,
            section(function_name, end_marker),
            (
                "await ensureSafariDNRKeepers({ allowCapacityDeferral: true });",
                "await updateNativeEnabledRulesets",
            ),
        )

    dynamic_facade = section(
        "    getDynamicRules(...args) {",
        "    getEnabledRulesets(...args) {",
    )
    session_facade = section(
        "    getSessionRules(...args) {",
        "    isRegexSupported",
    )
    keeper_filter_pattern = re.compile(
        r"rules\s*\.\s*filter\s*\(\s*rule\s*=>\s*"
        r"rule\s*\.\s*id\s*!==\s*safariDNRKeeperRuleId\s*\)",
        re.DOTALL,
    )
    if any(
        len(keeper_filter_pattern.findall(body)) != 1
        for body in (dynamic_facade, session_facade)
    ):
        fail(f"{archive_name} does not hide both Safari DNR keeper rules")
    require_ordered(
        "dynamic-rule facade",
        dynamic_facade,
        (
            "return getNativeDynamicRules(...args);",
            "await ensureSafariDNRKeeperWithCapacityDeferral('dynamic');",
            "rule => rule.id !== safariDNRKeeperRuleId",
        ),
    )
    require_ordered(
        "session-rule facade",
        session_facade,
        (
            "return getNativeSessionRules(...args);",
            "await ensureSafariDNRKeeperWithCapacityDeferral('session');",
            "rule => rule.id !== safariDNRKeeperRuleId",
        ),
    )
    require_ordered(
        "matched-rule facade",
        section("    getMatchedRules(...args) {", "    getSessionRules(...args) {"),
        (
            "return nativeDNR.getMatchedRules(...args);",
            "const result = await runSafariDNROperation(( ) =>",
            "rulesMatchedInfo: result.rulesMatchedInfo.filter(info =>",
            "info?.rule?.ruleId !== safariDNRKeeperRuleId",
        ),
    )


def verify_archive(
    entry: dict[str, object],
    bundle_root: Path,
    repository_root: Path,
) -> None:
    archive = bundle_root / str(entry["archive"])
    provenance_path = bundle_root / str(entry["provenance_file"])
    license_path = bundle_root / str(entry["license_file"])
    expected_provenance = entry["provenance"]
    expected_manifest = entry["manifest"]
    assert isinstance(expected_provenance, dict)
    assert isinstance(expected_manifest, dict)

    if not archive.is_file():
        fail(f"missing bundled archive: {archive.relative_to(repository_root)}")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != expected_provenance["sha256"]:
        fail(f"unexpected SHA-256 for {archive.name}: {digest}")

    provenance = load_json(provenance_path, repository_root)
    if provenance != expected_provenance:
        fail(f"provenance changed for {archive.name}")
    verify_support_files(entry, repository_root)

    try:
        license_text = license_path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read license for {archive.name}: {error}")
    if str(entry["license_marker"]) not in license_text:
        fail(f"license text does not match {expected_provenance['license']} for {archive.name}")

    try:
        with zipfile.ZipFile(archive) as package:
            names = package.namelist()
            for name in names:
                path = PurePosixPath(name)
                if path.is_absolute() or ".." in path.parts or "\\" in name:
                    fail(f"unsafe ZIP entry in {archive.name}: {name}")
                if name.endswith((".orig", ".rej")):
                    fail(f"unexpected patch artifact in {archive.name}: {name}")
            if names.count("manifest.json") != 1:
                fail(f"{archive.name} must contain exactly one root manifest.json")
            manifest = json.loads(package.read("manifest.json"))
            popup_path = str(entry["static_action_popup_path"])
            popup_parts = PurePosixPath(popup_path)
            if (
                not popup_path
                or popup_parts.is_absolute()
                or ".." in popup_parts.parts
                or "\\" in popup_path
                or popup_parts.as_posix() != popup_path
                or names.count(popup_path) != 1
            ):
                fail(f"invalid or missing static action popup in {archive.name}: {popup_path}")
            action = manifest.get("action") if isinstance(manifest, dict) else None
            if not isinstance(action, dict) or action.get("default_popup") != popup_path:
                fail(f"unexpected static action popup in {archive.name}")
            commands = manifest.get("commands", {}) if isinstance(manifest, dict) else {}
            reserved_commands = {
                "_execute_action",
                "_execute_browser_action",
                "_execute_page_action",
            }
            if isinstance(commands, dict) and reserved_commands.intersection(commands):
                fail(f"reserved action command is not allowed in {archive.name}")
            for member in entry.get("archive_required_members", ()):
                if names.count(str(member)) != 1:
                    fail(
                        f"{archive.name} must contain exactly one required archive "
                        f"member: {member}"
                    )
            forbidden_popup_apis = (
                "browser.action.setPopup",
                "chrome.action.setPopup",
                "browser.browserAction.setPopup",
                "chrome.browserAction.setPopup",
                "browser.pageAction.setPopup",
                "chrome.pageAction.setPopup",
                "browser.action.openPopup",
                "chrome.action.openPopup",
            )
            for member in names:
                if not member.endswith((".js", ".mjs", ".html")):
                    continue
                source = package.read(member).decode("utf-8")
                forbidden = next((api for api in forbidden_popup_apis if api in source), None)
                if forbidden is not None:
                    fail(
                        f"{archive.name} uses unsupported dynamic popup API "
                        f"in {member}: {forbidden}"
                    )
            for member, required_values in entry.get("archive_text_requirements", {}).items():
                source = package.read(str(member)).decode("utf-8")
                for required_value in required_values:
                    if required_value not in source:
                        fail(
                            f"{archive.name} omits required compatibility code in "
                            f"{member}: {required_value}"
                        )
            for member, forbidden_values in entry.get(
                "archive_text_forbidden_requirements", {}
            ).items():
                source = package.read(str(member)).decode("utf-8")
                for forbidden_value in forbidden_values:
                    if forbidden_value in source:
                        fail(
                            f"{archive.name} includes forbidden compatibility code in "
                            f"{member}: {forbidden_value}"
                        )
            for member, ordered_values in entry.get(
                "archive_text_order_requirements", {}
            ).items():
                source = package.read(str(member)).decode("utf-8")
                positions = [source.find(value) for value in ordered_values]
                if -1 in positions or positions != sorted(positions):
                    fail(
                        f"{archive.name} orders compatibility code incorrectly in "
                        f"{member}: {ordered_values}"
                    )
            for member, ordered_groups in entry.get(
                "archive_text_order_requirement_groups", {}
            ).items():
                source = package.read(str(member)).decode("utf-8")
                for ordered_values in ordered_groups:
                    positions = [source.find(value) for value in ordered_values]
                    if -1 in positions or positions != sorted(positions):
                        fail(
                            f"{archive.name} orders compatibility code incorrectly in "
                            f"{member}: {ordered_values}"
                        )
            if entry["display_name"] == "uBlock Origin Lite":
                verify_ubol_safari_dnr_keeper(package, names, archive.name)
            bad_member = package.testzip()
            if bad_member is not None:
                fail(f"CRC failure in {archive.name}: {bad_member}")
    except (OSError, UnicodeDecodeError, zipfile.BadZipFile, KeyError, json.JSONDecodeError) as error:
        fail(f"invalid bundled extension archive {archive.name}: {error}")

    if not isinstance(manifest, dict):
        fail(f"manifest.json in {archive.name} must contain an object")
    for key, expected_value in expected_manifest.items():
        if manifest.get(key) != expected_value:
            fail(f"unexpected manifest {key} in {archive.name}: {manifest.get(key)!r}")


def verify_review_notes(repository_root: Path) -> None:
    path = repository_root / "docs/app-review-notes-native-webextensions.md"
    try:
        document = path.read_text(encoding="utf-8")
        blocks = document.split("```text\n")
        notes = blocks[1].split("\n```", 1)[0]
        what_to_test = blocks[2].split("\n```", 1)[0]
    except (OSError, IndexError) as error:
        fail(f"cannot read the App Review notes template: {error}")
    if len(notes.encode("utf-8")) > 4_000:
        fail("App Review notes exceed App Store Connect's 4,000-byte limit")
    if len(what_to_test.encode("utf-8")) > 4_000:
        fail("TestFlight What to Test text exceeds App Store Connect's 4,000-byte limit")
    if "Dark Reader" not in what_to_test or "uBlock Origin Lite" not in what_to_test:
        fail("TestFlight What to Test text must cover both bundled extensions")

    required_values = {
        "WKWebExtension",
        "does not download WebExtension code",
        "[RELEASE_TAG_OR_FULL_COMMIT]",
    }
    for entry in EXPECTED:
        provenance = entry["provenance"]
        manifest = entry["manifest"]
        assert isinstance(provenance, dict)
        assert isinstance(manifest, dict)
        required_values.update(
            {
                f'{entry["display_name"]} {manifest["version"]}',
                str(provenance["sha256"]),
                str(provenance["sourceCommit"]),
                str(entry["review_license_marker"]),
            }
        )
        for key in ("buildScript", "upstreamDownloadURL", "upstreamSHA256"):
            if key in provenance:
                required_values.add(str(provenance[key]))
        for change in provenance.get("changes", []):
            if isinstance(change, dict) and "patch" in change:
                required_values.add(str(change["patch"]))
        review_required_values = entry.get("review_required_values", set())
        assert isinstance(review_required_values, set)
        required_values.update(review_required_values)
    missing = sorted(value for value in required_values if value not in notes)
    if missing:
        fail(f"App Review notes omit required disclosure values: {missing}")
    forbidden_values = {
        "Dark Reader 4.9.129, MIT, unmodified",
        "Unmodified official Chrome MV3 asset",
        "uBlock Origin Lite 2026.825.1619, GNU GPL v3.0 or later, unmodified",
        "Unmodified official Safari asset",
    }
    forbidden = sorted(value for value in forbidden_values if value in notes)
    if forbidden:
        fail(f"App Review notes misdescribe the derived Dark Reader asset: {forbidden}")


def verify_testflight_metadata(repository_root: Path) -> None:
    metadata = {
        "en-US": repository_root / "firefox-ios/TestFlight/WhatToTest.en-US.txt",
        "ja-JP": repository_root / "firefox-ios/TestFlight/WhatToTest.ja-JP.txt",
    }
    required_values = {
        "7,000,000",
        "Dark Reader",
        "uBlock Origin Lite",
        "WKWebExtension",
        "user DNR",
    }
    for entry in EXPECTED:
        manifest = entry["manifest"]
        assert isinstance(manifest, dict)
        required_values.add(f'{entry["display_name"]} {manifest["version"]}')
    forbidden_values = {
        "en-US": {
            "one signed, app-bundled extension",
            "exactly one catalog package",
        },
        "ja-JP": {
            "拡張機能は Dark Reader 1件",
            "catalog package は1件だけ",
        },
    }
    documents = {}
    for locale, path in metadata.items():
        try:
            document = path.read_text(encoding="utf-8")
        except OSError as error:
            fail(f"cannot read TestFlight metadata for {locale}: {error}")
        if len(document.encode("utf-8")) > 4_000:
            fail(f"TestFlight metadata for {locale} exceeds the 4,000-byte limit")
        normalized_document = " ".join(document.split())
        missing = sorted(value for value in required_values if value not in normalized_document)
        if missing:
            fail(f"TestFlight metadata for {locale} omits required values: {missing}")
        forbidden = sorted(
            value for value in forbidden_values[locale] if value in normalized_document
        )
        if forbidden:
            fail(f"TestFlight metadata for {locale} retains legacy claims: {forbidden}")
        documents[locale] = document.strip()

    try:
        review_document = (
            repository_root / "docs/app-review-notes-native-webextensions.md"
        ).read_text(encoding="utf-8")
        expected_english = review_document.split("```text\n")[2].split("\n```", 1)[0].strip()
    except (OSError, IndexError) as error:
        fail(f"cannot compare TestFlight metadata with App Review notes: {error}")
    if documents["en-US"] != expected_english:
        fail("English TestFlight metadata differs from the reviewed What to Test template")


def verify_catalog_hashes(repository_root: Path) -> None:
    catalog_path = (
        repository_root /
        "firefox-ios/Floorp/NativeWebExtensions/FloorpNativeWebExtensionModels.swift"
    )
    try:
        catalog = catalog_path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read the native WebExtension catalog: {error}")
    for entry in EXPECTED:
        resource_name = Path(str(entry["archive"])).stem
        provenance = entry["provenance"]
        assert isinstance(provenance, dict)
        expected_hash = str(provenance["sha256"])
        catalog_item_pattern = re.compile(
            rf'resourceName:\s*"{re.escape(resource_name)}"\s*,\s*'
            rf'resourceExtension:\s*"zip"\s*,\s*'
            rf'expectedSHA256:\s*"([0-9a-f]{{64}})"'
        )
        match = catalog_item_pattern.search(catalog)
        if match is None:
            fail(f"native WebExtension catalog omits {resource_name}.zip")
        if match.group(1) != expected_hash:
            fail(
                f"native WebExtension catalog hash mismatch for {resource_name}.zip: "
                f"expected {expected_hash}, found {match.group(1)}"
            )


def verify_repository(repository_root: Path) -> None:
    repository_root = repository_root.resolve()
    bundle_root = repository_root / "firefox-ios/Floorp/NativeWebExtensions/Bundled"
    legacy_paths = (
        repository_root / "firefox-ios/Floorp/WebExtensions",
        repository_root / "scripts/webextensions",
    )
    for path in legacy_paths:
        if path.exists():
            fail(f"legacy WebExtension implementation remains: {path.relative_to(repository_root)}")

    if not bundle_root.is_dir():
        fail(f"missing bundled extension directory: {bundle_root.relative_to(repository_root)}")

    expected_files = {
        str(value[key])
        for value in EXPECTED
        for key in ("archive", "license_file", "provenance_file")
    }
    bundled_directory = PurePosixPath("firefox-ios/Floorp/NativeWebExtensions/Bundled")
    for entry in EXPECTED:
        support_files = entry.get("support_files", {})
        assert isinstance(support_files, dict)
        expected_files.update(
            path.name
            for relative_path in support_files
            if (path := PurePosixPath(str(relative_path))).parent == bundled_directory
        )
    actual_files = {path.name for path in bundle_root.iterdir() if path.is_file()}
    if actual_files != expected_files:
        fail(
            "bundled extension file set changed; "
            f"expected {sorted(expected_files)}, found {sorted(actual_files)}"
        )

    for entry in EXPECTED:
        verify_archive(entry, bundle_root, repository_root)
    verify_catalog_hashes(repository_root)
    verify_review_notes(repository_root)
    verify_testflight_metadata(repository_root)


def main() -> int:
    repository_root = Path(sys.argv[1]) if len(sys.argv) == 2 else DEFAULT_REPOSITORY_ROOT
    if len(sys.argv) > 2:
        fail("usage: verify_bundled_extensions.py [repository-root]")
    verify_repository(repository_root)
    print("Verified bundled native WebExtensions, provenance, licenses, and release metadata.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
