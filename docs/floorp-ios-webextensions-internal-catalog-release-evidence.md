# Floorp iOS: 内部 WebExtensions カタログのリリース証跡

Status: **The current source candidate contains only Dark Reader. Its regenerated
input and artifact inventory are recorded below; managed signing, exact-candidate
approval, normal PR/CI integration, and release validation remain pending. All
17-package signature, build, and TestFlight rows are historical and must not be
used as evidence for the one-package candidate.**

この文書は package-specific evidence の保存形式である。Stage 3 の同梱 fixture 証跡を
再利用して「内部カタログの実拡張を検証済み」と記載してはならない。

## 2026-08-31 Dark Reader-only catalog supersession

The sole maintainer directed the current bundled catalog to retain only Dark
Reader. The source candidate has one record:

- `catalog-input.json`: 1 package, SHA-256
  `97e256ab134a81335d01685ba2b15e9e3a4e9f93a78cbdf8a74530275a9be5a8`;
- retained artifact: `floorp.thirdparty.darkreader` 4.9.129, generation
  `g20260826-thirdparty-darkreader`, artifact SHA-256
  `ca6b6a61ab5c46a0224919de1da2fc7b50b8904488ad0975afb22245732379d8`;
- withdrawal behavior: the next accepted higher-sequence catalog stops and
  revokes omitted installed generations. Package-owned data remains retained
  until explicit uninstall under the approved profile-isolation policy;
- release state: **managed signing pending**. The checked-in sequence-2
  17-package signature and schema-2 release approval are historical and cannot
  authorize or ship this input. Sequence 3, a new exact-candidate approval, and
  a new source-bound build are required.
- local contracts: 98 Python catalog/release-contract tests passed, and the
  immutable artifact functional harness passed 1/1.
- source provenance: the pinned Dark Reader archive SHA-256
  `b0a1af878da40dbb21544d5f8a19d15ab3120fc5c2a84f6654d795363ee88755`
  was reverified against 10 reviewed members and provenance SHA-256
  `aded4d3fec7bbf1fb5784c8e7297f69705e4cee888dd12eaae515a4371ce02f9`.

## Historical: 2026-08-28 Dark Reader MV3 supersession

All rows that name 16 artifacts/packages, sequence 1, the old catalog digest,
or its provenance/approval evidence remain historical observations only. The
then-current signed candidate was:

- `catalog-input.json`: 17 packages, SHA-256
  `feb00e6715b9021265460490203dda33ce6eeac4093d80de32211dcc89b67028`;
- Dark Reader: `floorp.thirdparty.darkreader` 4.9.129, a local fixed MV3
  compatibility build with no remote configuration/news/update channel;
- managed signature: catalog schema 3 / sequence 2, `catalog.json` SHA-256
  `230b81ba2b5dd7fde5471b05680d3d17c8fcd8e2db4ad483d6a00ee4bfa0bd6a`,
  issued `2026-08-28T16:08:02Z`, expires `2026-09-11T16:08:02Z`;
- root trust anchor: unchanged raw-key SHA-256
  `d69df8b7bda4b1a66636ef421be53b86f99f4cf38cea0f900b63b801e889f6a3`
  and root-public-key file SHA-256
  `23146d4cb799673205a0372ae6b6e319a0e0e16df744bfa5695ae2508384dee8`;
- source-bound provenance: all 14 third-party archives reverified for source
  commit `b133ab51243ae829ed24ebdd52f3fa848204ea91`; external evidence SHA-256
  `1f986e56271ca8ab63504c0128fcc261a376873709633ed19a23b8c68bcea8b7`;
- candidate-bound P0 record: canonical schema 2 record SHA-256
  `892c23ad6714458f400d4fc2aae9f213d69a10913de8ab46b323a83fabd58cdf`.

The public signed output is deliberately not considered integrated until its
separate normal PR/CI/`main` merge succeeds. This is not evidence that an older
TestFlight binary covers Dark Reader.

## Local implementation verification (current and historical; not release evidence)

