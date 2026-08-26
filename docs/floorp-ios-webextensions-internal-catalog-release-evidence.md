# Floorp iOS: 内部 WebExtensions カタログのリリース証跡

Status: **P1–P4 local implementation checks are recorded below. The candidate contains
16 constrained, local FWEA1 artifacts, but no managed-signer-produced catalog or root
public key yet; it therefore fails closed and must not be represented as this catalog
release. An existing TestFlight build is not source-bound to this unmerged change. No
author-approved signed artifact or physical-device result exists yet.**

この文書は package-specific evidence の保存形式である。Stage 3 の同梱 fixture 証跡を
再利用して「内部カタログの実拡張を検証済み」と記載してはならない。

## Local implementation verification (not release evidence)

| Check | Result | Scope / limitation |
| --- | --- | --- |
| `swiftc -typecheck` catalog and package-store closure | pass | Current catalog, package store, manifest, DNR, permissions, scripts, i18n, and compatibility sources. UI-only dependencies were stubbed only to make the isolated type check possible. |
| Signed catalog / FWEA1 executable harness | pass | Valid Ed25519 root/leaf catalog, tamper, expiration, device-clock and sequence rollback, generation revocation, duplicate key/non-canonical input, strict final URL, artifact/manifest mutation, ZIP magic, and traversal path all rejected fail-closed. |
| Package-store executable harness | pass | Immutable catalog install, unsupported DNR redirect rejection, digest-bound update consent requirement, revocation resource stop, and restart persistence. |
| Curated catalog construction / inspection | pass — 12 Python tests | All 16 constrained packages were normalized as FWEA1; the project-resource check proves that only `Artifacts/` is placed in the app target, never source packages or review records. This is not a signed catalog. |
| Curated package functional harness | pass — 16 / 16 | The local DOM/browser harness exercised each constrained package's declared content-script, DNR, popup/options, or alarm behavior without remote code or remote lists. |
| Signed-catalog lifecycle XCTest | pass — 61 / 61 | `FloorpWebExtensionPackageStoreTests` on iPhone 17 / iOS 26.2 covers tamper/expiry/rollback/key and generation revocation, archive/path attacks, complete-local-artifact validation, atomic replacement and failure retention, and separate private-profile installation/grants. This historical run predates the all-updates-consent tightening recorded below. Result bundle: `Test-Fennec-2026.08.27_00-02-49-+0900.xcresult`. |
| Curated DNR policy-boundary XCTest | pass — 78 / 78 | `FloorpWebExtensionPackageStoreTests` and `FloorpWebExtensionAPIHostTests` on iPhone 17 / iOS 26.2 add a catalog artifact containing otherwise Stage 3-supported `upgradeScheme`; the signed-catalog package-store boundary rejects it and leaves the profile empty. They also prove that a signed-catalog activation cannot call dynamic/session DNR bridge operations. This proves that the external curated DNR profile is static `block` only without reducing generic Stage 3 fixture coverage. Result bundle: `test_sim_2026-08-26T16-31-37-345Z_pid2383_2b659514.xcresult`. |
| P2–P4 simulator XCTest rerun | pass — 74 / 74 | iPhone 17 / iOS 26.2 の `FloorpWebExtensionsStage3Tests` (27), `FloorpWebExtensionDNRTests` (7), `FloorpWebExtensionAlarmsActionTests` (3), `FloorpWebExtensionStorageI18nTests` (13), `FloorpWebExtensionPageHostTests` (9), `FloorpWebExtensionAPIHostTests` (15) を同一実行で完走。content script の host grant/失効/all-frame/document-start、通常・private 分離、DNR の block と優先例外、popup/options/action 無しの安全な空状態、storage/alarms/native consent を含む。Result bundle: `Test-Fennec-2026.08.27_00-03-41-+0900.xcresult`. |
| Post-consent-UI arm64 rebuild and P1–P4 simulator XCTest | pass — 135 / 135 | 同意画面の version/name/site 表示を実値に直した後、iPhone 17 / iOS 26.2 の `Fennec_Testing` arm64 build と、catalog lifecycle (61) + P2–P4 (74) を同一実行で完走。Result bundle: `Test-Fennec-2026.08.27_00-19-17-+0900.xcresult`. WebKit/RBS の終了時 assertion warning はあったが、XCTest は 0 failures で完了。 |
| 16-artifact P1–P4 simulator XCTest | pass — 145 / 145 | iPhone 17 / iOS 26.2 の `Fennec_Testing` で、catalog lifecycle、content-script/private 隔離、DNR、popup/options/storage/alarms、page host、API host、および DNR site-exclusion coordinator を再実行。Result bundle: `test_sim_2026-08-26T16-10-49-102Z_pid2383_9e68246d.xcresult`。 |
| Latest P1–P4 simulator XCTest | pass — 147 / 147 | iPhone 17 / iOS 26.2 の `Fennec_Testing` で、catalog-specific static-`block` DNR、signed catalog からの dynamic/session DNR API 拒否、ならびに**同一権限を含む全 immutable generation 更新の digest-bound explicit consent**を再実行。改ざん・期限切れ・rollback・失効・原子的 generation 更新、通常/private 分離、content script、popup/options/storage/alarms/action-less menu、DNR、permission consent を同じ実行で検証した。Result bundle: `test_sim_2026-08-26T16-55-04-865Z_pid2383_9ec697f5.xcresult`。 |
| Curated catalog build/ingest/sign-script regression | pass — 12 / 12 | 16 artifact の deterministic FWEA1 構築、project resource の shipping 範囲、CRX/ZIP の quarantine、remote executable/dynamic code rejection、署名 catalog canonicalization を再確認。managed private key や署名済み release output は生成していない。 |
| Security diff scan | pass — 0 findings | `e291d57b-ac5f-454d-b1d2-83b490c45dbc`。135 review items を監査し、任意 URL/CRX/ZIP/shared-sheet 導入、remote JS/WASM/DNR list、silent update、fail-open の新規経路は確認されなかった。scan snapshot: `codex-security-snapshot/v1:sha256:b41c84b702b1f41679cf64e6bf6d67d7be6d9fbd01eebfc1fce52e87222e3c60`。その直後の補間表示修正は display-only であり、再ビルド/XCTest 済み。 |
| Previous security diff scan | pass — 0 findings | `1458eda9-9a1e-434b-9f4c-c0d13ede6244`。153 review items を source/static artifact review した。後続の static-`block` runtime 制限と `Artifacts/Signed` lookup は次行の最終 scan に含める。 |
| Latest security diff scan | pass — 0 findings | `60767d9e-f5a5-4013-9bb8-b68cee570d00`。156 review items と 7 security surfaces を final working tree で監査し、signature/digest/rollback/revocation、任意導入拒否、全 generation の native update consent、normal/private isolation、static `block`-only DNR、shipping resource、release workflow boundary に reportable finding はなかった。snapshot: `codex-security-snapshot/v1:sha256:da119415255d2014704d59a66b0bb677bbf8092d649f091567a71e61896686cb`。managed signer、P0 approvals、physical-device/TestFlight は code-scan の対象外 release gate として明記した。 |
| arm64 app-bundle resource audit | pass — 16 artifacts | iPhone 17 / iOS 26.2 の `Fennec_Testing` build-and-run 後、`Client.app` は 16 個の `Artifacts/*.fwea1`、`Packages`/`Review`/`catalog-input.json`/`catalog-sources.json` は 0 件、`catalog.json`/`root-public-key.txt` は 0 件だった。起動ログは欠落した署名資源を理由に catalog を fail closed で無効化し、クラッシュしなかった。Build log: `build_run_sim_2026-08-26T16-08-23-955Z_pid2383_1c82dc87.log`。 |
| Latest arm64 app-bundle resource audit | pass — 16 artifacts / fail closed | iPhone 17 / iOS 26.2 の `Fennec_Testing` を build-and-run 後、`Client.app/Artifacts` は 16 個の `.fwea1` のみ、`Artifacts/Signed/` の managed-signer public output は 0、ZIP/XPI/CRX、source packages、`catalog-input.json`、`catalog-sources.json`、license/review records は 0 件だった。起動ログは `signed bundled WebExtensions catalog unavailable: ... resources are missing` を記録し、catalog を無効化したまま onboarding 画面まで正常起動した。Build log: `build_run_sim_2026-08-26T16-57-12-932Z_pid2383_f2e5a535.log`。 |
| Missing-signature simulator launch | pass — fail closed | The built app installed and launched on iPhone 17 / iOS 26.2. Bootstrap logged `signed bundled WebExtensions catalog unavailable: ... resources are missing`; no catalog item became available and the app did not crash. |
| XcodeBuildMCP simulator XCTest (`Fennec_Testing`) | pass — 46 / 46 | `ClientTests/FloorpWebExtensionPackageStoreTests` was compiled and run on iPhone 17 Pro / iOS 26.5. It covers the catalog verifier, P0 remote-source gate, FWEA1 decoder, direct artifact-record digest bypass rejection, atomic package transaction, unsupported DNR rejection, revocation ordering, digest-bound update consent, and profile-scoped native optional permission consent. Result bundle: `test_sim_2026-08-25T20-22-09-710Z_pid58637_0aacbb2a.xcresult`. |
| WebKit content-script / DNR simulator XCTest | pass — 34 / 34 | `FloorpWebExtensionsStage3Tests` and `FloorpWebExtensionDNRTests` on the same simulator: normal/private policy separation, host-grant enforcement, document-start/all-frame fail-closed behavior, live DNR replacement/removal, and unsupported DNR behavior. Result bundle: `test_sim_2026-08-25T20-24-21-824Z_pid58637_85f5982e.xcresult`. |
| Popup/options/storage/alarms/permission simulator XCTest | pass — 40 / 40 | `FloorpWebExtensionAlarmsActionTests`, `FloorpWebExtensionStorageI18nTests`, `FloorpWebExtensionPageHostTests`, and `FloorpWebExtensionAPIHostTests`: action-less popup empty state, options package origin, normal/private storage isolation, alarms, profile-scoped API host, and stale-generation consent rejection. Result bundle: `test_sim_2026-08-25T20-24-52-874Z_pid58637_9725acac.xcresult`. |
| Native DNR simulator measurement | pass — record-only | 5,000 reviewed fixture rules; 7 fresh-transform samples on iPhone 17 / iOS 26.2: median 176.82 ms, mean 175.88 ms, p95 179.37 ms. All 5,000 compiled, were transformed, and none was rejected. The record explicitly leaves WebKit compilation, page load, and memory-pressure recovery unmeasured; it is not device or release evidence. Result bundle: `test_sim_2026-08-26T16-13-40-174Z_pid2383_ec1ce54f.xcresult`; simulator evidence: `native-dnr-9e9212ab-a2bf-41e3-89cc-ca4a38ed1828/native-dnr-transform.json`. |
| Simulator memgraph attempt | not measured / blocked | A live iPhone 17 simulator capture for `app.floorp.Floorp` failed before producing a memgraph because `leaks` could not obtain DYLD task information (`os/kern` failure 5). The failure log and metadata are retained under `/tmp/floorp-catalog-memgraph.q2PjZr/`; this is not evidence that memory is safe. A physical-device Instruments/memory-pressure run after signed TestFlight installation remains required. |
| Project-condition source compile | pass | The same `Fennec_Testing` XCTest invocation compiled the `Client` target and the complete `ClientTests` target after the catalog metadata compatibility correction. This is a simulator build result, not an archive or release validation. |

