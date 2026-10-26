#!/usr/bin/env python3
"""Check legacy/local Workspace runtime selection without downloading binaries."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "MozillaRustComponents"


def describe(override=None, package_path=PACKAGE):
    environment = dict(os.environ)
    environment.pop("FLOORP_APPLICATION_SERVICES_XCFRAMEWORK", None)
    if override is not None:
        environment["FLOORP_APPLICATION_SERVICES_XCFRAMEWORK"] = str(override)
    return subprocess.run(
        ["swift", "package", "--package-path", str(package_path), "dump-package"],
        env=environment, capture_output=True, text=True,
    )


def target(package, name):
    return next(value for value in package["targets"] if value["name"] == name)


def assert_runtime_selection(package, supports_workspaces):
    wrapper = target(package, "MozillaAppServices")
    assert ("FloorpWorkspaceRuntimeLegacy.swift" in wrapper["exclude"]) == supports_workspaces
    assert ("Generated/floorp_workspaces_sync.swift" in wrapper["exclude"]) != supports_workspaces
    assert any("FLOORP_WORKSPACES_RUNTIME" in str(value) for value in wrapper["settings"]) == supports_workspaces


def check_capability_fixtures(directory):
    for enabled in [False, True]:
        fixture = directory / f"selection-{enabled}"
        fixture.mkdir()
        shutil.copy2(PACKAGE / "Package.swift", fixture / "Package.swift")
        for path in [
            "Sources/MozillaRustComponentsWrapper/FloorpWorkspaceRuntimeLegacy.swift",
            "Sources/MozillaRustComponentsWrapper/Generated/floorp_workspaces_sync.swift",
            "Sources/FocusRustComponentsWrapper/Fixture.swift",
            "Tests/MozillaRustComponentsTests/Fixture.swift",
        ]:
            source = fixture / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("// Manifest selection fixture; never compiled or linked.\n")
        # No release identity is asserted by these manifest-only capability fixtures.
        (fixture / "FloorpApplicationServicesPin.json").write_text(json.dumps({
            "capabilities": {"floorpWorkspaces": enabled},
        }))
        result = describe(package_path=fixture)
        assert result.returncode == 0, result.stderr
        selected = json.loads(result.stdout)
        assert "url" in target(selected, "MozillaRustComponents")
        assert_runtime_selection(selected, enabled)


def main():
    default = describe()
    assert default.returncode == 0, default.stderr
    package = json.loads(default.stdout)
    pinned = json.loads((PACKAGE / "FloorpApplicationServicesPin.json").read_text())
    native = target(package, "MozillaRustComponents")
    assert native["url"].endswith(f'{pinned["release"]["tag"]}/MozillaRustComponents.xcframework.zip')
    assert native["checksum"] == pinned["assets"]["MozillaRustComponents.xcframework.zip"]["swiftPMChecksum"]
    supports_workspaces = pinned.get("capabilities", {}).get("floorpWorkspaces") is True
    assert_runtime_selection(package, supports_workspaces)

    with tempfile.TemporaryDirectory(prefix="floorp-workspace-runtime-manifest-") as temporary:
        check_capability_fixtures(Path(temporary))
        framework = Path(temporary) / "MozillaRustComponents.xcframework"
        headers = framework / "ios-arm64" / "Headers"
        headers.mkdir(parents=True)
        (framework / "Info.plist").write_text("fixture for manifest selection only")
        rejected = describe(framework)
        assert rejected.returncode != 0
        assert "does not contain the floorp_workspaces_sync UniFFI header" in rejected.stderr
        (headers / "floorp_workspaces_syncFFI.h").write_text(
            "uint32_t ffi_floorp_workspaces_sync_uniffi_contract_version(void);\n"
        )
        local = describe(framework)
        assert local.returncode == 0, local.stderr
        package = json.loads(local.stdout)
        assert (PACKAGE / target(package, "MozillaRustComponents")["path"]).resolve() == framework.resolve()
        assert_runtime_selection(package, True)
        assert target(package, "FocusRustComponents")["url"].endswith(
            f'{pinned["release"]["tag"]}/FocusRustComponents.xcframework.zip'
        )
    print("Workspace runtime manifest selection passed (pin, legacy/capable fixtures, rejected override, local headers).")


if __name__ == "__main__":
    main()