| Check | Result | Scope / limitation |
| --- | --- | --- |
| Current Dark Reader-only catalog contracts | pass — 98 Python tests; functional 1 / 1 | One input, package, artifact, review tree, provenance record, workflow count, tester copy, and no production fixture resources. This is source evidence; managed sequence-3 signing remains pending. |
| Current Dark Reader provenance archive | pass — 10 reviewed members | The digest-pinned upstream archive, MIT license, reviewed source members, package manifest/notice/patch, and local derivation match the schema-2 provenance record. |
| Current catalog-omission lifecycle XCTest | pass — 1 / 1 | iPhone 17 / iOS 26.5 の `Fennec_Testing` で、higher-sequence catalog から省略された導入済み generation が即時 suspend / catalog-revoked になり、authorization が拒否されることを確認した。package と所有データは明示 uninstall まで保持され、uninstall 後に削除される。Result bundle: `test_sim_2026-08-30T16-37-52-335Z_pid19885_b7f33696.xcresult`. |
| Current source-phase app-bundle resource audit | pass — one FWEA1, no fixtures | Simulator build の `Client.app/Artifacts` に `thirdparty-darkreader.fwea1` 1件と signed resources だけが存在し、3 test fixture と他の FWEA1 は存在しない。signed `catalog.json` は旧 sequence 2 のため、この source-phase build は release candidate ではない。one-package release verifier が package-count mismatch で拒否することを確認しており、sequence 3 への置換まで fail closed が必須である。 |
| `swiftc -typecheck` catalog and package-store closure | pass | Current catalog, package store, manifest, DNR, permissions, scripts, i18n, and compatibility sources. UI-only dependencies were stubbed only to make the isolated type check possible. |
| Signed catalog / FWEA1 executable harness | pass | Valid Ed25519 root/leaf catalog, tamper, expiration, device-clock and sequence rollback, generation revocation, duplicate key/non-canonical input, strict final URL, artifact/manifest mutation, ZIP magic, and traversal path all rejected fail-closed. |
| Package-store executable harness | pass | Immutable catalog install, unsupported DNR redirect rejection, digest-bound update consent requirement, revocation resource stop, and restart persistence. |
| Historical curated catalog construction / inspection | pass — 57 Python tests | The then-current 17-package input was normalized and inspected. It is superseded by the one-package checks above. |
| Historical curated artifact functional harness | pass — 17 / 17 | The then-current 17 artifacts passed their local smoke paths. This does not cover or authorize the current candidate. |
| Historical signed-catalog lifecycle XCTest | pass — 61 / 61 | `FloorpWebExtensionPackageStoreTests` on iPhone 17 / iOS 26.2 covers tamper/expiry/rollback/key and generation revocation, archive/path attacks, complete-local-artifact validation, atomic replacement and failure retention, and separate private-profile installation/grants. Superseded as the current lifecycle evidence by the 65/65 run below. Result bundle: `Test-Fennec-2026.08.27_00-02-49-+0900.xcresult`. |
| Curated DNR policy-boundary XCTest | pass — 78 / 78 | `FloorpWebExtensionPackageStoreTests` and `FloorpWebExtensionAPIHostTests` on iPhone 17 / iOS 26.2 add a catalog artifact containing otherwise Stage 3-supported `upgradeScheme`; the signed-catalog package-store boundary rejects it and leaves the profile empty. They also prove that a signed-catalog activation cannot call dynamic/session DNR bridge operations. This proves that the external curated DNR profile is static `block` only without reducing generic Stage 3 fixture coverage. Result bundle: `test_sim_2026-08-26T16-31-37-345Z_pid2383_2b659514.xcresult`. |
| P2–P4 simulator XCTest rerun | pass — 74 / 74 | iPhone 17 / iOS 26.2 の `FloorpWebExtensionsStage3Tests` (27), `FloorpWebExtensionDNRTests` (7), `FloorpWebExtensionAlarmsActionTests` (3), `FloorpWebExtensionStorageI18nTests` (13), `FloorpWebExtensionPageHostTests` (9), `FloorpWebExtensionAPIHostTests` (15) を同一実行で完走。content script の host grant/失効/all-frame/document-start、通常・private 分離、DNR の block と優先例外、popup/options/action 無しの安全な空状態、storage/alarms/native consent を含む。Result bundle: `Test-Fennec-2026.08.27_00-03-41-+0900.xcresult`. |
| Post-consent-UI arm64 rebuild and P1–P4 simulator XCTest | pass — 135 / 135 | 同意画面の version/name/site 表示を実値に直した後、iPhone 17 / iOS 26.2 の `Fennec_Testing` arm64 build と、catalog lifecycle (61) + P2–P4 (74) を同一実行で完走。Result bundle: `Test-Fennec-2026.08.27_00-19-17-+0900.xcresult`. WebKit/RBS の終了時 assertion warning はあったが、XCTest は 0 failures で完了。 |
| 16-artifact P1–P4 simulator XCTest | pass — 145 / 145 | iPhone 17 / iOS 26.2 の `Fennec_Testing` で、catalog lifecycle、content-script/private 隔離、DNR、popup/options/storage/alarms、page host、API host、および DNR site-exclusion coordinator を再実行。Result bundle: `test_sim_2026-08-26T16-10-49-102Z_pid2383_9e68246d.xcresult`。 |
| Historical P2–P4 simulator XCTest | pass — 147 / 147 | iPhone 17 / iOS 26.2 の `Fennec_Testing` で、catalog-specific static-`block` DNR、signed catalog からの dynamic/session DNR API 拒否、改ざん・期限切れ・rollback・失効・原子的 generation 更新、通常/private 分離、content script、popup/options/storage/alarms/action-less menu、DNR、permission consent を検証した。現行の全更新同意必須 policy は下記の current runs により再検証している。Result bundle: `test_sim_2026-08-26T16-55-04-865Z_pid2383_9ec697f5.xcresult`。 |
| Historical signed-catalog lifecycle XCTest | pass — 65 / 65 | iPhone 17 / iOS 26.2 の `Fennec_Testing` で `FloorpWebExtensionPackageStoreTests` を再実行。署名・期限・clock/sequence rollback・key/generation revocation・FWEA1/digest/path attack・atomic update/復旧・normal/private 分離・DNR 拒否を確認した。権限差分が空でも digest-bound native confirmation が必須で、cancel は旧 generation を維持し、同値・旧 semantic version は確認前に reject する。導入済み設定表示が、署名済み provenance（description/source/revision/license/homepage/generation）だけを露出し、artifact location を渡さないことも確認した。Result bundle: `Test-Fennec-2026.08.27_05-07-03-+0900.xcresult`。新しい Settings fail-closed と managed-signing handoff は後続 run で再検証中。 |
| Historical signed-catalog lifecycle XCTest | pass — 67 / 67 | iPhone 17 / iOS 26.2 の `Fennec_Testing` で `FloorpWebExtensionPackageStoreTests` を再実行。従来の P1 lifecycle coverage に加え、Settings は signed catalog の取得完了前に fixture を表示せず非選択の loading row だけを表示すること、production default composition は unsigned fixture catalog を導入できないことを確認した。初回の test-only theme dependency crash は明示注入へ修正後に解消した。Result bundle: `Test-Fennec-2026.08.27_13-38-34-+0900.xcresult`。 |
| Historical P2–P4 simulator XCTest | pass — 76 / 76 | 最新の provenance/update-history UI を含む `Fennec_Testing` を iPhone 17 / iOS 26.2 で再ビルドし、`FloorpWebExtensionsStage3Tests` (28)、`FloorpWebExtensionDNRTests` (7)、`FloorpWebExtensionAlarmsActionTests` (3)、`FloorpWebExtensionStorageI18nTests` (13)、`FloorpWebExtensionPageHostTests` (9)、`FloorpWebExtensionAPIHostTests` (16) を同一実行で完走。content script の host grant/失効/all-frame/document-start、通常/private 分離、static-block DNR と非対応 action 拒否、popup/options/action 無しの安全な空状態、storage/alarms/native consent を含む。Result bundle: `Test-Fennec-2026.08.27_05-11-28-+0900.xcresult`。 |
| Historical P2–P4 simulator XCTest | pass — 76 / 76 | UI fail-closed と managed signing handoff の修正後、iPhone 17 / iOS 26.2 の `Fennec_Testing` で同じ 6 suites を再実行。content script の host grant/失効/all-frame/document-start、通常/private 分離、static-block DNR と非対応 action 拒否、popup/options/action 無しの安全な空状態、storage/alarms/native consent を確認。Result bundle: `Test-Fennec-2026.08.27_13-42-01-+0900.xcresult`。 |
| Historical pre-Dark Reader catalog build/ingest and signing-handoff regression | pass — 34 / 34; deterministic 16 / 16 | This row records the prior 16-package contract only. The later 17-package input was independently covered by the historical checks below. |
| Historical unsigned-tree release-contract check | pass — fail closed | signed output 導入前に `verify_signed_curated_catalog_release.py` を unsigned catalog root に対して実行し、`Artifacts/Signed/catalog.json` が存在しないため release candidate を拒否することを確認した。これは署名済み候補の成功証跡ではなく、unsigned artifacts が TestFlight workflow を通過しないことの証跡である。 |
| TestFlight release-workflow contract | pass — local contract tests | 任意 `catalog_release` switch を通常 TestFlight workflow に足す方式は、switch を外すと verifier を通らず mutation へ到達できるため撤回した。通常 workflow と候補 workflow を分離し、candidate は protected annotated `floorp-catalog-*` tag、`main` 到達確認、root-key digest と fixed one-package verifier の Apple credential 前実行、tag-only `sourceBranchOrTag`、強制 `--wait` と completed-run source SHA readback を要求する。candidate workflow は external group/Beta App Review mutation を含まない。通常の `Build and unit test` には鍵を要しない catalog build/documentation/provenance/ingest/resource/workflow contract と one-artifact functional harness を含む。実際の protected secret、Xcode Cloud invocation、または App Store Connect mutation は行っていない。 |
| Historical candidate-source control regression | pass — release 65 / 65; catalog 34 / 34; functional 16 / 16 | 2026-08-27: exact annotated SHA tag / current-main / canonical tag-kind guard、signed-catalog verifier-before-credentials、external submission separation、Xcode Cloud `sourceBranchOrTag` resolution を再実行した。これは local control evidence であり、Xcode Cloud/App Store Connect の実行証跡ではない。 |
| Historical pre-Dark Reader exact-main non-secret contract rerun | pass — 90 Python tests; functional 16 / 16 | 2026-08-28 に `ab6235fd7c6694aa97217d1626411ef0af0a3796` の clean checkout で実行した、旧 16-package candidate の証跡。後続の 17-package candidate にも現在の one-package candidate にも流用しない。 |
| Dark Reader source integration CI | pass — PR #142 | `b133ab51243ae829ed24ebdd52f3fa848204ea91` が通常 PR #142 として main に merge され、required `Validate workflows` と `Build and unit test` が成功した。signed public output は別の通常 PR/CI を通す。 |
| Actual managed signing, release verification, and P0 record | pass — 17 packages | 2026-08-28、clean `main` `b133ab51243ae829ed24ebdd52f3fa848204ea91` で、1Password SSH Agent の non-export root/leaf signer を使い catalog schema 3 / sequence 2 を署名した。public `catalog.json` SHA-256 は `230b81ba2b5dd7fde5471b05680d3d17c8fcd8e2db4ad483d6a00ee4bfa0bd6a`、root raw-key SHA-256 は pinned `d69df8b7bda4b1a66636ef421be53b86f99f4cf38cea0f900b63b801e889f6a3`、issued/expires は `2026-08-28T16:08:02Z` / `2026-09-11T16:08:02Z`。14 archive provenance evidence SHA-256 は `1f986e56271ca8ab63504c0128fcc261a376873709633ed19a23b8c68bcea8b7`、release verifier evidence SHA-256 は `24ea39e2f77cc07d01327f898e9b34faab86ff2b0144f705326e2e661ace9f35`、P0 approval record SHA-256 は `892c23ad6714458f400d4fc2aae9f213d69a10913de8ab46b323a83fabd58cdf`、approval-verifier evidence SHA-256 は `715199edaa3c72c569b7a528f32eecb3c169e085965d86ba26657697f3be6fa9`。秘密鍵を GitHub、Xcode Cloud、app bundle、ログに置いていない。 |
| Historical Dark Reader native MV3 regression XCTest | pass — 49 / 49 | storage/i18n、MV3 API host、runtime message の当時の source suites を実行し、0 failures を確認した。これは sequence-2 17-package candidate の記録であり、現在の one-package source candidate の署名・app-bundle・physical-device/P5 evidence を代替しない。 |
| Historical signed-candidate P1–P4 simulator XCTest | pass — 149 / 149 | iPhone 17 / iOS 26.2 の新規 build (`Fennec_Testing`, FloorpCI)で package-store、content-script/private isolation、DNR、alarms/action、storage/i18n、page host、API host suites を実行し、149 passed / 0 failed / 0 skipped。これは prior signed candidate の証跡であり、現在の one-package app-bundle candidate の代替ではない。 |
| Historical signed-candidate app-bundle resource audit | pass — 16 artifacts + 2 signed resources | 同じ arm64 simulator build の prior 16-package candidate の証跡。現在の one-package signed public output の app-bundle audit は tag-bound candidate build 後に記録する。 |
| Historical candidate-source security diff scan | pass — 0 findings | 2026-08-27 sealed scan `59a67bc9-776a-43c0-b227-6ac1f8477f29`、snapshot `codex-security-snapshot/v1:sha256:2252558baf24bc7f9d7e12e9d72afbaa467b14a425bafb1354555783d8fdf021`。candidate GitHub/Xcode source binding、reference kind/canonical namespace、credential ordering、external mutation separation、signed runtime/atomic lifecycle/profile/DNR boundaryを含む 25 changed surfaces をレビューした。Apple、managed signer、GitHub/Xcode Cloud policy、物理実機、External TestFlight は source-scan 対象外の release gate であり、合格と解釈してはならない。 |
| Very Good AdBlock source-provenance recheck | historical local observation — not release evidence | 過去のローカル再照合として pinned archive SHA-256 `1f7e2a0560a2d5e606893993a470a342d21ed314ae5d94a9ec468259283f3fc4`、固定 tar member、LICENSE、16 件の source-to-static-`block` DNR mapping、provenance record SHA-256 `aadac25787260fcaa76cf7091cabdcace4528db204e5d33b4fa6ace803621079` を記録している。ただし candidate に束縛された archive input / signer-produced provenance evidence がないため、署名または外部配布の証跡にはならない。managed signer が同じ確認を実 archive とともに出力するまでゲートは blocked のままとする。 |
| Independent security re-review | pass — static review | 新しい Settings 初期表示、production default composition、Very Good AdBlock source provenance、managed signing handoff を独立再レビュー。最初に見つかった unsigned fixture の表示余地、別 checkout の catalog 署名余地、input re-read TOCTOU を修正し、最終確認では新たな High/Medium runtime boundary regression はなし。任意 URL/CRX/ZIP/shared-sheet 導入、remote JS/WASM/DNR list、silent update、fail-open は追加されていない。実 archive を使う managed signer 実行と Swift XCTest の独立再実行はこのレビューの範囲外。 |
| Previous security diff scan | pass — 0 findings | `1458eda9-9a1e-434b-9f4c-c0d13ede6244`。153 review items を source/static artifact review した。後続の static-`block` runtime 制限と `Artifacts/Signed` lookup は次行の最終 scan に含める。 |
| Historical pre-merge security diff scan | pass — 0 findings | `849db58a-941f-4dbd-8f5a-dbae175739ff`。最終ステージ済み working-tree snapshot を 5 review items / 7 security surfaces で再監査し、任意 URL/CRX/ZIP/shared-sheet 導入、remote JS/WASM/DNR list、silent update、fail-open の新規経路は確認されなかった。同値・旧 semantic version、欠落/取消/stale consent、改ざん artifact は fail closed であり、normal/private restore と atomic journal も維持される。actual managed signing、physical-device/P5、External TestFlight は明示的な code-scan 対象外 release gate である。sealed scan report: `report.md`、snapshot: `codex-security-snapshot/v1:sha256:5c0c731dcac57bd46efd08fb4bf93b8472f2a0603008d5b37ed0bb71dd61532a`。 |
| Sole-maintainer P0 governance security diff scan | pass — 0 findings | 2026-08-28 sealed scan `bfeca104-0d02-4732-8429-403754cde5dc`。schema 2 の canonical single-`maintainerApproval`、protected digest、verified catalog fields、workflow credential ordering、P0 policy と MIT/license/notice/provenance assertions、固定同梱 runtime boundary を complete coverage でレビューした。actual environment secret/protection、managed signing、実 archive、P5、Apple 実審査は repository source 外の gate である。 |
| Managed-signing/provenance security diff scan | pass — 0 reportable findings | `c63ac7e0-599c-4f52-962e-b0b1a539e7c6`。21 review items / 6 security surfaces を監査。review-only archive parser と external evidence output の候補は、digest-pinned clean checkout と authorized local signer path を根拠に外部攻撃経路ではないと判定したが、後続で archive resource bound と no-overwrite を実装した。この scan はその hardening 前の snapshot なので、最終 merge 前には hardening を含む current diff を再スキャンする。sealed scan report: `/private/var/folders/f_/12lnwl4j4tqddkryz5zkjkjr0000gn/T/codex-security-scans-0xwYEL/floorp-curated-extension-catalog/940118d86a3966932881cac5dd46c7b6071dfc00_20260827T044832Z_utqys6uv/report.md`。 |
| Final pre-merge security diff scan | pass — 0 findings | `0d734226-7644-4145-9b7c-358331de79fb`。hardening 後の working-tree snapshot を 21 review items / 6 security surfaces で再監査。署名/rollback/revocation/digest、private 分離、fixture 非表示、static-DNR、provenance archive bound、managed signer no-overwrite を確認し、任意 URL/CRX/ZIP/shared-sheet 導入、remote executable/list、silent update、fail-open の新規経路は確認されなかった。P0/P5 の human gate は code-scan の対象外である。sealed scan report: `/private/var/folders/f_/12lnwl4j4tqddkryz5zkjkjr0000gn/T/codex-security-scans-0xwYEL/floorp-curated-extension-catalog/940118d86a3966932881cac5dd46c7b6071dfc00_20260827T050147Z_llo9kg80/report.md`; snapshot: `codex-security-snapshot/v1:sha256:a84e8da3443d42101b4bd8178dc640dc02160b10a8a9d35ebfc0861b4b819b95`。 |
| arm64 app-bundle resource audit | pass — 16 artifacts | iPhone 17 / iOS 26.2 の `Fennec_Testing` build-and-run 後、`Client.app` は 16 個の `Artifacts/*.fwea1`、`Packages`/`Review`/`catalog-input.json`/`catalog-sources.json` は 0 件、`catalog.json`/`root-public-key.txt` は 0 件だった。起動ログは欠落した署名資源を理由に catalog を fail closed で無効化し、クラッシュしなかった。Build log: `build_run_sim_2026-08-26T16-08-23-955Z_pid2383_1c82dc87.log`。 |
| Historical arm64 app-bundle resource audit | pass — 16 artifacts / fail closed | iPhone 17 / iOS 26.2 の `Fennec_Testing` を build-and-run 後、`Client.app/Artifacts` は 16 個の `.fwea1` のみ、`Artifacts/Signed/` の managed-signer public output は 0、ZIP/XPI/CRX、source packages、`catalog-input.json`、`catalog-sources.json`、license/review records は 0 件だった。起動ログは `signed bundled WebExtensions catalog unavailable: ... resources are missing` を記録し、catalog を無効化したまま onboarding 画面まで正常起動した。Build log: `build_run_sim_2026-08-26T16-57-12-932Z_pid2383_f2e5a535.log`。 |
| Historical arm64 app-bundle resource audit | pass — 16 artifacts / fail closed | UI fail-closed 修正後の iPhone 17 / iOS 26.2 `Fennec_Testing` build product を再監査した prior unsigned candidate の記録。現在の one-package managed signer output の app-bundle audit は tag-bound candidate build 後に記録する。 |
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
| current requester direction | 2026-08-31: retain only Dark Reader in the current bundled catalog and prioritize richer extensions for future separately reviewed additions. This authorizes the composition change, not TestFlight or External submission of an unsigned candidate. |
| requester direction | 2026-08-26: continue toward release through the established GitHub Actions workflow; defer the pre-distribution physical-device pass to TestFlight installation. |
| historical candidate adoption and P0 authority | 2026-08-28: the sole Floorp iOS maintainer approved the then-current fixed 17-extension candidate. That composition and exact approval are superseded and cannot authorize the current one-package candidate. |
| effect on acceptance | This authorizes the candidate-validation sequence only. P5 is not complete until the TestFlight-installed physical-device, accessibility, performance, battery, and revocation results are recorded. |
| source-integrity rule | A pre-existing TestFlight build cannot be reused unless its exact source SHA equals the merged release SHA and all package-specific gates are approved. |
| release-path reassessment | 2026-08-27: an optional signed-catalog switch on the ordinary TestFlight workflow was rejected because it left an ungated mutation path. The candidate now requires a separate protected annotated `floorp-catalog-<40 lowercase commit SHA>` tag whose name, tag commit, checkout, and current `origin/main` HEAD agree. Xcode Cloud additionally rejects a candidate before `xcodebuild` unless its actual `CI_GIT_REF`/`CI_TAG`/`CI_COMMIT`, approved manual workflow/bundle ID, checkout, and freshly fetched `origin/main` agree; terminal source-commit readback remains a second check. This still does not authorize external group assignment or Beta App Review submission. |
| GitHub protection readback | 2026-08-28: active repository tag ruleset `21688477` protects `floorp-catalog-*` against deletion and non-fast-forward update with no bypass actor. Candidate and external-release environments each accept only `floorp-catalog-*` tags and have administrator bypass disabled. This is a technical source/credential boundary, not a substitute for the sole maintainer's P0 authority. |