These checks exercise implementation boundaries only. They do not replace the signed
production artifact, normal/private physical-device matrix, accessibility, performance,
or release evidence required below.

## Release-direction record

| Item | Record |
| --- | --- |
| requester direction | 2026-08-26: continue toward release through the established GitHub Actions workflow; defer the pre-distribution physical-device pass to TestFlight installation. |
| candidate adoption | 2026-08-27: Floorp iOS maintainer approved the displayed 16 fixed, app-bundled extensions for the first External TestFlight candidate and authorized managed catalog signing plus Beta App Review submission only after normal review, CI, and the regular `main` integration path. This does not approve any P0 owner gate. |
| effect on acceptance | This authorizes the candidate-validation sequence only. P5 is not complete until the TestFlight-installed physical-device, accessibility, performance, battery, and revocation results are recorded. |
| source-integrity rule | A pre-existing TestFlight build cannot be reused unless its exact source SHA equals the merged release SHA and all package-specific gates are approved. |

## Source binding

| 項目 | 記録 |
| --- | --- |
| main merge SHA | 未記録 |
| release-candidate workspace / base | `codex/floorp-curated-extension-catalog` の local SSH-signed commit（未push）/ `origin/main` `c7c8490af409cc1ff99bec2f576cd8eea3ff739a`。この commit は通常 review、CI、正規 merge と managed signer output の後に初めて External TestFlight source candidate になる。 |
| catalog ID / sequence / signing key ID | 未記録 |
| catalog canonical digest | 未記録 |
| artifact SHA-256 / manifest SHA-256 / inventory SHA-256 | 未記録 |
| artifact author / provenance / redistribution authorization | 未記録 |
| approved reviewers (Product, Security, Legal/Privacy) | 未記録 |

