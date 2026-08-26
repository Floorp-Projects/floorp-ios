# Floorp iOS: 内部 WebExtensions カタログのリリース証跡

Status: **P1 local implementation checks are recorded below. An existing TestFlight build
is visible in App Store Connect, but it is not source-bound to this unmerged change and
must not be represented as this catalog release. No author-approved remote artifact or
physical-device result exists yet.**

この文書は package-specific evidence の保存形式である。Stage 3 の同梱 fixture 証跡を
再利用して「内部カタログの実拡張を検証済み」と記載してはならない。

## Local implementation verification (not release evidence)

| Check | Result | Scope / limitation |
| --- | --- | --- |
| `swiftc -typecheck` catalog and package-store closure | pass | Current catalog, package store, manifest, DNR, permissions, scripts, i18n, and compatibility sources. UI-only dependencies were stubbed only to make the isolated type check possible. |
| Signed catalog / FWEA1 executable harness | pass | Valid Ed25519 root/leaf catalog, tamper, expiration, device-clock and sequence rollback, generation revocation, duplicate key/non-canonical input, strict final URL, artifact/manifest mutation, ZIP magic, and traversal path all rejected fail-closed. |
| Package-store executable harness | pass | Immutable catalog install, unsupported DNR redirect rejection, digest-bound update consent requirement, revocation resource stop, and restart persistence. |
| XcodeBuildMCP simulator XCTest (`Fennec_Testing`) | pass — 46 / 46 | `ClientTests/FloorpWebExtensionPackageStoreTests` was compiled and run on iPhone 17 Pro / iOS 26.5. It covers the catalog verifier, P0 remote-source gate, FWEA1 decoder, direct artifact-record digest bypass rejection, atomic package transaction, unsupported DNR rejection, revocation ordering, digest-bound update consent, and profile-scoped native optional permission consent. Result bundle: `test_sim_2026-08-25T20-22-09-710Z_pid58637_0aacbb2a.xcresult`. |
| WebKit content-script / DNR simulator XCTest | pass — 34 / 34 | `FloorpWebExtensionsStage3Tests` and `FloorpWebExtensionDNRTests` on the same simulator: normal/private policy separation, host-grant enforcement, document-start/all-frame fail-closed behavior, live DNR replacement/removal, and unsupported DNR behavior. Result bundle: `test_sim_2026-08-25T20-24-21-824Z_pid58637_85f5982e.xcresult`. |
| Popup/options/storage/alarms/permission simulator XCTest | pass — 40 / 40 | `FloorpWebExtensionAlarmsActionTests`, `FloorpWebExtensionStorageI18nTests`, `FloorpWebExtensionPageHostTests`, and `FloorpWebExtensionAPIHostTests`: action-less popup empty state, options package origin, normal/private storage isolation, alarms, profile-scoped API host, and stale-generation consent rejection. Result bundle: `test_sim_2026-08-25T20-24-52-874Z_pid58637_9725acac.xcresult`. |
| Native DNR simulator measurement | pass — record-only | 5,000 reviewed fixture rules; 7 fresh-transform samples on iPhone 17 Pro simulator / iOS 26.5: median 186.46 ms, mean 186.13 ms, p95 191.13 ms. The record explicitly leaves WebKit compilation, page load, and memory-pressure recovery unmeasured; it is not device or release evidence. Result bundle: `test_sim_2026-08-25T20-25-29-066Z_pid58637_1fd5973d.xcresult`. |
| Project-condition source compile | pass | The same `Fennec_Testing` XCTest invocation compiled the `Client` target and the complete `ClientTests` target after the catalog metadata compatibility correction. This is a simulator build result, not an archive or release validation. |

These checks exercise implementation boundaries only. They do not replace the signed
production artifact, normal/private physical-device matrix, accessibility, performance,
or release evidence required below.

## Release-direction record

| Item | Record |
| --- | --- |
| requester direction | 2026-08-26: continue toward release through the established GitHub Actions workflow; defer the pre-distribution physical-device pass to TestFlight installation. |
| effect on acceptance | This authorizes the candidate-validation sequence only. P5 is not complete until the TestFlight-installed physical-device, accessibility, performance, battery, and revocation results are recorded. |
| source-integrity rule | A pre-existing TestFlight build cannot be reused unless its exact source SHA equals the merged release SHA and all package-specific gates are approved. |

## Source binding

| 項目 | 記録 |
| --- | --- |
| main merge SHA | 未記録 |
| release-candidate branch / SHA | `codex/floorp-extension-catalog-design` / `9a06e780f96d6a8decff383e8baed56303d0ab9e` (2026-08-26 に remote ref へ push 済み。main には未統合) |
| catalog ID / sequence / signing key ID | 未記録 |
| catalog canonical digest | 未記録 |
| artifact SHA-256 / manifest SHA-256 / inventory SHA-256 | 未記録 |
| artifact author / provenance / redistribution authorization | 未記録 |
| approved reviewers (Product, Security, Legal/Privacy) | 未記録 |

## Required functional evidence per artifact

| Area | Normal profile | Private profile | Required result |
| --- | --- | --- | --- |
| Content script / site access | 未記録 | 未記録 | allowed site だけで固定 resource が実行され、撤回・disable・uninstall・generation replacement・revocation 後は停止する。 |
| DNR static/dynamic/session | 未記録 | 未記録 | supported action だけが有効化され、redirect/header/allowAll/matched-rule feedback を含む artifact は導入拒否する。 |
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
| App Store Connect observation | 2026-08-26: iOS 0.2.0 (59) is `提出準備完了` / ready to submit with zero assigned groups and zero individual testers. It is source-bound to `9898ddb…`, not to the catalog candidate, so it is not release evidence for this change. |
| prior external build | 0.2.0 (58) is already testing in the existing external group; it is unrelated to this change and is not used as evidence. |
| Beta App Review information | Existing notes state that extensions are disabled. They are not valid for this candidate; no information was edited or submitted. |
| workflow / Xcode Cloud run for this source | not started — requires the merged exact main SHA |
| build number / processed build for this source | not available |
| External TestFlight group for this source | not selected; group assignment and Beta App Review submission require a source-bound build and action-time release confirmation |
| Beta App Review | not submitted |
| tester installation and retest | not performed — will be the requested physical-device validation after a source-bound TestFlight candidate is available |

External TestFlight may be entered only after every entry marked `未記録` above is completed and
the release gates in [release gates](floorp-ios-webextensions-internal-catalog-release-gates.md)
are approved.