## Historical sequence-2 source binding

| 項目 | 記録 |
| --- | --- |
| main merge SHA | `ab6235fd7c6694aa97217d1626411ef0af0a3796` — normal merge of PR #139. The current-main `Floorp iOS CI` run `33123110415` completed successfully; the forthcoming signed-output PR will require its own normal CI before candidate dispatch. |
| protected candidate tag / tag policy evidence | tag is not yet created. Required form remains annotated `floorp-catalog-<40 lowercase commit SHA>` for the then-current exact `main` HEAD. Active repository ruleset `21688477` blocks deletion and force update for `floorp-catalog-*`; no actor can bypass it. |
| release-candidate workspace / base | clean exact `main` `ab6235fd7c6694aa97217d1626411ef0af0a3796`; the immutable public signer output was byte-compared before being staged in a separate normal public-output PR branch. |
| catalog ID / sequence / signing key ID | `floorp-ios-curated-testflight` / `2` / `floorp-catalog-leaf-2026-08`; catalog schema 3, issuer root `floorp-catalog-root-2026-08`, app bundle `app.floorp.Floorp`, channel `testflight`, minimum marketing version `0.3.0`. |
| catalog canonical digest | `230b81ba2b5dd7fde5471b05680d3d17c8fcd8e2db4ad483d6a00ee4bfa0bd6a`; issued `2026-08-28T16:08:02Z`, expires `2026-09-11T16:08:02Z`. |
| artifact SHA-256 / manifest SHA-256 / inventory SHA-256 | all 16 signed catalog records were checked by the release verifier against the exact app resources and artifact origin; verifier result SHA-256 `1a2a6d49977ed567dbd68070cd5557d4ef6a8e6fa388ac889857834afcf2fff6`. |
| third-party provenance / redistribution basis | 13 compatibility builds: verified MIT license, local `LICENSE`/`NOTICE`, pinned source provenance, and exact candidate archive re-verification during managed signing; external provenance evidence SHA-256 `dbc6b0f5701a9c0d96a39347768a5cc28aa11846a373fb57853e47a0946a0213`. |
| P0 approval authority | sole Floorp iOS maintainer policy receipt plus exact signed candidate schema 2 `maintainerApproval` record; canonical record SHA-256 `892c23ad6714458f400d4fc2aae9f213d69a10913de8ab46b323a83fabd58cdf`. |

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