## Required functional evidence per artifact

| Area | Normal profile | Private profile | Required result |
| --- | --- | --- | --- |
| Content script / site access | 未記録 | 未記録 | allowed site だけで固定 resource が実行され、撤回・disable・uninstall・generation replacement・revocation 後は停止する。 |
| DNR static/dynamic/session | 未記録 | 未記録 | curated artifact は static `block` rule だけを有効化し、redirect/header/allow/allowAll/upgrade/matched-rule feedback と dynamic/session DNR API は導入・実行とも拒否する。 |
| Popup/options/action-less menu | 未記録 | 未記録 | popup/options は immutable package origin のみを使用し、action 未宣言時は安全な空状態でクラッシュしない。 |
| storage/alarms | 未記録 | 未記録 | normal/private のデータを混在させず、disable/update/revocation/uninstall の保持・削除が承認済みポリシーどおりである。 |
| optional permission | 未記録 | 未記録 | native consent が同一 enabled generation だけに適用され、cancel、stale generation、表示不能は拒否する。 |

## Security and rollback exercise

| Case | Result | Evidence link / SHA |
| --- | --- | --- |
| catalog signature / leaf chain / audience failure | 未記録 | 未記録 |
| expiration / device clock rollback / sequence rollback | 未記録 | 未記録 |
| artifact digest / manifest digest / inventory digest mismatch | 未記録 | 未記録 |
| FWEA malformed input, ZIP magic, path collision, oversized/truncated payload | 未記録 | 未記録 |
| failed update retains prior active generation | 未記録 | 未記録 |
| key and generation revocation stops runtime/DNR/page origin | 未記録 | 未記録 |

