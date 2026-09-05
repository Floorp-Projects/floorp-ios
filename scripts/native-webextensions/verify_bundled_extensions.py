#!/usr/bin/env python3

"""Fail closed when Floorp's bundled WKWebExtension assets drift."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
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
            "firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.patch": "41ce6decc01bef4998451567cb77f2876240dba7be55d23cc685275f1997e12e",
            "scripts/package-darkreader-ios.sh": "92a61a8d60dc13ce1058235e6cc686f323a60c18f4db2927cae5d67c0ff8caaa",
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
                    "description": "Send popup and options mutations with an explicit response callback, retain failures without unhandled rejections, remove the popup's independent storage read, and expose a native close-preparation handshake.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "ui/popup/index.js",
                },
                {
                    "description": "Keep options-page mutation messages alive through their durable background response and expose the same native close-preparation handshake.",
                    "patch": "darkreader-floorp-ios-mv3-4.9.129.patch",
                    "path": "ui/options/index.js",
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
            "sha256": "ebbb916a7b2bd8e3c5c6e538316fe3eea2e11875432522934f489697654cd761",
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
        "review_required_values": {
            "Floorp-derived",
            "background.service_worker",
            "background.scripts",
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
            "firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.patch": "5b82afeba920162a5bfa71501841ea642c82d442b6cbf2ebc7c66ed28ff7b5b6",
            "scripts/package-ubol-ios.sh": "f60cc1bca59e9894c24fa28345169ebfe9b5794a3bfde7aba0ea4e170dfc26b0",
        },
        "provenance": {
            "asset": "uBOLite-floorp-ios-2026.825.1619.zip",
            "buildScript": "scripts/package-ubol-ios.sh",
            "changes": [
                {
                    "description": "Declare WebKit's public declarativeNetRequestFeedback permission so uBO Lite's upstream Developer mode can expose its Matched rules diagnostics.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "path": "manifest.json",
                },
                {
                    "description": "Propagate the active tab's numeric logical window ID and incognito state when opening Matched rules and Report; adapt upstream Matched rules windows.create to an awaited active tabs.create in the source window; scope Report lookup, reuse, and creation to the same window and privacy realm; verify the created realm; and return explicit opened/error responses so WebKit does not strand popup message ports.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": ["js/background.js", "js/ext-utils.js", "js/popup.js"],
                },
                {
                    "description": "Serialize Safari local/session storage with bounded retries limited to WebKit unknown errors; create and retain a hidden local-storage sentinel before reads; make local configuration authoritative with revisioned exact readback; preserve caller DNR rule objects while cloning and converting Safari aliases; recover poisoned queues; order realm markers around verified native DNR mutations; and reject missing, malformed, or runtime-error DNR readbacks instead of treating them as empty success.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": [
                        "js/alarms.js",
                        "js/config.js",
                        "js/ext-compat.js",
                        "js/ext.js",
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
                    "description": "Protect settings restore/reset and custom-filter edits with snapshots, durable recovery journals, strict mutation responses, foreground-completed Safari static-ruleset rollback/readback, authoritative state rebroadcast across concurrent dashboards, and retryable queues; track delayed FileReader, editor, filter-list, and dashboard writes to a fixed point so a failed or interrupted operation cannot be reported as saved.",
                    "patch": "uBOLite-floorp-ios-2026.825.1619.patch",
                    "paths": [
                        "js/background.js",
                        "js/backup-restore.js",
                        "js/compiled-filters.js",
                        "js/develop.js",
                        "js/filter-lists.js",
                        "js/filter-manager-ui.js",
                        "js/filter-manager.js",
                        "js/imported-lists.js",
                        "js/rw-dnr-editor.js",
                        "js/settings.js",
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
            "sha256": "402934f1f49d0c83d3eec7fb1c4f421897cced7f0fe78e9745551f8ebb80a9a2",
            "sourceCommit": "080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b",
            "strictMinimumSafariVersion": "18.6",
            "upstreamAsset": "uBOLite_2026.825.1619.safari.zip",
            "upstreamDownloadURL": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.825.1619/uBOLite_2026.825.1619.safari.zip",
            "upstreamSHA256": "89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94",
        },
        "manifest": {
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
        "archive_text_requirements": {
            "js/popup.js": (
                "assertSuccessfulMessageResponse,",
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
            ),
            "js/settings.js": (
                "assertSuccessfulMessageResponse,",
                "export async function onFilteringModeChange(ev, messageSender = sendMessage)",
                "data.defaultFilteringMode = previousLevel;",
                "showRuntimeError(reason);",
                "export async function restoreSettingsFromObject(",
                "await restore(targetConfig);",
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
                "updateUserRules(throwOnError = false)",
                "if ( throwOnError ) { throw reason; }",
                "Enabled ruleset readback mismatch",
                "const RULESET_RECONCILIATION_KEY = 'floorp.rulesetReconciliation.v1';",
                "allowStaticMutation = true",
            ),
            "js/mode-manager.js": (
                "startupFresh = false",
                "await filteringModesToDNR(userModes, startupFresh)",
                "setFilteringModeDetails(details, throwOnDNRError = false)",
                "await filteringModesToDNR(unserializeModeDetails(data), throwOnDNRError)",
                "await saveRulesetConfig()",
            ),
            "js/ext-compat.js": (
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
                "            webext.storage.session.remove('safari.seenRealms')",
                "throwOnError = false",
                "if ( throwOnError ) { throw reason; }",
                "await nativeDNR.updateEnabledRulesets",
                "export function readNativeEnabledRulesets(",
                "Invalid enabled static DNR readback",
                "Realm static DNR refresh readback mismatch",
                "Static ruleset update readback mismatch",
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
                "structuredClone(addRules).filter(isSupportedRule)",
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
                "what: 'beginSettingsRestore'",
                "what: 'commitSettingsRestore'",
                "what: 'rollbackSettingsRestore'",
                "rollback?.foregroundReconciliationRequired === true",
                "const reconciliation = await reconcileProtection();",
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
        "review_required_values": {
            "Floorp-derived",
            "declarativeNetRequestFeedback",
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
    required_values = {"Dark Reader", "uBlock Origin Lite", "WKWebExtension"}
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