2026-08-27 の local device discovery では接続済み iPhone/iPad は 0 台だった。Simulator
結果や Apple Distribution identity の存在は、TestFlight-installed physical-device evidence を
代替しない。

## TestFlight record

| Item | Status |
| --- | --- |
| prior GitHub Actions / Xcode Cloud invocation | `Floorp TestFlight Deploy (Xcode Cloud)` run `32879372157` completed successfully on 2026-08-25 for `main` SHA `9898ddb598cdee27ea60c9b138af0dc6d9759e75`. App Store Connect confirms the resulting Xcode Cloud build 59 as successful and bound to that same commit; it predates and does not contain this candidate. |
| current External TestFlight build observation | 2026-08-27 の読み取り確認では、`Floorp TestFlight Deploy (Xcode Cloud)` run `32966424126` が `main` SHA `c7c8490af409cc1ff99bec2f576cd8eea3ff739a` から成功しており、App Store Connect の 0.2.0 (61) は `Floorp External`（4 testers）で `テスト中`。ただしこの build の tester notes は Stage 3 fixture-only と明示し、署名済み curated catalog / 17 artifact を含む候補ではない。従って本リリースの証跡・審査提出・実機テストに再利用しない。 |
| App Store Connect observation | 2026-08-26: iOS 0.2.0 (59) is `提出準備完了` / ready to submit with zero assigned groups and zero individual testers. It is source-bound to `9898ddb…`, not to the catalog candidate, so it is not release evidence for this change. |
| prior external build | 0.2.0 (58) is already testing in the existing external group; it is unrelated to this change and is not used as evidence. |
| current candidate tester / reviewer materials | prepared, not submitted | `WhatToTest.en-US.txt` / `ja-JP.txt` と Beta App Review draft は Dark Reader-only の手順へ更新済み。sequence-3 exact approval、source-bound build、live reviewer contact が揃うまで提出に使わない。 |
| workflow / Xcode Cloud run for this source | not started — requires the merged exact current main SHA, protected annotated `floorp-catalog-<40 lowercase commit SHA>` tag whose name/tag commit/checkout/current `origin/main` HEAD agree, managed signer output in `Artifacts/Signed/catalog.json` and `Artifacts/Signed/root-public-key.txt`, the candidate-only release-contract success, a pre-archive Cloud check of the actual tag/ref/commit/workflow/bundle/checkout/current-main identity, and a terminal Xcode Cloud `sourceCommit` match. The root-digest secret name has been confirmed in both tag-restricted environments; its value remains unread and must match the actual signed root before dispatch. The Apple API credential required by the existing workflow is not yet present in either environment. |
| build number / processed build for this source | not available |
| External TestFlight group for this source | not selected; group assignment and Beta App Review submission require a source-bound build and action-time release confirmation |
| Beta App Review | not submitted |
| tester installation and retest | not performed — will be the requested physical-device validation after a source-bound TestFlight candidate is available |

Beta App Review submission may occur only after the signed candidate, its protected tag/build
binding, reviewer material, and the submission-specific release gates are complete. External
availability and P5 completion remain blocked until the TestFlight-installed physical-device,
accessibility, performance, battery, and revocation evidence above is recorded and the release
gates in [release gates](floorp-ios-webextensions-internal-catalog-release-gates.md) are approved.
