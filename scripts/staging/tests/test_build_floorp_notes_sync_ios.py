"""Contract tests for the fail-closed Floorp Notes Sync build wrapper."""

import json
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[3]
SCRIPT = REPOSITORY / "scripts/staging/build-floorp-notes-sync-ios.sh"
SDK_GENERATOR = REPOSITORY / "firefox-ios/bin/sdk_generator.sh"
FIXTURES = REPOSITORY / "scripts/ci/fixtures"
SOURCE_SHA = json.loads(
    (FIXTURES / "floorp-notes-sync-g1-g5-valid.json").read_text()
)["release_inputs"]["ios"]["source_sha"]
EVIDENCE_BUILD_NUMBER = json.loads(
    (FIXTURES / "floorp-notes-sync-g1-g5-valid.json").read_text()
)["release_inputs"]["ios"]["build_number"]
SOURCE_TREE = "b" * 40
EXPECTED_HOSTS = [
    "accounts.firefox.com",
    "api.accounts.firefox.com",
    "event-sync.services.mozilla.com",
    "oauth.accounts.firefox.com",
    "profile.accounts.firefox.com",
    "static.accounts.firefox.com",
    "sync.services.mozilla.com",
    "token.services.mozilla.com",
]


class FloorpNotesSyncBuildContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repository = self.root / "source"
        self.bin = self.root / "bin"
        self.bin.mkdir(parents=True)
        self.fake_xcode_app = (self.root / "FakeXcode.app").resolve()
        self.fake_developer_dir = self.fake_xcode_app / "Contents/Developer"
        self._prepare_fake_toolchain()
        self._prepare_source_tree()
        self.run_index = 0

    def tearDown(self):
        self.temporary.cleanup()

    def prepare_local_source_evidence(self, mode="release-enabled"):
        fixture = (
            "floorp-notes-sync-g1-g4-production-qa-valid.json"
            if mode == "production-qa"
            else "floorp-notes-sync-g1-g5-valid.json"
        )
        evidence = json.loads((FIXTURES / fixture).read_text())
        directory = self.root / f"local-evidence-{self.run_index + 1}"
        artifacts = directory / "artifacts"
        result_bundle = artifacts / "FloorpNotesSync.xcresult"
        (result_bundle / "Data").mkdir(parents=True)
        metadata = b'{"status":"passed"}'
        metadata_path = artifacts / "task-manifest.json"
        metadata_path.write_bytes(metadata)
        (result_bundle / "Info.plist").write_bytes(
            b"<?xml version='1.0'?><plist version='1.0'><dict/></plist>"
        )
        (result_bundle / "Data/test-summary").write_bytes(
            b"synthetic-only test metadata"
        )
        directory_digest = self.local_xcresult_digest(result_bundle)
        evidence["gates"]["g2"]["artifact"] = {
            "sha256": "2" * 64,
            "sources": [
                {
                    "content_policy": "metadata-json",
                    "kind": "local-file",
                    "path": "artifacts/task-manifest.json",
                    "role": "task-manifest",
                    "sha256": hashlib.sha256(metadata).hexdigest(),
                }
            ],
        }
        evidence["gates"]["g3"]["artifact"] = {
            "sha256": "3" * 64,
            "sources": [
                {
                    "content_policy": "test-result-bundle",
                    "kind": "local-directory",
                    "path": "artifacts/FloorpNotesSync.xcresult",
                    "role": "xcresult",
                    "sha256": directory_digest,
                }
            ],
        }
        evidence_path = directory / "evidence.json"
        evidence_path.write_text(
            json.dumps(evidence, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        )
        return evidence_path, metadata_path, result_bundle

    @staticmethod
    def local_xcresult_digest(result_bundle):
        files = []
        for path in sorted(result_bundle.rglob("*")):
            if path.is_file():
                raw = path.read_bytes()
                files.append(
                    {
                        "path": path.relative_to(result_bundle).as_posix(),
                        "sha256": hashlib.sha256(raw).hexdigest(),
                        "size": len(raw),
                    }
                )
        return hashlib.sha256(
            json.dumps(
                {"files": files},
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode()
        ).hexdigest()

    def _prepare_source_tree(self):
        target = self.repository / "scripts/staging/build-floorp-notes-sync-ios.sh"
        target.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, target)
        wrapper = target.read_text()
        replacements = {
            'GIT_BIN="/usr/bin/git"': f'GIT_BIN="{self.bin / "git"}"',
            'XCODE_SELECT_BIN="/usr/bin/xcode-select"': (
                f'XCODE_SELECT_BIN="{self.bin / "xcode-select"}"'
            ),
            'CODESIGN_BIN="/usr/bin/codesign"': (
                f'CODESIGN_BIN="{self.bin / "codesign"}"'
            ),
            'SECURITY_BIN="/usr/bin/security"': (
                f'SECURITY_BIN="{self.bin / "security"}"'
            ),
            'SPCTL_BIN="/usr/sbin/spctl"': f'SPCTL_BIN="{self.bin / "spctl"}"',
        }
        for production_value, test_value in replacements.items():
            self.assertEqual(wrapper.count(production_value), 1)
            wrapper = wrapper.replace(production_value, test_value)
        production_environment = (
            '    DEVELOPER_DIR="$SELECTED_DEVELOPER" \\\n'
            '    "$XCODEBUILD_BIN" "${XCODE_ARGS[@]}"'
        )
        test_environment = (
            '    DEVELOPER_DIR="$SELECTED_DEVELOPER" \\\n'
            '    FAKE_XCODE_RECORD="${FAKE_XCODE_RECORD:-}" \\\n'
            '    FAKE_XCODE_EXIT="${FAKE_XCODE_EXIT:-0}" \\\n'
            '    FAKE_GATE_MISMATCH="${FAKE_GATE_MISMATCH:-0}" \\\n'
            '    FAKE_BUILD_NUMBER="${FAKE_BUILD_NUMBER:-}" \\\n'
            '    FAKE_MUTATE_CONTRACT_SNAPSHOT="${FAKE_MUTATE_CONTRACT_SNAPSHOT:-0}" \\\n'
            '    FAKE_MUTATE_GENERATED_MANIFEST="${FAKE_MUTATE_GENERATED_MANIFEST:-0}" \\\n'
            '    FAKE_MUTATE_GENERATED_SOURCE="${FAKE_MUTATE_GENERATED_SOURCE:-0}" \\\n'
            '    FAKE_MUTATE_LOCAL_SNAPSHOT="${FAKE_MUTATE_LOCAL_SNAPSHOT:-0}" \\\n'
            '    FAKE_G6_EMBEDDING="${FAKE_G6_EMBEDDING:-}" \\\n'
            '    FAKE_SIGNING_MODE="${FAKE_SIGNING_MODE:-valid}" \\\n'
            '    "$XCODEBUILD_BIN" "${XCODE_ARGS[@]}"'
        )
        self.assertEqual(wrapper.count(production_environment), 1)
        target.write_text(wrapper.replace(production_environment, test_environment))

        preparer_source = (
            REPOSITORY / "scripts/staging/prepare-floorp-ios-source-snapshot.py"
        )
        preparer = (
            self.repository / "scripts/staging/prepare-floorp-ios-source-snapshot.py"
        )
        shutil.copy2(preparer_source, preparer)
        preparer_text = preparer.read_text()
        production_node_directory = 'NODE_BIN_DIR = Path("/opt/homebrew/bin")'
        self.assertEqual(preparer_text.count(production_node_directory), 1)
        preparer.write_text(
            preparer_text.replace(
                production_node_directory,
                f"NODE_BIN_DIR = Path({str(self.bin)!r})",
            )
        )

        bootstrap = self.repository / "bootstrap.sh"
        bootstrap.write_text(
            textwrap.dedent(
                """\
                #!/bin/bash
                set -euo pipefail
                [[ "${1:-}" == "firefox" ]]
                [[ "${CI:-}" == "true" ]]
                root="$(cd "$(dirname "$0")" && pwd)"
                assets="$root/firefox-ios/Client/Assets"
                mkdir -p "$assets" "$root/firefox-ios/Client/Generated/Metrics"
                for name in \
                    AddressFormManager.js \
                    AllFramesAtDocumentEnd.js \
                    AllFramesAtDocumentStart.js \
                    AutofillAllFramesAtDocumentStart.js \
                    MainFrameAtDocumentEnd.js \
                    MainFrameAtDocumentStart.js \
                    NightModeAllFramesAtDocumentStart.js \
                    TranslationsEngine.js \
                    WebcompatAllFramesAtDocumentStart.js \
                    translations-engine.worker.js; do
                    printf 'generated %s\\n' "$name" > "$assets/$name"
                done
                printf 'client glean metrics\\n' > \
                    "$root/firefox-ios/Client/Generated/Metrics/Metrics.swift"
                cat > "$root/firefox-ios/bin/nimbus-fml.sh" <<'NIMBUS'
                #!/bin/bash
                set -euo pipefail
                mkdir -p "$SOURCE_ROOT/Client/Generated"
                printf 'nimbus features\\n' > "$SOURCE_ROOT/Client/Generated/FxNimbus.swift"
                printf 'nimbus messaging\\n' > "$SOURCE_ROOT/Client/Generated/FxNimbusMessaging.swift"
                NIMBUS
                chmod 0755 "$root/firefox-ios/bin/nimbus-fml.sh"
                """
            )
        )
        bootstrap.chmod(0o755)

        sdk_generator = self.repository / "firefox-ios/bin/sdk_generator.sh"
        sdk_generator.parent.mkdir(parents=True, exist_ok=True)
        sdk_generator.write_text(
            textwrap.dedent(
                """\
                #!/bin/bash
                set -euo pipefail
                output=""
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        -o|--output) output="$2"; shift 2 ;;
                        -g|--glean-namespace) shift 2 ;;
                        *) shift ;;
                    esac
                done
                [[ -n "$output" ]]
                mkdir -p "$output" "$FLOORP_GLEAN_VENV/bin"
                printf 'storage glean metrics\\n' > "$output/Metrics.swift"
                cat > "$FLOORP_GLEAN_VENV/bin/python" <<'PYTHON'
                #!/usr/bin/python3
                import sys
                if sys.argv[1:] == ["--version"]:
                    print("Python 3.12.0")
                elif "pip" in sys.argv[1:] and "freeze" in sys.argv[1:]:
                    print("glean-parser==20.0")
                    print("pip==24.0")
                elif "importlib.metadata" in " ".join(sys.argv[1:]):
                    print("20.0")
                PYTHON
                chmod 0755 "$FLOORP_GLEAN_VENV/bin/python"
                """
            )
        )
        sdk_generator.chmod(0o755)

        validator = self.repository / "scripts/ci/validate-floorp-notes-sync-release.py"
        validator.parent.mkdir(parents=True)
        validator.write_text(textwrap.dedent("""\
            import json, os, pathlib, sys
            with open(os.environ["FAKE_VALIDATOR_RECORD"], "a") as handle:
                handle.write(json.dumps(sys.argv[1:]) + "\\n")
            for raw_path in json.loads(os.environ.get("FAKE_REPLACE_SOURCE_INPUTS", "[]")):
                pathlib.Path(raw_path).write_text('{"source":"replaced-after-snapshot"}\\n')
            if os.environ.get("FAKE_MUTATE_FINAL_VALIDATION") == "1":
                evidence = pathlib.Path(sys.argv[sys.argv.index("--evidence") + 1])
                if "publication-inputs" in evidence.parts:
                    evidence.write_text('{"publication":"mutated"}\\n')
            if os.environ.get("FAKE_MUTATE_FINAL_LOCAL_SOURCE") == "1":
                evidence = pathlib.Path(sys.argv[sys.argv.index("--evidence") + 1])
                if "publication-inputs" in evidence.parts:
                    payload = json.loads(evidence.read_text())
                    for gate in payload["gates"].values():
                        for source in gate.get("artifact", {}).get("sources", []):
                            if source.get("kind") == "local-file":
                                (evidence.parent / source["path"]).write_text(
                                    '{"publication-local":"mutated"}\\n'
                                )
                                raise SystemExit(0)
            if os.environ.get("FAKE_MUTATE_APP_AFTER_FINAL_VALIDATION") == "1":
                evidence = pathlib.Path(sys.argv[sys.argv.index("--evidence") + 1])
                if "publication-inputs" in evidence.parts:
                    app_binary = pathlib.Path(os.environ["FAKE_APP_TO_MUTATE"])
                    app_binary.write_bytes(app_binary.read_bytes() + b"mutated")
            raise SystemExit(int(os.environ.get("FAKE_VALIDATOR_EXIT", "0")))
        """))

        clock_client = self.repository / "scripts/ci/create-floorp-validation-clock.sh"
        clock_client.write_text(textwrap.dedent("""\
            #!/usr/bin/python3
            import argparse, json, os, pathlib, sys
            parser = argparse.ArgumentParser()
            parser.add_argument("--repository")
            parser.add_argument("--workflow")
            parser.add_argument("--expected-head")
            parser.add_argument("--max-age-seconds")
            parser.add_argument("--output", type=pathlib.Path)
            arguments = parser.parse_args()
            pathlib.Path(os.environ["FAKE_CLOCK_RECORD"]).write_text(
                json.dumps(sys.argv[1:]) + "\\n"
            )
            source = pathlib.Path(os.environ["FAKE_CLOCK_SOURCE"])
            with arguments.output.open("xb") as handle:
                handle.write(source.read_bytes())
        """))
        clock_client.chmod(0o755)

        docs = self.repository / "docs"
        docs.mkdir()
        shutil.copy2(REPOSITORY / "docs/floorp-release-endpoints.json", docs)
        (docs / "floorp-notes-sync-release-evidence.schema.json").write_text("{}\n")
        release_configuration = self.repository / (
            "firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
        )
        release_configuration.parent.mkdir(parents=True)
        release_configuration.write_text("FLOORP_BUILD_NUMBER = 4\n")
        merge_fixture = self.repository / (
            "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json"
        )
        merge_fixture.parent.mkdir(parents=True)
        shutil.copy2(
            REPOSITORY / "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
            merge_fixture,
        )

        pin_path = self.repository / "MozillaRustComponents/FloorpApplicationServicesPin.json"
        pin_path.parent.mkdir()
        shutil.copy2(
            REPOSITORY / "MozillaRustComponents/FloorpApplicationServicesPin.json",
            pin_path,
        )
        generated = self.repository / (
            "MozillaRustComponents/Sources/MozillaRustComponentsWrapper/Generated/"
            "floorp_prefs_sync.swift"
        )
        generated.parent.mkdir(parents=True)
        generated.write_text("// generated test binding\n")

        entitlements = self.repository / (
            "firefox-ios/Client/Entitlements/FloorpReleaseApplication.entitlements"
        )
        entitlements.parent.mkdir(parents=True)
        with entitlements.open("wb") as handle:
            plistlib.dump(
                {
                    "com.apple.developer.networking.multipath": True,
                    "com.apple.security.application-groups": [
                        "$(FLOORP_APP_GROUP_IDENTIFIER)"
                    ],
                    "keychain-access-groups": ["$(AppIdentifierPrefix)app.floorp.Floorp"],
                },
                handle,
            )
        (self.repository / "firefox-ios/Client.xcodeproj").mkdir(parents=True)

    def _prepare_fake_toolchain(self):
        node = self.bin / "node"
        node.write_text("#!/bin/sh\nprintf 'v22.14.0\\n'\n")
        node.chmod(0o755)
        npm = self.bin / "npm"
        npm.write_text("#!/bin/sh\nprintf '10.9.2\\n'\n")
        npm.chmod(0o755)

        git = self.bin / "git"
        git.write_text(textwrap.dedent("""\
            #!/usr/bin/python3
            import os, pathlib, sys, tarfile
            args = sys.argv[1:]
            if "rev-parse" in args:
                value = args[args.index("rev-parse") + 1]
                print(os.environ["FAKE_GIT_TREE"] if value == "HEAD^{tree}" else os.environ["FAKE_GIT_HEAD"])
                raise SystemExit(0)
            if "status" in args:
                counter = pathlib.Path(os.environ["FAKE_GIT_STATUS_COUNTER"])
                count = int(counter.read_text()) if counter.exists() else 0
                counter.write_text(str(count + 1))
                if os.environ.get("FAKE_GIT_DIRTY") == "1" or (
                    os.environ.get("FAKE_GIT_MUTATE") == "1" and count > 0
                ):
                    print(" M unexpected-source-change")
                raise SystemExit(0)
            if "archive" in args:
                output_argument = next(value for value in args if value.startswith("--output="))
                output = pathlib.Path(output_argument.split("=", 1)[1])
                source = pathlib.Path(os.environ["FAKE_SOURCE_ROOT"])
                with tarfile.open(output, "w", format=tarfile.PAX_FORMAT) as archive:
                    for path in sorted(source.rglob("*")):
                        archive.add(path, arcname=path.relative_to(source), recursive=False)
                raise SystemExit(0)
            if args == ["get-tar-commit-id"]:
                print(os.environ["FAKE_GIT_HEAD"])
                raise SystemExit(0)
            raise SystemExit("unsupported fake git invocation: " + repr(args))
        """))
        git.chmod(0o755)

        xcode_select = self.bin / "xcode-select"
        xcode_select.write_text(textwrap.dedent(f"""\
            #!/usr/bin/python3
            import sys
            if sys.argv[1:] != ["-p"]:
                raise SystemExit("unexpected xcode-select arguments")
            print({str(self.fake_developer_dir)!r})
        """))
        xcode_select.chmod(0o755)

        xcodebuild = self.fake_developer_dir / "usr/bin/xcodebuild"
        xcodebuild.parent.mkdir(parents=True)
        xcodebuild.write_text(textwrap.dedent("""\
            #!/usr/bin/python3
            import datetime, json, os, pathlib, plistlib, shutil, sys
            args = sys.argv[1:]
            if args == ["-version"]:
                print("Xcode 26.0")
                print("Build version 17A100")
                raise SystemExit(0)
            with open(os.environ["FAKE_XCODE_RECORD"], "a") as handle:
                handle.write(json.dumps(args) + "\\n")
            if int(os.environ.get("FAKE_XCODE_EXIT", "0")):
                raise SystemExit(int(os.environ["FAKE_XCODE_EXIT"]))
            overlay = pathlib.Path(args[args.index("-xcconfig") + 1])
            settings = {}
            for line in overlay.read_text().splitlines():
                if "=" in line and not line.lstrip().startswith("//"):
                    key, value = line.split("=", 1)
                    settings[key.strip()] = value.strip().replace("\\\\ ", " ")
            if args[0] == "archive":
                archive = pathlib.Path(args[args.index("-archivePath") + 1])
                app = archive / "Products/Applications/Client.app"
            else:
                derived = pathlib.Path(args[args.index("-derivedDataPath") + 1])
                app = derived / "Build/Products/FloorpRelease-iphonesimulator/Client.app"
            app.mkdir(parents=True)
            generated_manifest = pathlib.Path(
                next(
                    argument.split("=", 1)[1]
                    for argument in args
                    if argument.startswith("FLOORP_GENERATED_SOURCE_MANIFEST=")
                )
            )
            if os.environ.get("FAKE_MUTATE_GENERATED_MANIFEST") == "1":
                generated_manifest.write_text('{"mutated":true}')
            if os.environ.get("FAKE_MUTATE_GENERATED_SOURCE") == "1":
                project = pathlib.Path(args[args.index("-project") + 1])
                generated_source = (
                    project.parent.parent
                    / "firefox-ios/Client/Generated/FxNimbus.swift"
                )
                generated_source.chmod(generated_source.stat().st_mode | 0o200)
                generated_source.write_text("mutated during build\\n")
            effective = settings["FLOORP_NOTES_SYNC_EFFECTIVE"]
            if os.environ.get("FAKE_GATE_MISMATCH") == "1":
                effective = "NO" if effective == "YES" else "YES"
            digest = settings.get("FLOORP_NOTES_SYNC_EVIDENCE_DIGEST", "")
            evidence = settings.get("FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE", "")
            if evidence:
                evidence_build_number = str(
                    json.loads(pathlib.Path(evidence).read_text())["release_inputs"]["ios"]["build_number"]
                )
            else:
                evidence_build_number = "4"
            build_number = os.environ.get("FAKE_BUILD_NUMBER") or evidence_build_number
            info = {
                "CFBundleExecutable": "Client",
                "CFBundleIdentifier": "app.floorp.Floorp",
                "CFBundleName": "Floorp",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.2.0",
                "CFBundleVersion": build_number,
                "MozFloorpNotesSyncBuildMode": settings["FLOORP_NOTES_SYNC_BUILD_MODE"],
                "MozFloorpNotesSyncSourceSHA": settings["FLOORP_NOTES_SYNC_SOURCE_SHA"],
                "MozFloorpNotesSyncRequested": settings["FLOORP_NOTES_SYNC_REQUESTED"],
                "MozAllowFloorpNotesSync": effective,
                "MozFloorpNotesSyncRegistrationAllowed": effective,
                "MozFloorpNotesSyncEngineRequestsAllowed": effective,
                "MozFloorpNotesSyncUIExposureAllowed": effective,
                "MozFloorpNotesSyncEndpointAuthority": "production",
                "MozFloorpNotesSyncProtocol": "sync15",
                "MozFloorpNotesSyncEndpointMatrixSHA256": settings["FLOORP_NOTES_SYNC_ENDPOINT_MATRIX_SHA256"],
                "MozFloorpNotesSyncEvidenceDigest": digest,
                "MozFloorpNotesSyncEvidenceResourceSHA256": settings.get(
                    "FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE_SHA256", ""
                ),
            }
            if os.environ.get("FAKE_G6_EMBEDDING") == "plist":
                info["MozFloorpNotesSyncG6Approvals"] = "forbidden"
            with (app / "Info.plist").open("wb") as handle:
                plistlib.dump(info, handle)
            if os.environ.get("FAKE_G6_EMBEDDING") == "resource":
                (app / "G6Approvals.json").write_text('{"forbidden":true}')
            executable = app / "Client"
            shutil.copyfile("/usr/bin/true", executable)
            executable.chmod(0o755)
            framework = app / "Frameworks/MozillaRustComponents.framework"
            framework.mkdir(parents=True)
            framework_binary = framework / "MozillaRustComponents"
            shutil.copyfile("/usr/bin/true", framework_binary)
            framework_binary.chmod(0o755)
            with (framework / "Info.plist").open("wb") as handle:
                plistlib.dump(
                    {
                        "CFBundleExecutable": "MozillaRustComponents",
                        "CFBundleIdentifier": "test.MozillaRustComponents",
                        "CFBundleName": "MozillaRustComponents",
                        "CFBundlePackageType": "FMWK",
                        "CFBundleVersion": "1",
                    },
                    handle,
                )
            if evidence:
                shutil.copy2(evidence, app / "FloorpNotesSyncReleaseEvidence.json")
            if os.environ.get("FAKE_MUTATE_CONTRACT_SNAPSHOT") == "1" and evidence:
                pathlib.Path(evidence).write_text('{"snapshot":"mutated-during-build"}\\n')
            if os.environ.get("FAKE_MUTATE_LOCAL_SNAPSHOT") == "1" and evidence:
                payload = json.loads(pathlib.Path(evidence).read_text())
                for gate in payload["gates"].values():
                    for source in gate.get("artifact", {}).get("sources", []):
                        if source.get("kind") == "local-file":
                            target = pathlib.Path(evidence).parent / source["path"]
                            if target.is_file():
                                target.write_text('{"local":"mutated-during-build"}\\n')
                                break
            signing_requested = args[0] == "archive" and "CODE_SIGNING_ALLOWED=NO" not in args
            signing_mode = os.environ.get("FAKE_SIGNING_MODE", "valid")
            if signing_requested and signing_mode != "missing":
                team = "BADTEAM123" if signing_mode == "bad-team" else "DV2U35YBHT"
                app_group = "group.app.floorp.Floorp.DV2U35YBHT"
                keychain = "DV2U35YBHT.app.floorp.Floorp"
                if signing_mode == "bad-app-group":
                    app_group = "group.invalid"
                if signing_mode == "bad-keychain":
                    keychain = "DV2U35YBHT.invalid"
                signed_entitlements = app.parent / "fake-signed-entitlements.plist"
                with signed_entitlements.open("wb") as handle:
                    entitlements = {}
                    if signing_mode != "empty-entitlements":
                        entitlements = {
                            "application-identifier": f"{team}.app.floorp.Floorp",
                            "com.apple.developer.team-identifier": team,
                            "com.apple.developer.networking.multipath": True,
                            "com.apple.security.application-groups": [app_group],
                            "keychain-access-groups": [keychain],
                        }
                        if signing_mode == "unexpected-entitlement":
                            entitlements["com.apple.developer.healthkit"] = True
                        if signing_mode == "get-task-allow":
                            entitlements["get-task-allow"] = True
                    plistlib.dump(entitlements, handle)
                profile_team = "BADTEAM123" if signing_mode == "profile-bad-team" else "DV2U35YBHT"
                profile_app_id = f"{profile_team}.app.floorp.Floorp"
                if signing_mode == "profile-bad-app-id":
                    profile_app_id = f"{profile_team}.invalid"
                expiration = datetime.datetime(2027, 8, 10, tzinfo=datetime.timezone.utc)
                if signing_mode == "profile-expired":
                    expiration = datetime.datetime(2026, 8, 9, tzinfo=datetime.timezone.utc)
                profile_entitlements = {
                    "application-identifier": profile_app_id,
                    "com.apple.developer.networking.multipath": True,
                    "com.apple.developer.team-identifier": profile_team,
                    "com.apple.security.application-groups": [
                        "group.app.floorp.Floorp.DV2U35YBHT"
                    ],
                    "get-task-allow": signing_mode == "profile-development",
                    "keychain-access-groups": [
                        "DV2U35YBHT.app.floorp.Floorp"
                    ],
                }
                profile = {
                    "ApplicationIdentifierPrefix": [profile_team],
                    "CreationDate": datetime.datetime(
                        2026, 8, 1, tzinfo=datetime.timezone.utc
                    ),
                    "DeveloperCertificates": [
                        b"wrong-certificate"
                        if signing_mode == "profile-bad-certificate"
                        else b"fixture-distribution-certificate"
                    ],
                    "Entitlements": profile_entitlements,
                    "ExpirationDate": expiration,
                    "Name": "Floorp App Store Fixture",
                    "TeamIdentifier": [profile_team],
                    "UUID": "11111111-2222-3333-4444-555555555555",
                }
                with (app / "embedded.mobileprovision").open("wb") as handle:
                    plistlib.dump(profile, handle)
        """))
        xcodebuild.write_text(
            xcodebuild.read_text().replace("#!/usr/bin/python3", f"#!{sys.executable}", 1)
        )
        xcodebuild.chmod(0o755)

        codesign = self.bin / "codesign"
        codesign.write_text(textwrap.dedent(f"""\
            #!/usr/bin/python3
            import os, pathlib, sys

            args = sys.argv[1:]
            target = pathlib.Path(args[-1]) if args else pathlib.Path()
            signing_mode = os.environ.get("FAKE_SIGNING_MODE", "valid")
            xcode_signature_mode = os.environ.get("FAKE_XCODE_SIGNATURE_MODE", "valid")
            if "--verify" in args:
                if target.name == "Client.app" and signing_mode == "missing":
                    raise SystemExit(1)
                raise SystemExit(0)
            if "--extract-certificates" in args:
                pathlib.Path("codesign0").write_bytes(b"fixture-distribution-certificate")
                raise SystemExit(0)
            if "--entitlements" in args:
                entitlements = target.parent / "fake-signed-entitlements.plist"
                if not entitlements.is_file():
                    raise SystemExit(1)
                sys.stdout.buffer.write(entitlements.read_bytes())
                raise SystemExit(0)
            if "--verbose=4" in args:
                if target == pathlib.Path({str(self.fake_xcode_app)!r}):
                    if xcode_signature_mode == "adhoc":
                        lines = [
                            "Identifier=com.apple.dt.Xcode",
                            "Signature=adhoc",
                            "TeamIdentifier=not set",
                        ]
                    else:
                        xcode_team = (
                            "BADTEAM123"
                            if xcode_signature_mode == "bad-team"
                            else "59GAB85EFG"
                        )
                        lines = [
                            "Identifier=com.apple.dt.Xcode",
                            "Authority=Apple Mac OS Application Signing",
                            "Authority=Apple Worldwide Developer Relations Certification Authority",
                            "Authority=Apple Root CA",
                            f"TeamIdentifier={{xcode_team}}",
                            "CDHash=1111111111111111111111111111111111111111",
                        ]
                elif target.name == "xcodebuild":
                    lines = [
                        "Identifier=com.apple.dt.xcodebuild",
                        "Authority=Software Signing",
                        "Authority=Apple Code Signing Certification Authority",
                        "Authority=Apple Root CA",
                        "TeamIdentifier=59GAB85EFG",
                        "CDHash=2222222222222222222222222222222222222222",
                    ]
                elif signing_mode == "adhoc":
                    lines = [
                        "Identifier=app.floorp.Floorp",
                        "Signature=adhoc",
                        "TeamIdentifier=not set",
                    ]
                else:
                    team = "BADTEAM123" if signing_mode == "bad-team" else "DV2U35YBHT"
                    authority = (
                        "Apple Development: Test User (DV2U35YBHT)"
                        if signing_mode == "bad-authority"
                        else f"Apple Distribution: Floorp Projects Inc. ({{team}})"
                    )
                    lines = [
                        "Identifier=app.floorp.Floorp",
                        f"Authority={{authority}}",
                        "Authority=Apple Worldwide Developer Relations Certification Authority",
                        "Authority=Apple Root CA",
                        f"TeamIdentifier={{team}}",
                    ]
                print("\\n".join(lines), file=sys.stderr)
                raise SystemExit(0)
            raise SystemExit("unexpected fake codesign invocation: " + repr(args))
        """))
        codesign.chmod(0o755)

        security = self.bin / "security"
        security.write_text(textwrap.dedent("""\
            #!/usr/bin/python3
            import os, pathlib, sys
            args = sys.argv[1:]
            if args[:2] == ["cms", "-D"] and "-i" in args:
                profile = pathlib.Path(args[args.index("-i") + 1])
                sys.stdout.buffer.write(profile.read_bytes())
                raise SystemExit(0)
            if args and args[0] == "verify-cert":
                raise SystemExit(
                    1 if os.environ.get("FAKE_SIGNING_MODE") == "certificate-untrusted" else 0
                )
            raise SystemExit("unexpected fake security invocation: " + repr(args))
        """))
        security.chmod(0o755)

        spctl = self.bin / "spctl"
        spctl.write_text("#!/bin/sh\necho \"$4: accepted\"\necho 'source=Mac App Store'\n")
        spctl.chmod(0o755)

        gh = self.bin / "gh"
        gh.write_text("#!/bin/sh\nexit 0\n")
        gh.chmod(0o755)

    def run_script(
        self,
        mode="release-disabled",
        *,
        extra=None,
        env=None,
        omit=None,
        manifest_path=None,
    ):
        self.run_index += 1
        output = self.root / f"output-{self.run_index}"
        manifest = manifest_path or output / "build-manifest.json"
        validator_record = self.root / f"validator-{self.run_index}.jsonl"
        xcode_record = self.root / f"xcode-{self.run_index}.jsonl"
        self.last_clock_record = self.root / f"clock-{self.run_index}.jsonl"
        status_counter = self.root / f"git-status-{self.run_index}.txt"
        arguments = [
            "/bin/bash",
            "-p",
            str(self.repository / "scripts/staging/build-floorp-notes-sync-ios.sh"),
            "--mode",
            mode,
            "--source-sha",
            SOURCE_SHA,
            "--output-dir",
            str(output),
            "--manifest",
            str(manifest),
        ]
        if mode == "production-qa":
            arguments += [
                "--evidence",
                str(FIXTURES / "floorp-notes-sync-g1-g4-production-qa-valid.json"),
                "--validation-clock-manifest",
                str(FIXTURES / "validation-clock-valid.json"),
            ]
        elif mode == "release-enabled":
            arguments += [
                "--evidence",
                str(FIXTURES / "floorp-notes-sync-g1-g5-valid.json"),
                "--validation-clock-manifest",
                str(FIXTURES / "validation-clock-valid.json"),
            ]
        for flag in omit or []:
            index = arguments.index(flag)
            del arguments[index : index + 2]
        arguments += extra or []
        process_env = os.environ.copy()
        process_env.update(
            {
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "FAKE_GIT_HEAD": SOURCE_SHA,
                "FAKE_GIT_TREE": SOURCE_TREE,
                "FAKE_GIT_STATUS_COUNTER": str(status_counter),
                "FAKE_SOURCE_ROOT": str(self.repository),
                "FAKE_CLOCK_SOURCE": str(FIXTURES / "validation-clock-valid.json"),
                "FAKE_CLOCK_RECORD": str(self.last_clock_record),
                "FAKE_VALIDATOR_RECORD": str(validator_record),
                "FAKE_XCODE_RECORD": str(xcode_record),
            }
        )
        process_env.update(env or {})
        result = subprocess.run(arguments, capture_output=True, text=True, env=process_env)
        return result, manifest, validator_record, xcode_record, output

    def test_release_disabled_has_no_evidence_and_all_runtime_paths_are_false(self):
        result, manifest_path, validator_record, xcode_record, _ = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(validator_record.exists())
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["mode"], "release-disabled")
        self.assertEqual(manifest["build"]["configuration"], "FloorpRelease")
        self.assertIsNone(manifest["paths"]["archive"])
        self.assertTrue(Path(manifest["paths"]["app"]).is_absolute())
        self.assertEqual(
            manifest["gate"],
            {"requested": False, "effective": False},
        )
        self.assertEqual(
            manifest["runtime_contract"],
            {
                "engine_registration_allowed": False,
                "engine_requests_allowed": False,
                "ui_exposure_allowed": False,
            },
        )
        self.assertIsNone(manifest["evidence"]["embedded_digest_sha256"])
        xcode_args = json.loads(xcode_record.read_text().splitlines()[0])
        self.assertEqual(xcode_args[0], "build")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", xcode_args)

    def test_release_disabled_does_not_require_validator_or_schema(self):
        (self.repository / "scripts/ci/validate-floorp-notes-sync-release.py").unlink()
        (self.repository / "docs/floorp-notes-sync-release-evidence.schema.json").unlink()
        result, manifest_path, validator_record, _, _ = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(manifest_path.is_file())
        self.assertFalse(validator_record.exists())

    def test_production_qa_validates_g1_g4_and_hardcodes_production_authority(self):
        result, manifest_path, validator_record, xcode_record, _ = self.run_script("production-qa")
        self.assertEqual(result.returncode, 0, result.stderr)
        validator_args = json.loads(validator_record.read_text().splitlines()[0])
        self.assertEqual(
            [validator_args[index] for index in range(0, len(validator_args), 2)],
            ["--schema", "--evidence", "--validation-clock-manifest", "--canonicalization"],
        )
        self.assertEqual(validator_args[-1], "rfc8785-jcs")
        for path in (validator_args[1], validator_args[3], validator_args[5]):
            self.assertIn("contract-inputs", path)
            self.assertFalse(path.startswith(str(FIXTURES)))
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["gate"], {"requested": True, "effective": True})
        self.assertEqual(manifest["endpoint_authority"]["fxa_server"], "FxAConfig.Server.release")
        self.assertEqual(manifest["endpoint_authority"]["wire_protocol"], "sync15")
        self.assertEqual(manifest["endpoint_authority"]["hosts"], EXPECTED_HOSTS)
        self.assertEqual(manifest["evidence"]["clock_run_id"], 987654321)
        self.assertRegex(manifest["evidence"]["clock_manifest_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(
            manifest["evidence"]["embedded_digest_sha256"],
            "20f348e1a932d78a407b08208153450b8e5961e97428a66bb9fd7dcc693a67b3",
        )
        self.assertRegex(manifest["endpoint_authority"]["matrix_sha256"], r"^[0-9a-f]{64}$")
        self.assertFalse(str(manifest["contract_inputs"]["xcconfig_path"]).startswith(str(self.repository)))
        self.assertFalse(str(manifest["contract_inputs"]["evidence_resource_path"]).startswith(str(self.repository)))
        xcode_args = json.loads(xcode_record.read_text().splitlines()[0])
        self.assertEqual(xcode_args[0], "build")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", xcode_args)

    def test_enabled_build_revalidates_after_xcodebuild(self):
        result, manifest_path, validator_record, _, output = self.run_script(
            "production-qa"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        validation_calls = [
            json.loads(line) for line in validator_record.read_text().splitlines()
        ]
        self.assertEqual(len(validation_calls), 2)
        final_call = validation_calls[-1]
        for path in (final_call[1], final_call[3], final_call[5]):
            self.assertTrue(
                Path(path).resolve().is_relative_to(
                    (output / "contract-inputs/publication-inputs").resolve()
                )
            )
        manifest = json.loads(manifest_path.read_text())
        self.assertTrue(
            Path(manifest["evidence"]["clock_manifest_path"])
            .resolve()
            .is_relative_to(
                (output / "contract-inputs/publication-inputs").resolve()
            )
        )

    def test_enabled_build_snapshots_floorp_release_build_number_authority(self):
        result, _, _, _, output = self.run_script("production-qa")
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = b"FLOORP_BUILD_NUMBER = 4\n"
        for root in (
            output / "contract-inputs/validator-repository",
            output / "contract-inputs/publication-inputs/validator-repository",
        ):
            self.assertEqual(
                (
                    root
                    / "firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
                ).read_bytes(),
                expected,
            )

    def test_post_build_clock_uses_only_the_public_cli(self):
        result, _, _, _, _ = self.run_script("production-qa")
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(self.last_clock_record.read_text())
        self.assertNotIn("--gh-bin", arguments)
        self.assertEqual(arguments.count("--output"), 1)
        workflow_index = arguments.index("--workflow")
        self.assertEqual(
            arguments[workflow_index + 1],
            "floorp-notes-sync-validation-clock.yml",
        )

    def test_local_sources_are_snapshotted_for_build_and_publication(self):
        evidence, metadata, result_bundle = self.prepare_local_source_evidence()
        original_metadata = metadata.read_bytes()
        result, manifest_path, _, _, output = self.run_script(
            "release-enabled",
            extra=["--evidence", str(evidence)],
            env={"FAKE_REPLACE_SOURCE_INPUTS": json.dumps([str(metadata)])},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(metadata.read_bytes(), original_metadata)
        for root in (
            output / "contract-inputs",
            output / "contract-inputs/publication-inputs",
        ):
            self.assertEqual(
                (root / "artifacts/task-manifest.json").read_bytes(),
                original_metadata,
            )
            self.assertTrue(
                (root / "artifacts/FloorpNotesSync.xcresult/Info.plist").is_file()
            )
            self.assertTrue(
                (root / "artifacts/FloorpNotesSync.xcresult/Data/test-summary").is_file()
            )
        manifest = json.loads(manifest_path.read_text())
        local_record = manifest["contract_inputs"]["local_artifact_snapshots"]
        self.assertEqual(
            [item["kind"] for item in local_record["items"]],
            ["local-directory", "local-file"],
        )
        self.assertEqual(
            next(
                item["sha256"]
                for item in local_record["items"]
                if item["kind"] == "local-directory"
            ),
            json.loads(evidence.read_text())["gates"]["g3"]["artifact"]["sources"][0][
                "sha256"
            ],
        )

    def test_unsafe_local_sources_fail_before_validation_and_build(self):
        for attack in ("parent", "symlink", "special", "oversized"):
            with self.subTest(attack=attack):
                evidence, metadata, _ = self.prepare_local_source_evidence()
                payload = json.loads(evidence.read_text())
                source = payload["gates"]["g2"]["artifact"]["sources"][0]
                if attack == "parent":
                    source["path"] = "../outside.json"
                    evidence.write_text(json.dumps(payload, separators=(",", ":"), sort_keys=True))
                elif attack == "symlink":
                    secret = evidence.parent / "outside.json"
                    secret.write_text('{"secret":true}')
                    metadata.unlink()
                    metadata.symlink_to(secret)
                elif attack == "special":
                    metadata.unlink()
                    os.mkfifo(metadata)
                else:
                    with metadata.open("wb") as handle:
                        handle.truncate(32 * 1024 * 1024 + 1)
                    source["sha256"] = "a" * 64
                    evidence.write_text(json.dumps(payload, separators=(",", ":"), sort_keys=True))
                result, manifest, validator_record, xcode_record, _ = self.run_script(
                    "release-enabled", extra=["--evidence", str(evidence)]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(
                    any(
                        marker in result.stderr.lower()
                        for marker in (
                            "local",
                            "permission denied",
                            "xcodebuild failed",
                            "final release validator rejected",
                        )
                    ),
                    result.stderr,
                )
                self.assertFalse(manifest.exists())
                self.assertFalse(validator_record.exists())
                self.assertFalse(xcode_record.exists())

    def test_local_xcresult_scans_secrets_beyond_the_old_cutoff(self):
        evidence, _, result_bundle = self.prepare_local_source_evidence()
        (result_bundle / "Data/test-summary").write_bytes(
            b"x" * (4 * 1024 * 1024 + 17) + b"raw_sync_key"
        )
        payload = json.loads(evidence.read_text())
        payload["gates"]["g3"]["artifact"]["sources"][0]["sha256"] = (
            self.local_xcresult_digest(result_bundle)
        )
        evidence.write_text(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        )

        result, manifest, validator_record, xcode_record, _ = self.run_script(
            "release-enabled",
            extra=["--evidence", str(evidence)],
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("forbidden secret metadata", result.stderr.lower())
        self.assertFalse(manifest.exists())
        self.assertFalse(validator_record.exists())
        self.assertFalse(xcode_record.exists())

    def test_local_snapshot_mutations_fail_without_manifest(self):
        for variable in (
            "FAKE_MUTATE_LOCAL_SNAPSHOT",
            "FAKE_MUTATE_FINAL_LOCAL_SOURCE",
        ):
            with self.subTest(variable=variable):
                evidence, _, _ = self.prepare_local_source_evidence()
                result, manifest, validator_record, _, _ = self.run_script(
                    "release-enabled",
                    extra=["--evidence", str(evidence)],
                    env={variable: "1"},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(
                    any(
                        marker in result.stderr.lower()
                        for marker in (
                            "local",
                            "permission denied",
                            "xcodebuild failed",
                            "final release validator rejected",
                        )
                    ),
                    result.stderr,
                )
                self.assertFalse(manifest.exists())
                self.assertTrue(validator_record.exists())

    def test_fake_validator_cannot_bypass_exact_embedded_gate_sets(self):
        release = json.loads(
            (FIXTURES / "floorp-notes-sync-g1-g5-valid.json").read_text()
        )
        production = json.loads(
            (FIXTURES / "floorp-notes-sync-g1-g4-production-qa-valid.json").read_text()
        )
        cases = (
            ("release-enabled", release, "g6", {"status": "passed"}),
            ("production-qa", production, "g5", release["gates"]["g5"]),
        )
        for mode, evidence, gate, value in cases:
            with self.subTest(mode=mode, gate=gate):
                candidate = json.loads(json.dumps(evidence))
                candidate["gates"][gate] = value
                path = self.root / f"extra-{mode}-{gate}.json"
                path.write_text(json.dumps(candidate, separators=(",", ":"), sort_keys=True))
                result, manifest, validator_record, xcode_record, _ = self.run_script(
                    mode, extra=["--evidence", str(path)]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("exact gate set", result.stderr.lower())
                self.assertFalse(manifest.exists())
                self.assertFalse(validator_record.exists())
                self.assertFalse(xcode_record.exists())

    def test_alternate_g6_authorization_material_is_never_embedded(self):
        for embedding in ("plist", "resource"):
            with self.subTest(embedding=embedding):
                result, manifest, _, _, _ = self.run_script(
                    env={"FAKE_G6_EMBEDDING": embedding}
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("forbidden", result.stderr.lower())
                self.assertFalse(manifest.exists())

    def test_xcodebuild_uses_an_exact_commit_snapshot(self):
        result, manifest_path, _, xcode_record, _ = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        xcode_args = json.loads(xcode_record.read_text().splitlines()[0])
        project = Path(xcode_args[xcode_args.index("-project") + 1]).resolve()
        self.assertFalse(project.is_relative_to(self.repository.resolve()))
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["source"]["commit"], SOURCE_SHA)
        self.assertTrue(manifest["source"]["snapshot"]["read_only"])
        self.assertEqual(
            manifest["source"]["snapshot"]["snapshot_tree_sha256"],
            manifest["contract_inputs"]["source_snapshot"][
                "snapshot_tree_sha256"
            ],
        )
        self.assertEqual(
            Path(manifest["source"]["snapshot"]["snapshot_path"]), project.parent.parent
        )
        self.assertIn("source_snapshot", manifest["contract_inputs"])

    def test_xcodebuild_uses_external_glean_venv_for_read_only_snapshot(self):
        result, _, _, xcode_record, output = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        xcode_args = json.loads(xcode_record.read_text().splitlines()[0])
        settings = [
            argument
            for argument in xcode_args
            if argument.startswith("FLOORP_GLEAN_VENV=")
        ]
        self.assertEqual(len(settings), 1, xcode_args)
        venv = Path(settings[0].split("=", 1)[1]).resolve()
        project = Path(xcode_args[xcode_args.index("-project") + 1]).resolve()
        source_snapshot = project.parent.parent
        self.assertFalse(venv.is_relative_to(source_snapshot))
        self.assertTrue(venv.is_relative_to((output / "tool-state").resolve()))

    def test_exact_snapshot_contains_attested_prepared_generated_sources(self):
        result, manifest_path, _, xcode_record, _ = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(manifest_path.read_text())
        snapshot = manifest["source"]["snapshot"]
        generated = snapshot["generated_source_inputs"]
        self.assertRegex(generated["sha256"], r"^[0-9a-f]{64}$")
        generated_manifest = json.loads(Path(generated["path"]).read_text())
        self.assertEqual(generated_manifest["schema_version"], 1)
        self.assertEqual(generated_manifest["source_sha"], SOURCE_SHA)
        generated_paths = {
            entry["path"] for entry in generated_manifest["generated_files"]
        }
        self.assertTrue(
            {
                "firefox-ios/Client/Generated/FxNimbus.swift",
                "firefox-ios/Client/Generated/FxNimbusMessaging.swift",
                "firefox-ios/Client/Generated/Metrics/Metrics.swift",
                "firefox-ios/Storage/Generated/Metrics.swift",
            }.issubset(generated_paths)
        )
        source_snapshot = Path(snapshot["snapshot_path"])
        self.assertFalse((source_snapshot / "firefox-ios/.venv").exists())
        for relative in generated_paths:
            mode = (source_snapshot / relative).stat().st_mode
            self.assertEqual(mode & 0o222, 0, relative)
        xcode_args = json.loads(xcode_record.read_text().splitlines()[0])
        self.assertIn("FLOORP_GENERATED_SOURCES_PREPARED=YES", xcode_args)
        self.assertIn(
            f"FLOORP_GENERATED_SOURCE_MANIFEST={generated['path']}",
            xcode_args,
        )

    def test_generated_source_preparer_rejects_unexpected_output(self):
        bootstrap = self.repository / "bootstrap.sh"
        bootstrap.write_text(
            bootstrap.read_text()
            + '\nprintf "unexpected\\n" > "$root/unexpected-generated-input"\n'
        )
        result, manifest, _, xcode_record, _ = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generated-source path set mismatch", result.stderr)
        self.assertFalse(manifest.exists())
        self.assertFalse(xcode_record.exists())

    def test_wrapper_ignores_inherited_glean_tool_paths(self):
        attacker_root = self.root / "attacker-tooling"
        result, _, _, xcode_record, output = self.run_script(
            env={
                "FLOORP_GENERATED_SOURCE_MANIFEST": str(
                    self.root / "attacker-manifest.json"
                ),
                "FLOORP_GENERATED_SOURCES_PREPARED": "YES",
                "FLOORP_GLEAN_TOOL_ROOT": str(attacker_root),
                "FLOORP_GLEAN_VENV": str(attacker_root / "glean-venv"),
                "FLOORP_GLEAN_VERIFY_ONLY": "NO",
                "FLOORP_GLEAN_VERIFY_ROOT": str(attacker_root / "verify"),
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        xcode_args = json.loads(xcode_record.read_text().splitlines()[0])
        self.assertIn(
            f"FLOORP_GLEAN_TOOL_ROOT={(output / 'tool-state').resolve()}",
            xcode_args,
        )
        self.assertFalse(attacker_root.exists())

    def test_production_qa_rejects_archive_and_signing(self):
        cases = (["--action", "archive"], ["--allow-signing"])
        for extra in cases:
            with self.subTest(extra=extra):
                result, _, _, xcode_record, _ = self.run_script("production-qa", extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("production-qa", result.stderr)
                self.assertFalse(xcode_record.exists())

    def test_release_enabled_archive_binds_g1_g5_and_all_artifacts(self):
        archive_parent = self.root / "final-output"
        archive_parent.mkdir(mode=0o700)
        archive = archive_parent / "FloorpNotes.xcarchive"
        result, manifest_path, _, xcode_record, _ = self.run_script(
            "release-enabled",
            extra=["--action", "archive", "--archive-path", str(archive), "--allow-signing"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["source"]["commit"], SOURCE_SHA)
        self.assertEqual(manifest["source"]["tree"], SOURCE_TREE)
        self.assertFalse(manifest["source"]["dirty"])
        self.assertEqual(
            manifest["release_inputs"]["ios"],
            json.loads(
                (FIXTURES / "floorp-notes-sync-g1-g5-valid.json").read_text()
            )["release_inputs"]["ios"],
        )
        self.assertEqual(manifest["paths"]["archive"], str(archive.resolve()))
        self.assertEqual(
            manifest["evidence"]["embedded_digest_sha256"],
            "15c74251e456fda956c70e8d11e420b5e31c5a011531c0d24c05d675c070e55a",
        )
        self.assertEqual(manifest["build"]["xcode_version"], ["Xcode 26.0", "Build version 17A100"])
        self.assertEqual(manifest["build"]["build_number"], EVIDENCE_BUILD_NUMBER)
        xcconfig = Path(manifest["contract_inputs"]["xcconfig_path"]).read_text()
        self.assertIn(
            f"FLOORP_BUILD_NUMBER = {EVIDENCE_BUILD_NUMBER}\n",
            xcconfig,
        )
        self.assertTrue(manifest["build"]["signing_verified"])
        self.assertEqual(
            manifest["build"]["signing_identity"]["authorities"],
            [
                "Apple Distribution: Floorp Projects Inc. (DV2U35YBHT)",
                "Apple Worldwide Developer Relations Certification Authority",
                "Apple Root CA",
            ],
        )
        self.assertEqual(
            manifest["build"]["provisioning_profile"]["team_identifier"],
            ["DV2U35YBHT"],
        )
        self.assertEqual(
            manifest["build"]["toolchain"]["xcodebuild"]["path"],
            str(self.fake_developer_dir / "usr/bin/xcodebuild"),
        )
        self.assertEqual(
            manifest["build"]["toolchain"]["xcode_app"]["team_identifier"],
            "59GAB85EFG",
        )
        self.assertEqual(manifest["build"]["destination"], "generic/platform=iOS")
        self.assertRegex(manifest["artifacts"]["app_merkle_sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(manifest["artifacts"]["executable"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(manifest["artifacts"]["info_plist"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(manifest["artifacts"]["entitlements"]["source"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertTrue(manifest["artifacts"]["application_services"]["frameworks"])
        self.assertEqual(
            manifest["artifacts"]["entitlements"]["signed"][
                "com.apple.developer.team-identifier"
            ],
            "DV2U35YBHT",
        )
        xcode_args = json.loads(xcode_record.read_text().splitlines()[0])
        self.assertEqual(xcode_args[0], "archive")
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", xcode_args)

    def test_release_enabled_requires_evidence_and_clock(self):
        for flag in ("--evidence", "--validation-clock-manifest"):
            with self.subTest(flag=flag):
                result, _, _, xcode_record, _ = self.run_script(
                    "release-enabled", omit=[flag]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(xcode_record.exists())

    def test_release_disabled_rejects_evidence_inputs(self):
        result, _, _, xcode_record, _ = self.run_script(
            extra=["--evidence", str(FIXTURES / "floorp-notes-sync-g1-g5-valid.json")]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release-disabled", result.stderr)
        self.assertFalse(xcode_record.exists())

    def test_missing_g5_fails_even_when_validator_returns_success(self):
        evidence = json.loads((FIXTURES / "floorp-notes-sync-g1-g5-valid.json").read_text())
        del evidence["gates"]["g5"]
        path = self.root / "missing-g5.json"
        path.write_text(json.dumps(evidence))
        result, _, _, xcode_record, _ = self.run_script(
            "release-enabled",
            extra=["--evidence", str(path)],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("g5", result.stderr.lower())
        self.assertFalse(xcode_record.exists())

    def test_validator_failure_stops_before_xcodebuild(self):
        result, _, _, xcode_record, _ = self.run_script(
            "release-enabled", env={"FAKE_VALIDATOR_EXIT": "1"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("validator", result.stderr.lower())
        self.assertFalse(xcode_record.exists())

    def test_wrong_clock_head_fails_closed(self):
        clock = json.loads((FIXTURES / "validation-clock-valid.json").read_text())
        clock["run"]["head_sha"] = "c" * 40
        path = self.root / "wrong-clock.json"
        path.write_text(json.dumps(clock))
        result, _, _, xcode_record, _ = self.run_script(
            "release-enabled",
            extra=["--validation-clock-manifest", str(path)],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clock", result.stderr.lower())
        self.assertFalse(xcode_record.exists())

    def test_dirty_or_mutated_source_fails_closed(self):
        for variable in ("FAKE_GIT_DIRTY", "FAKE_GIT_MUTATE"):
            with self.subTest(variable=variable):
                result, _, _, _, _ = self.run_script(env={variable: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("source", result.stderr.lower())

    def test_source_sha_mismatch_fails_before_build(self):
        result, _, _, xcode_record, _ = self.run_script(env={"FAKE_GIT_HEAD": "c" * 40})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source-sha", result.stderr.lower())
        self.assertFalse(xcode_record.exists())

    def test_enabled_build_number_must_match_built_cf_bundle_version(self):
        result, manifest, _, _, _ = self.run_script(
            "release-enabled", env={"FAKE_BUILD_NUMBER": "999999"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build number", result.stderr.lower())
        self.assertFalse(manifest.exists())

    def test_enabled_ios_release_inputs_are_exact(self):
        mutations = {
            "repository": "Example/floorp-ios",
            "source_sha": "c" * 40,
            "configuration": "Debug",
        }
        for field, value in mutations.items():
            with self.subTest(field=field):
                evidence = json.loads(
                    (FIXTURES / "floorp-notes-sync-g1-g5-valid.json").read_text()
                )
                evidence["release_inputs"]["ios"][field] = value
                path = self.root / f"wrong-ios-{field}.json"
                path.write_text(json.dumps(evidence))
                result, _, _, xcode_record, _ = self.run_script(
                    "release-enabled", extra=["--evidence", str(path)]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ios", result.stderr.lower())
                self.assertFalse(xcode_record.exists())

    def test_application_services_release_inputs_exactly_match_checked_in_pin(self):
        mutations = [
            ("repository", "Example/application-services"),
            ("release_tag", "floorp-ios-wrong"),
            ("source_sha", "c" * 40),
            ("tree_sha", "d" * 40),
            ("artifacts.focus_xcframework_sha256", "1" * 64),
            ("artifacts.mozilla_xcframework_sha256", "2" * 64),
            ("artifacts.release_manifest_sha256", "3" * 64),
            ("artifacts.sha256sums_sha256", "4" * 64),
            ("artifacts.swift_components_sha256", "5" * 64),
            ("artifacts.unexpected_sha256", "6" * 64),
            ("artifacts.focus_xcframework_sha256", None),
        ]
        for field, value in mutations:
            with self.subTest(field=field):
                evidence = json.loads(
                    (FIXTURES / "floorp-notes-sync-g1-g5-valid.json").read_text()
                )
                target = evidence["release_inputs"]["application_services"]
                parts = field.split(".")
                for part in parts[:-1]:
                    target = target[part]
                if value is None:
                    del target[parts[-1]]
                else:
                    target[parts[-1]] = value
                path = self.root / f"wrong-as-{field.replace('.', '-')}.json"
                path.write_text(json.dumps(evidence))
                result, _, _, xcode_record, _ = self.run_script(
                    "release-enabled", extra=["--evidence", str(path)]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("application services", result.stderr.lower())
                self.assertFalse(xcode_record.exists())

    def test_contract_inputs_are_snapshotted_before_validation_and_source_replacement(self):
        evidence = self.root / "mutable-evidence.json"
        clock = self.root / "mutable-clock.json"
        schema = self.root / "mutable-schema.json"
        shutil.copy2(FIXTURES / "floorp-notes-sync-g1-g5-valid.json", evidence)
        shutil.copy2(FIXTURES / "validation-clock-valid.json", clock)
        shutil.copy2(
            REPOSITORY / "docs/floorp-notes-sync-release-evidence.schema.json",
            schema,
        )
        original_evidence = evidence.read_bytes()
        result, manifest_path, validator_record, _, output = self.run_script(
            "release-enabled",
            extra=[
                "--evidence",
                str(evidence),
                "--validation-clock-manifest",
                str(clock),
                "--schema",
                str(schema),
            ],
            env={
                "FAKE_REPLACE_SOURCE_INPUTS": json.dumps(
                    [str(evidence), str(clock), str(schema)]
                )
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(evidence.read_bytes(), original_evidence)
        manifest = json.loads(manifest_path.read_text())
        app = Path(manifest["paths"]["app"])
        self.assertEqual(
            (app / "FloorpNotesSyncReleaseEvidence.json").read_bytes(),
            original_evidence,
        )
        validator_args = json.loads(validator_record.read_text().splitlines()[0])
        for path in (validator_args[1], validator_args[3], validator_args[5]):
            self.assertTrue(
                Path(path).resolve().is_relative_to(
                    (output / "contract-inputs").resolve()
                )
            )
        self.assertTrue(
            Path(manifest["contract_inputs"]["schema_path"]).resolve().is_relative_to(
                (output / "contract-inputs").resolve()
            )
        )

    def test_contract_snapshot_mutation_during_build_fails_without_manifest(self):
        result, manifest, _, _, _ = self.run_script(
            "release-enabled", env={"FAKE_MUTATE_CONTRACT_SNAPSHOT": "1"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("snapshot", result.stderr.lower())
        self.assertFalse(manifest.exists())

    def test_generated_manifest_mutation_during_build_fails_without_manifest(self):
        result, manifest, _, _, _ = self.run_script(
            env={"FAKE_MUTATE_GENERATED_MANIFEST": "1"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generated-source manifest", result.stderr.lower())
        self.assertFalse(manifest.exists())

    def test_generated_source_mutation_during_build_fails_without_manifest(self):
        result, manifest, _, _, _ = self.run_script(
            env={"FAKE_MUTATE_GENERATED_SOURCE": "1"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source snapshot", result.stderr.lower())
        self.assertFalse(manifest.exists())

    def test_publication_snapshot_mutation_during_final_validation_fails(self):
        result, manifest, validator_record, _, _ = self.run_script(
            "release-enabled", env={"FAKE_MUTATE_FINAL_VALIDATION": "1"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(validator_record.read_text().splitlines()), 2)
        self.assertIn("snapshot", result.stderr.lower())
        self.assertFalse(manifest.exists())

    def test_app_mutation_after_final_validation_fails_before_publication(self):
        next_output = self.root / f"output-{self.run_index + 1}"
        app_binary = (
            next_output
            / "DerivedData/Build/Products/FloorpRelease-iphonesimulator/Client.app/Client"
        )
        result, manifest, validator_record, _, _ = self.run_script(
            "release-enabled",
            env={
                "FAKE_MUTATE_APP_AFTER_FINAL_VALIDATION": "1",
                "FAKE_APP_TO_MUTATE": str(app_binary),
            },
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(validator_record.read_text().splitlines()), 2)
        self.assertIn("changed after release validation", result.stderr.lower())
        self.assertFalse(manifest.exists())

    def test_allow_signing_requires_release_enabled_device_archive(self):
        cases = (
            ("release-disabled", ["--action", "archive", "--allow-signing"]),
            ("release-enabled", ["--allow-signing"]),
            (
                "release-enabled",
                [
                    "--action",
                    "archive",
                    "--allow-signing",
                    "--destination",
                    "generic/platform=iOS Simulator",
                ],
            ),
        )
        for mode, extra in cases:
            with self.subTest(mode=mode, extra=extra):
                result, _, _, xcode_record, _ = self.run_script(mode, extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("sign", result.stderr.lower())
                self.assertFalse(xcode_record.exists())

    def test_allow_signing_rejects_missing_or_mismatched_signed_entitlements(self):
        for signing_mode in (
            "missing",
            "empty-entitlements",
            "bad-team",
            "bad-authority",
            "bad-app-group",
            "bad-keychain",
            "profile-bad-team",
            "profile-bad-app-id",
            "profile-expired",
            "profile-development",
            "profile-bad-certificate",
            "certificate-untrusted",
        ):
            with self.subTest(signing_mode=signing_mode):
                archive = self.root / f"{signing_mode}.xcarchive"
                result, manifest, _, _, _ = self.run_script(
                    "release-enabled",
                    extra=[
                        "--action",
                        "archive",
                        "--archive-path",
                        str(archive),
                        "--allow-signing",
                    ],
                    env={"FAKE_SIGNING_MODE": signing_mode},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(
                    result.stderr.lower(), r"sign|mobileprovision|certificate"
                )
                self.assertFalse(manifest.exists())

    def test_untrusted_selected_xcode_is_rejected_before_build(self):
        for signature_mode in ("adhoc", "bad-team"):
            with self.subTest(signature_mode=signature_mode):
                result, manifest, _, xcode_record, _ = self.run_script(
                    env={"FAKE_XCODE_SIGNATURE_MODE": signature_mode}
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("xcode", result.stderr.lower())
                self.assertFalse(manifest.exists())
                self.assertFalse(xcode_record.exists())

    def test_allow_signing_rejects_ad_hoc_and_unexpected_entitlements(self):
        for signing_mode in ("adhoc", "unexpected-entitlement", "get-task-allow"):
            with self.subTest(signing_mode=signing_mode):
                archive = self.root / f"{signing_mode}.xcarchive"
                result, manifest, _, _, _ = self.run_script(
                    "release-enabled",
                    extra=[
                        "--action",
                        "archive",
                        "--archive-path",
                        str(archive),
                        "--allow-signing",
                    ],
                    env={"FAKE_SIGNING_MODE": signing_mode},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("sign", result.stderr.lower())
                self.assertFalse(manifest.exists())

    def test_existing_manifest_is_never_replaced(self):
        manifest = self.root / "append-only-build-manifest.json"
        marker = b'{"marker":"preserve"}\n'
        manifest.write_bytes(marker)
        result, _, _, _, _ = self.run_script(manifest_path=manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest", result.stderr.lower())
        self.assertEqual(manifest.read_bytes(), marker)

    def test_existing_empty_output_directory_is_rejected(self):
        output = self.root / f"output-{self.run_index + 1}"
        output.mkdir(mode=0o700)

        result, manifest, _, xcode_record, _ = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output-dir", result.stderr.lower())
        self.assertFalse(manifest.exists())
        self.assertFalse(xcode_record.exists())

    def test_production_cli_ignores_path_toolchain_poisoning(self):
        production_repository = self.root / "production-source"
        shutil.copytree(self.repository, production_repository)
        production_script = (
            production_repository / "scripts/staging/build-floorp-notes-sync-ios.sh"
        )
        shutil.copy2(SCRIPT, production_script)
        subprocess.run(["/usr/bin/git", "init", "-q", str(production_repository)], check=True)
        subprocess.run(
            ["/usr/bin/git", "-C", str(production_repository), "add", "."],
            check=True,
        )
        subprocess.run(
            [
                "/usr/bin/git",
                "-C",
                str(production_repository),
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Build Contract Test",
                "-c",
                "user.email=build-contract@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ],
            check=True,
        )
        source_sha = subprocess.check_output(
            ["/usr/bin/git", "-C", str(production_repository), "rev-parse", "HEAD"],
            text=True,
        ).strip()
        poison = self.root / "poison-bin"
        poison.mkdir()
        poison_marker = self.root / "path-poison-ran"
        for name in ("git", "xcode-select", "xcodebuild"):
            path = poison / name
            path.write_text(
                f"#!/bin/sh\necho {name} >> {poison_marker!s}\nexit 99\n"
            )
            path.chmod(0o755)
        bash_env_marker = self.root / "bash-env-ran"
        bash_env = self.root / "bash-env.sh"
        bash_env.write_text(f"touch {bash_env_marker!s}\n")
        python_poison = self.root / "python-poison"
        python_poison.mkdir()
        python_marker = self.root / "python-sitecustomize-ran"
        (python_poison / "sitecustomize.py").write_text(
            f"from pathlib import Path\nPath({str(python_marker)!r}).touch()\n"
        )
        git_marker = self.root / "git-config-ran"
        git_fsmonitor = self.root / "git-fsmonitor.sh"
        git_fsmonitor.write_text(f"#!/bin/sh\ntouch {git_marker!s}\nexit 0\n")
        git_fsmonitor.chmod(0o755)
        output = self.root / "nonempty-output"
        output.mkdir()
        (output / "marker").write_text("preserve\n")
        result = subprocess.run(
            [
                "/bin/bash",
                "-p",
                str(production_script),
                "--mode",
                "release-disabled",
                "--source-sha",
                source_sha,
                "--output-dir",
                str(output),
                "--manifest",
                str(self.root / "production-manifest.json"),
            ],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "PATH": f"{poison}:/usr/bin:/bin",
                "BASH_ENV": str(bash_env),
                "PYTHONPATH": str(python_poison),
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "core.fsmonitor",
                "GIT_CONFIG_VALUE_0": str(git_fsmonitor),
            },
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output-dir", result.stderr)
        self.assertFalse(poison_marker.exists())
        self.assertFalse(bash_env_marker.exists())
        self.assertFalse(python_marker.exists())
        self.assertFalse(git_marker.exists())
        production_text = SCRIPT.read_text()
        self.assertIn('GIT_BIN="/usr/bin/git"', production_text)
        self.assertIn('XCODE_SELECT_BIN="/usr/bin/xcode-select"', production_text)
        self.assertIn('CODESIGN_BIN="/usr/bin/codesign"', production_text)
        self.assertNotIn("FAKE_", production_text)
        self.assertNotIn("--test-", production_text)

    def test_wrong_endpoint_matrix_fails_closed(self):
        path = self.repository / "docs/floorp-release-endpoints.json"
        matrix = json.loads(path.read_text())
        next(row for row in matrix["endpoints"] if row["host"] == "sync.services.mozilla.com")[
            "status"
        ] = "disabled"
        path.write_text(json.dumps(matrix))
        result, _, _, xcode_record, _ = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("endpoint", result.stderr.lower())
        self.assertFalse(xcode_record.exists())

    def test_nonproduction_or_custom_evidence_authority_fails_closed(self):
        for field, value in (
            ("fxa_configuration", "FxAConfig.Server.stage"),
            ("sync_hosts", ["sync.example.invalid"]),
        ):
            with self.subTest(field=field):
                evidence = json.loads(
                    (
                        FIXTURES
                        / "floorp-notes-sync-g1-g4-production-qa-valid.json"
                    ).read_text()
                )
                evidence["release_inputs"]["environment"][field] = value
                path = self.root / f"wrong-authority-{field}.json"
                path.write_text(json.dumps(evidence))
                result, _, _, xcode_record, _ = self.run_script(
                    "production-qa", extra=["--evidence", str(path)]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("endpoint authority", result.stderr.lower())
                self.assertFalse(xcode_record.exists())

    def test_repository_validator_rejects_legacy_unretrievable_fixture_modes(self):
        validator_root = self.root / "real-validator-snapshot"
        validator = validator_root / "scripts/ci/validate-floorp-notes-sync-release.py"
        schema = validator_root / "docs/floorp-notes-sync-release-evidence.schema.json"
        endpoint_policy = validator_root / "docs/floorp-release-endpoints.json"
        merge_fixture = validator_root / (
            "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json"
        )
        for source, target in (
            (REPOSITORY / "scripts/ci/validate-floorp-notes-sync-release.py", validator),
            (REPOSITORY / "docs/floorp-notes-sync-release-evidence.schema.json", schema),
            (REPOSITORY / "docs/floorp-release-endpoints.json", endpoint_policy),
            (
                REPOSITORY / "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
                merge_fixture,
            ),
        ):
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

        clock = self.root / "real-validator-clock.json"
        shutil.copy2(FIXTURES / "validation-clock-valid.json", clock)
        mock_gh = self.root / "real-validator-mock-gh"
        mock_gh.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json, os, pathlib, sys
            clock = json.loads(pathlib.Path(os.environ["BUILD_WRAPPER_TEST_CLOCK"]).read_text())
            run = clock["run"]
            live_run = {
                "conclusion": run["conclusion"],
                "created_at": run["created_at"],
                "event": run["event"],
                "head_sha": run["head_sha"],
                "html_url": run["html_url"],
                "id": run["id"],
                "path": f'{run["workflow_path"]}@{run["head_sha"]}',
                "repository": {"full_name": run["repository"]},
                "run_attempt": run["attempt"],
                "status": run["status"],
                "updated_at": run["updated_at"],
                "url": run["api_url"],
                "workflow_id": run["workflow_id"],
            }
            joined = " ".join(sys.argv[1:])
            if "/attempts/" in joined and "/jobs" in joined:
                print(json.dumps({"jobs": clock["jobs"], "total_count": len(clock["jobs"])}))
            elif "--include" in sys.argv:
                print("HTTP/2.0 200 OK")
                print(f'Date: {clock["github_http_date"]}')
                print("Content-Type: application/json")
                print()
                print(json.dumps(live_run))
            else:
                raise SystemExit("unexpected mock GitHub API invocation")
        """))
        mock_gh.chmod(0o755)
        validator_driver = self.root / "real-validator-driver.py"
        validator_driver.write_text(textwrap.dedent(f"""\
            import importlib.util
            import pathlib
            import sys

            validator = pathlib.Path({str(validator)!r})
            spec = importlib.util.spec_from_file_location("build_wrapper_validator", validator)
            if spec is None or spec.loader is None:
                raise SystemExit("validator module could not be loaded")
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            raise SystemExit(
                module.main(sys.argv[2:], test_gh_bin=pathlib.Path(sys.argv[1]))
            )
        """))
        environment = os.environ.copy()
        environment["BUILD_WRAPPER_TEST_CLOCK"] = str(clock)
        for fixture in (
            "floorp-notes-sync-g1-g4-production-qa-valid.json",
            "floorp-notes-sync-g1-g5-valid.json",
        ):
            with self.subTest(fixture=fixture):
                evidence = self.root / fixture
                shutil.copy2(FIXTURES / fixture, evidence)
                result = subprocess.run(
                    [
                        "python3",
                        str(validator_driver),
                        str(mock_gh),
                        "--schema",
                        str(schema),
                        "--evidence",
                        str(evidence),
                        "--validation-clock-manifest",
                        str(clock),
                        "--canonicalization",
                        "rfc8785-jcs",
                    ],
                    cwd=REPOSITORY,
                    capture_output=True,
                    text=True,
                    env=environment,
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("REJECT", result.stderr)

    def test_post_build_gate_mismatch_fails_without_manifest(self):
        result, manifest, _, _, _ = self.run_script(env={"FAKE_GATE_MISMATCH": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gate", result.stderr.lower())
        self.assertFalse(manifest.exists())

    def test_output_inside_source_worktree_is_rejected(self):
        output = self.repository / "forbidden-output"
        manifest = output / "manifest.json"
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "FAKE_GIT_HEAD": SOURCE_SHA,
                "FAKE_GIT_TREE": SOURCE_TREE,
                "FAKE_GIT_STATUS_COUNTER": str(self.root / "inside-status"),
                "FAKE_VALIDATOR_RECORD": str(self.root / "inside-validator"),
                "FAKE_XCODE_RECORD": str(self.root / "inside-xcode"),
            }
        )
        result = subprocess.run(
            [
                "/bin/bash",
                "-p",
                str(self.repository / "scripts/staging/build-floorp-notes-sync-ios.sh"),
                "--mode",
                "release-disabled",
                "--source-sha",
                SOURCE_SHA,
                "--output-dir",
                str(output),
                "--manifest",
                str(manifest),
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("worktree", result.stderr.lower())


class GleanSDKGeneratorContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "read-only-source"
        self.source.mkdir()
        self.yaml = self.source / "metrics.yaml"
        self.yaml.write_text("$schema: moz://mozilla.org/schemas/glean/metrics/2-0-0\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.python_record = self.root / "python-record.jsonl"
        fake_python = self.bin / "python3"
        fake_python.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/python3
                import json, os, pathlib, sys

                record = pathlib.Path(os.environ["FAKE_PYTHON_RECORD"])
                with record.open("a") as handle:
                    handle.write(json.dumps(sys.argv[1:]) + "\\n")
                if sys.argv[1:3] == ["-m", "venv"]:
                    target = pathlib.Path(sys.argv[3])
                    binary = target / "bin"
                    binary.mkdir(parents=True)
                    for name in ("python", "pip"):
                        (binary / name).symlink_to(pathlib.Path(__file__).resolve())
                elif "translate" in sys.argv:
                    output = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
                    output.mkdir(parents=True, exist_ok=True)
                    (output / "Metrics.swift").write_text("generated metrics\\n")
                """
            )
        )
        fake_python.chmod(0o755)

    def tearDown(self):
        for path in sorted(self.source.rglob("*"), reverse=True):
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o200)
        self.source.chmod(0o755)
        self.temporary.cleanup()

    def test_explicit_writable_venv_supports_read_only_source(self):
        tool_root = self.root / "writable-tooling"
        tool_root.mkdir(mode=0o700)
        verify_root = tool_root / "verify"
        verify_root.mkdir(mode=0o700)
        venv = tool_root / "glean-venv"
        output = self.root / "generated"
        self.source.chmod(0o555)
        environment = os.environ.copy()
        environment.update(
            {
                "ACTION": "build",
                "FAKE_PYTHON_RECORD": str(self.python_record),
                "FLOORP_GLEAN_TOOL_ROOT": str(tool_root),
                "FLOORP_GLEAN_VENV": str(venv),
                "FLOORP_GLEAN_VERIFY_ROOT": str(verify_root),
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "PROJECT": "Client",
                "SOURCE_ROOT": str(self.source),
            }
        )
        result = subprocess.run(
            [
                "/bin/bash",
                str(SDK_GENERATOR),
                "--output",
                str(output),
                str(self.yaml),
            ],
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((venv / "bin/python").is_symlink())
        self.assertFalse((self.source / ".venv").exists())
        calls = [
            json.loads(line) for line in self.python_record.read_text().splitlines()
        ]
        self.assertIn(["-m", "venv", str(venv)], calls)

    def test_relative_explicit_venv_is_rejected_before_tool_execution(self):
        tool_root = self.root / "writable-tooling"
        tool_root.mkdir(mode=0o700)
        verify_root = tool_root / "verify"
        verify_root.mkdir(mode=0o700)
        environment = os.environ.copy()
        environment.update(
            {
                "ACTION": "build",
                "FAKE_PYTHON_RECORD": str(self.python_record),
                "FLOORP_GLEAN_TOOL_ROOT": str(tool_root),
                "FLOORP_GLEAN_VENV": "relative/glean-venv",
                "FLOORP_GLEAN_VERIFY_ROOT": str(verify_root),
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "PROJECT": "Client",
                "SOURCE_ROOT": str(self.source),
            }
        )
        result = subprocess.run(
            ["/bin/bash", str(SDK_GENERATOR), str(self.yaml)],
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("absolute path", result.stderr)
        self.assertFalse(self.python_record.exists())

    def test_verify_only_regenerates_outside_source_and_preserves_bytes(self):
        generated = self.source / "Generated"
        generated.mkdir()
        metrics = generated / "Metrics.swift"
        metrics.write_text("generated metrics\n")
        metrics.chmod(0o444)
        generated.chmod(0o555)
        self.source.chmod(0o555)
        before = (metrics.read_bytes(), metrics.stat().st_mtime_ns)

        tool_root = self.root / "private-tooling"
        tool_root.mkdir(mode=0o700)
        verify_root = tool_root / "verify"
        verify_root.mkdir(mode=0o700)
        venv = tool_root / "glean-venv"
        environment = os.environ.copy()
        environment.update(
            {
                "ACTION": "build",
                "FAKE_PYTHON_RECORD": str(self.python_record),
                "FLOORP_GLEAN_TOOL_ROOT": str(tool_root),
                "FLOORP_GLEAN_VENV": str(venv),
                "FLOORP_GLEAN_VERIFY_ONLY": "YES",
                "FLOORP_GLEAN_VERIFY_ROOT": str(verify_root),
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "PROJECT": "Client",
                "SOURCE_ROOT": str(self.source),
            }
        )
        result = subprocess.run(
            [
                "/bin/bash",
                str(SDK_GENERATOR),
                "--output",
                str(generated),
                str(self.yaml),
            ],
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((metrics.read_bytes(), metrics.stat().st_mtime_ns), before)
        self.assertEqual(list(verify_root.iterdir()), [])

    def test_symlinked_external_tool_root_is_rejected(self):
        real_tool_root = self.root / "real-tooling"
        real_tool_root.mkdir(mode=0o700)
        (real_tool_root / "verify").mkdir(mode=0o700)
        tool_root = self.root / "linked-tooling"
        tool_root.symlink_to(real_tool_root, target_is_directory=True)
        environment = os.environ.copy()
        environment.update(
            {
                "ACTION": "build",
                "FAKE_PYTHON_RECORD": str(self.python_record),
                "FLOORP_GLEAN_TOOL_ROOT": str(tool_root),
                "FLOORP_GLEAN_VENV": str(tool_root / "glean-venv"),
                "FLOORP_GLEAN_VERIFY_ROOT": str(tool_root / "verify"),
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "PROJECT": "Client",
                "SOURCE_ROOT": str(self.source),
            }
        )
        result = subprocess.run(
            ["/bin/bash", str(SDK_GENERATOR), str(self.yaml)],
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("symlink", result.stderr.lower())
        self.assertFalse((real_tool_root / "glean-venv").exists())


if __name__ == "__main__":
    unittest.main()
