from __future__ import annotations

import copy
from collections.abc import Callable
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = Path(__file__).resolve().parents[1] / "verify_bundled_extensions.py"
SPEC = importlib.util.spec_from_file_location("verify_bundled_extensions", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class BundledNativeWebExtensionVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        source = REPOSITORY_ROOT / "firefox-ios/Floorp/NativeWebExtensions/Bundled"
        destination = self.root / "firefox-ios/Floorp/NativeWebExtensions/Bundled"
        destination.parent.mkdir(parents=True)
        shutil.copytree(source, destination)
        self.bundle_root = destination
        review_notes_source = REPOSITORY_ROOT / "docs/app-review-notes-native-webextensions.md"
        review_notes_destination = self.root / "docs/app-review-notes-native-webextensions.md"
        review_notes_destination.parent.mkdir(parents=True)
        shutil.copy2(review_notes_source, review_notes_destination)
        self.review_notes = review_notes_destination
        testflight_source = REPOSITORY_ROOT / "firefox-ios/TestFlight"
        testflight_destination = self.root / "firefox-ios/TestFlight"
        testflight_destination.mkdir(parents=True)
        for locale in ("en-US", "ja-JP"):
            shutil.copy2(
                testflight_source / f"WhatToTest.{locale}.txt",
                testflight_destination / f"WhatToTest.{locale}.txt",
            )
        self.testflight_root = testflight_destination
        scripts_destination = self.root / "scripts"
        scripts_destination.mkdir(parents=True)
        for script_name in ("package-darkreader-ios.sh", "package-ubol-ios.sh"):
            shutil.copy2(
                REPOSITORY_ROOT / "scripts" / script_name,
                scripts_destination / script_name,
            )
        self.dark_reader_build_script = scripts_destination / "package-darkreader-ios.sh"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_accepts_exact_bundled_release_assets(self) -> None:
        VERIFIER.verify_repository(self.root)

    def test_rejects_archive_digest_drift(self) -> None:
        archive = self.bundle_root / "darkreader-floorp-ios-mv3-4.9.129.zip"
        archive.write_bytes(archive.read_bytes() + b"drift")

        with self.assertRaisesRegex(RuntimeError, "unexpected SHA-256"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_derived_patch_drift(self) -> None:
        patch = self.bundle_root / "darkreader-floorp-ios-mv3-4.9.129.patch"
        patch.write_text(patch.read_text(encoding="utf-8") + "\n# drift\n", encoding="utf-8")

        with self.assertRaisesRegex(RuntimeError, "unexpected SHA-256 for support file"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_missing_derived_build_script(self) -> None:
        self.dark_reader_build_script.unlink()

        with self.assertRaisesRegex(RuntimeError, "missing bundled-extension support file"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_missing_license(self) -> None:
        (self.bundle_root / "uBOLite-floorp-ios-2026.825.1619.LICENSE").unlink()

        with self.assertRaisesRegex(RuntimeError, "bundled extension file set changed"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_unreviewed_extra_asset(self) -> None:
        (self.bundle_root / "unreviewed.zip").write_bytes(b"PK\x05\x06")

        with self.assertRaisesRegex(RuntimeError, "bundled extension file set changed"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_patch_backup_inside_archive(self) -> None:
        entry = self.rewrite_archive(
            "Dark Reader",
            lambda files: files.update({"manifest.json.orig": files["manifest.json"]}),
        )

        with self.assertRaisesRegex(RuntimeError, "unexpected patch artifact"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_static_action_popup_manifest_drift(self) -> None:
        entry = self.rewrite_archive(
            "Dark Reader",
            lambda files: self.update_manifest(
                files,
                lambda manifest: manifest["action"].update({"default_popup": "other.html"}),
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "unexpected static action popup"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_missing_static_action_popup_entry(self) -> None:
        entry = self.rewrite_archive(
            "Dark Reader",
            lambda files: files.pop("ui/popup/index.html"),
        )

        with self.assertRaisesRegex(RuntimeError, "invalid or missing static action popup"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_reserved_action_command(self) -> None:
        entry = self.rewrite_archive(
            "Dark Reader",
            lambda files: self.update_manifest(
                files,
                lambda manifest: manifest.setdefault("commands", {}).update({
                    "_execute_action": {"description": "unsafe native popup path"},
                }),
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "reserved action command"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_dynamic_popup_api_source(self) -> None:
        entry = self.rewrite_archive(
            "Dark Reader",
            lambda files: files.update({
                "dynamic-popup.js": b"browser.action.setPopup({ popup: 'other.html' });",
            }),
        )

        with self.assertRaisesRegex(RuntimeError, "unsupported dynamic popup API"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_readiness_origin_guard_drift(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/background.js",
                "sender?.origin?.toLowerCase() !== UBOL_ORIGIN",
                "isTrustedOrigin(sender) === false",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_conditional_wake_registration_reconciliation(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/background.js",
                "const reconcileResult = await reconcileSettingsState({",
                "if ( await browser.scripting.getRegisteredContentScripts().length === 0 ) {\n"
                "        const conditionalResult = await reconcileSettingsState({",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_broad_safari_storage_retry(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-compat.js",
                "/unknown error/i.test(message) === false",
                "/./.test(message) === false",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_destructive_safari_dnr_alias_conversion(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-compat.js",
                "structuredClone(addRules).filter(isSupportedRule)",
                "addRules.filter(isSupportedRule)",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_missing_safari_local_storage_bootstrap(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-compat.js",
                "webext.storage.local.set({ [safariLocalStorageSentinelKey]: true })",
                "Promise.resolve()",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_reading_before_safari_local_storage_bootstrap(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-compat.js",
                "if ( areaName === 'local' ) {\n"
                "                await ensureSafariLocalStorage();\n"
                "            }\n"
                "            return retrySafariStorageOperation(operation);",
                "const result = await retrySafariStorageOperation(operation);\n"
                "            if ( areaName === 'local' ) {\n"
                "                await ensureSafariLocalStorage();\n"
                "            }\n"
                "            return result;",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_exposing_safari_local_storage_sentinel(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext.js",
                "key => key !== safariLocalStorageSentinelKey",
                "key => key.length !== 0",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_safari_all_content_script_unregister(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "scripting.unregisterContentScripts({ ids: removeIds })",
                "scripting.unregisterContentScripts()",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_missing_existing_content_script_update(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "scripting.updateContentScripts(toUpdate)",
                "scripting.registerContentScripts(toUpdate)",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_case_sensitive_world_readback(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "details.world.toUpperCase()",
                "details.world",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_nondeterministic_content_script_ruleset_order(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "rulesetsDetails.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0)",
                "rulesetsDetails.sort((a, b) => a.id.localeCompare(b.id))",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_missing_safari_registration_sentinel(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "floorp-safari-registration-sentinel",
                "disabled-registration-row",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_missing_pre_mutation_sentinel_registration(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "await scripting.registerContentScripts([ sentinel ]);",
                "void sentinel;",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_seen_realms_storage_serialization_bypass(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-compat.js",
                "runStorageOperation('session', ( ) =>\n"
                "    webext.storage.session.get('safari.seenRealms')",
                "webext.storage.session.get('safari.seenRealms')",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_single_attempt_content_script_reconciliation(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "for ( let attempt = 1; attempt <= 3; attempt++ )",
                "for ( let attempt = 1; attempt <= 1; attempt++ )",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_missing_content_script_convergence_readback(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "if ( registrationMismatch(after, desired) )",
                "if ( false )",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_swallowed_final_safari_scripting_failure(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/scripting-manager.js",
                "if ( webextFlavor === 'safari' || throwOnError ) { throw reason; }",
                "if ( throwOnError ) { throw reason; }",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_report_route_without_source_window(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-utils.js",
                "...(Number.isInteger(windowId) ? { windowId } : {})",
                "",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_non_strict_default_mode_mutation(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/background.js",
                "setDefaultFilteringMode(request.level, true)",
                "setDefaultFilteringMode(request.level)",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_strict_block_failure_without_rollback(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/background.js",
                "strict-block rollback failed:",
                "strict-block recovery failed:",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_ui_treating_explicit_error_response_as_success(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext.js",
                "return assertSuccessfulMessageResponse(response);",
                "return response;",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_popup_failure_without_slider_rollback(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/popup.js",
                "setFilteringMode(beforeLevel);",
                "void beforeLevel;",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_deferred_popup_permission_request(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/popup.js",
                "permissionRequest = capturePopupRequest(permissionRequester([",
                "permissionRequest = Promise.resolve().then(( ) => permissionRequester([",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_popup_permission_request_without_hostname_guard(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/popup.js",
                "if ( targetHostname === '' ) { return Promise.resolve(false); }",
                "void targetHostname;",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_popup_permission_request_after_serialized_mutation(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.move_archive_text_after(
                files,
                "js/popup.js",
                "permissionRequest = capturePopupRequest(permissionRequester([",
                "return queuePopupMutation(( ) => commitFilteringModeNow(",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "orders compatibility code incorrectly"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_restore_failure_without_visible_abort(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/settings.js",
                "await restore(targetConfig);",
                "return restore(targetConfig);",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_restore_rollback_without_foreground_static_reconciliation(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/backup-restore.js",
                "rollback?.foregroundReconciliationRequired === true",
                "rollback?.foregroundReconciliationRequired === false",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_close_handshake_without_ruleset_readback(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/filter-lists.js",
                "Enabled rulesets did not match the requested selection",
                "Enabled rulesets accepted without confirmation",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_close_handshake_that_applies_an_unrendered_ruleset_dom(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/filter-lists.js",
                "if ( revision === 0 ) {",
                "if ( false ) {",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_close_handshake_with_inverted_beforeunload_guard(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/filter-lists.js",
                "if ( timer === undefined ) { return; }",
                "if ( timer !== undefined ) { return; }",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_missing_host_awaited_close_handshake(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/filter-lists.js",
                "self.floorpPrepareToClose = async ( ) => {",
                "self.floorpPrepareToClose = ( ) => {",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_unawaited_matched_rules_tab(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/background.js",
                "await browser.tabs.create({",
                "browser.tabs.create({",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_missing_matched_rules_window_target(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/background.js",
                "Number.isInteger(request.windowId)",
                "false",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_missing_background_rejection_reply(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/background.js",
                "ubolErr(`onMessage/${request.what}/${error}`)",
                "void error",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_startup_dnr_error_suppression(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ruleset-manager.js",
                "if ( throwOnError ) { throw reason; }",
                "if ( throwOnError ) { return false; }",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_realm_refresh_barrier_drift(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-compat.js",
                "await nativeDNR.updateEnabledRulesets",
                "nativeDNR.updateEnabledRulesets",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_realm_refresh_error_recovery_drift(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-compat.js",
                "realmRulesetUpdateError = undefined;",
                "void realmRulesetUpdateError;",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_ubol_startup_realm_failure_latch_drift(self) -> None:
        entry = self.rewrite_archive(
            "uBlock Origin Lite",
            lambda files: self.replace_archive_text(
                files,
                "js/ext-compat.js",
                "realmRulesetStartupError ??= reason;",
                "void reason;",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "omits required compatibility code"):
            VERIFIER.verify_archive(entry, self.bundle_root, self.root)

    def test_rejects_legacy_runtime_tree(self) -> None:
        (self.root / "firefox-ios/Floorp/WebExtensions").mkdir(parents=True)

        with self.assertRaisesRegex(RuntimeError, "legacy WebExtension implementation remains"):
            VERIFIER.verify_repository(self.root)

    @staticmethod
    def update_manifest(
        files: dict[str, bytes],
        update: Callable[[dict[str, object]], None],
    ) -> None:
        manifest = json.loads(files["manifest.json"])
        update(manifest)
        files["manifest.json"] = json.dumps(manifest, sort_keys=True).encode()

    @staticmethod
    def replace_archive_text(
        files: dict[str, bytes],
        path: str,
        before: str,
        after: str,
    ) -> None:
        source = files[path].decode("utf-8")
        if before not in source:
            raise AssertionError(f"missing fixture marker in {path}: {before}")
        files[path] = source.replace(before, after).encode("utf-8")

    @staticmethod
    def move_archive_text_after(
        files: dict[str, bytes],
        path: str,
        moving: str,
        anchor: str,
    ) -> None:
        source = files[path].decode("utf-8")
        if moving not in source or anchor not in source:
            raise AssertionError(f"missing fixture ordering marker in {path}")
        without_moving = source.replace(moving, "", 1)
        files[path] = without_moving.replace(
            anchor,
            anchor + moving,
            1,
        ).encode("utf-8")

    def rewrite_archive(
        self,
        display_name: str,
        update: Callable[[dict[str, bytes]], None],
    ) -> dict[str, object]:
        entry = copy.deepcopy(next(
            candidate
            for candidate in VERIFIER.EXPECTED
            if candidate["display_name"] == display_name
        ))
        archive = self.bundle_root / str(entry["archive"])
        with zipfile.ZipFile(archive) as package:
            files = {name: package.read(name) for name in package.namelist()}
        update(files)
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
            for name, data in files.items():
                package.writestr(name, data)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        provenance = entry["provenance"]
        provenance["sha256"] = digest
        provenance_path = self.bundle_root / str(entry["provenance_file"])
        provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
        return entry

    def test_rejects_review_notes_over_app_store_connect_limit(self) -> None:
        document = self.review_notes.read_text(encoding="utf-8")
        self.review_notes.write_text(
            document.replace("```text\n", "```text\n" + ("x" * 4_001), 1),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(RuntimeError, "4,000-byte limit"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_stale_testflight_metadata(self) -> None:
        metadata = self.testflight_root / "WhatToTest.en-US.txt"
        metadata.write_text(
            metadata.read_text(encoding="utf-8").replace("uBlock Origin Lite", "legacy extension"),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(RuntimeError, "omits required values"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_stale_japanese_testflight_claims(self) -> None:
        metadata = self.testflight_root / "WhatToTest.ja-JP.txt"
        metadata.write_text(
            metadata.read_text(encoding="utf-8")
            + "\n\n署名済み・アプリ同梱の拡張機能は Dark Reader 1件です。\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(RuntimeError, "retains legacy claims"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_stale_testflight_extension_versions(self) -> None:
        replacements = {
            "4.9.129": "4.9.128",
            "2026.825.1619": "2026.825.1618",
        }
        for locale in ("en-US", "ja-JP"):
            metadata = self.testflight_root / f"WhatToTest.{locale}.txt"
            document = metadata.read_text(encoding="utf-8")
            for current, stale in replacements.items():
                document = document.replace(current, stale)
            metadata.write_text(
                document,
                encoding="utf-8",
            )
        document = self.review_notes.read_text(encoding="utf-8")
        heading = "## Paste into TestFlight — What to Test"
        before, testflight_section = document.split(heading, 1)
        for current, stale in replacements.items():
            testflight_section = testflight_section.replace(current, stale, 1)
        self.review_notes.write_text(
            before + heading + testflight_section,
            encoding="utf-8",
        )

        with self.assertRaisesRegex(RuntimeError, "omits required values") as context:
            VERIFIER.verify_repository(self.root)
        self.assertIn("Dark Reader 4.9.129", str(context.exception))
        self.assertIn("uBlock Origin Lite 2026.825.1619", str(context.exception))

    def test_rejects_testflight_metadata_different_from_reviewed_template(self) -> None:
        metadata = self.testflight_root / "WhatToTest.en-US.txt"
        metadata.write_text(
            metadata.read_text(encoding="utf-8").replace("release candidate", "release test"),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(RuntimeError, "differs from the reviewed"):
            VERIFIER.verify_repository(self.root)


if __name__ == "__main__":
    unittest.main()
