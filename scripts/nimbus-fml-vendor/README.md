# Floorp Nimbus FML script

`nimbus-fml.sh` is vendored from Mozilla Application Services commit
`f515906ebb956a1a1cd6ad51d0f8877a6a8675f3`, path
`components/nimbus/ios/scripts/nimbus-fml.sh`. The pristine upstream SHA-256 is
`443a72235811e6367914f80b2eacc900d55913442cb9d594930170e0e2cc5da4`.
The original MPL notice remains in the file.

Floorp changes the prebuilt binary cache handling: every reused ZIP is checked
against its saved checksum; unavailable remote checksums permit a verified
cache for the exact Application Services version, while `--fresh`, malformed
remote checksums, and failed downloads after a known checksum never use that
fallback. Downloads are verified before replacing existing cache files. The
host executable is extracted from a private verified ZIP snapshot and replaces
a mismatched cached executable. Each invocation runs its private extracted
binary so another build cannot change it between validation and generation.
The `--fresh` option also advances by one argument.

`bootstrap.sh` verifies the fixed patched-script SHA-256 before installing it
atomically to the ignored `firefox-ios/bin/nimbus-fml.sh`, and repairs stale
generated copies. Update that reviewed checksum whenever this vendored file
changes. Bootstrap no longer downloads the generator script; its binary
download URLs and Application Services version selection remain unchanged.

Prepared-source generation still records the generated script digest, verifies
the separately locked Nimbus binary and source archive, and accepts the same
exact generated path set. This vendored input does not relax those checks.

Run the network-free cache and bootstrap checks with:

```sh
python3 -m unittest scripts.ci.tests.test_nimbus_fml_cache
```