## Device, accessibility, and performance evidence

| Measurement | Device / iOS | Method | Result | Artifact |
| --- | --- | --- | --- | --- |
| install / preflight latency | 未記録 | 未記録 | 未記録 | 未記録 |
| DNR compile / page load impact | iPhone 17 Pro simulator / iOS 26.5 | 5,000-rule native transform, 7 samples | 186.46 ms median; no page-load measurement | record-only XCTest; no physical-device or release artifact |
| memory and battery impact | 未記録 | 未記録 | 未記録 | 未記録 |
| VoiceOver, Dynamic Type, contrast, consent controls | 未記録 | 未記録 | 未記録 | 未記録 |
| physical-device regression after TestFlight install | 未記録 | 未記録 | 未記録 | 未記録 |

## TestFlight record

| Item | Status |
| --- | --- |
| prior GitHub Actions / Xcode Cloud invocation | `Floorp TestFlight Deploy (Xcode Cloud)` run `32879372157` completed successfully on 2026-08-25 for `main` SHA `9898ddb598cdee27ea60c9b138af0dc6d9759e75`. App Store Connect confirms the resulting Xcode Cloud build 59 as successful and bound to that same commit; it predates and does not contain this candidate. |
| current External TestFlight build observation | 2026-08-27 の読み取り確認では、`Floorp TestFlight Deploy (Xcode Cloud)` run `32966424126` が `main` SHA `c7c8490af409cc1ff99bec2f576cd8eea3ff739a` から成功しており、App Store Connect の 0.2.0 (61) は `Floorp External`（4 testers）で `テスト中`。ただしこの build の tester notes は Stage 3 fixture-only と明示し、署名済み curated catalog / 16 artifact を含む候補ではない。従って本リリースの証跡・審査提出・実機テストに再利用しない。 |
| App Store Connect observation | 2026-08-26: iOS 0.2.0 (59) is `提出準備完了` / ready to submit with zero assigned groups and zero individual testers. It is source-bound to `9898ddb…`, not to the catalog candidate, so it is not release evidence for this change. |
| prior external build | 0.2.0 (58) is already testing in the existing external group; it is unrelated to this change and is not used as evidence. |
| Beta App Review information | Existing notes state that extensions are disabled. They are not valid for this candidate; no information was edited or submitted. |
| workflow / Xcode Cloud run for this source | not started — requires the merged exact main SHA **and** managed signer output in `Artifacts/Signed/catalog.json` and `Artifacts/Signed/root-public-key.txt`; current app bundle audit correctly found neither file. |
| build number / processed build for this source | not available |
| External TestFlight group for this source | not selected; group assignment and Beta App Review submission require a source-bound build and action-time release confirmation |
| Beta App Review | not submitted |
| tester installation and retest | not performed — will be the requested physical-device validation after a source-bound TestFlight candidate is available |

External TestFlight may be entered only after every entry marked `未記録` above is completed and
the release gates in [release gates](floorp-ios-webextensions-internal-catalog-release-gates.md)
are approved.
