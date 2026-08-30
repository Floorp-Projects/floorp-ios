# Floorp iOS: 内部 WebExtensions カタログのリリースゲート

Status: **in progress — the current source candidate contains only Dark Reader.
Its one-record input and policy receipt are complete, but managed sequence-3
signing, exact-candidate schema-2 approval, normal PR/CI/`main` integration, an
immutable release tag, and source-to-build readback are pending. The historical
sequence-2 17-package signature and approval cannot authorize this candidate.**

この記録は、`floorp-ios-webextensions-internal-catalog-design.md` の P0 を実行可能な
リリース条件に変換する。未完了の項目はコードや feature flag で代替してはならない。
現時点で公開版が許可する導入元は、検証済みのアプリ同梱 catalog だけである。署名済み
catalog がない candidate では、同梱された FWEA1 であっても導入してはならない。

## 2026-08-31 Dark Reader-only supersession

- Current input: one package (`floorp.thirdparty.darkreader` 4.9.129), SHA-256
  `97e256ab134a81335d01685ba2b15e9e3a4e9f93a78cbdf8a74530275a9be5a8`.
- The current P0 policy receipt approves the one-package, app-bundled scope and
  retains the existing closed-install, profile-isolation, and key-operation
  boundaries.
- The active release approval is intentionally `pending` until the exact
  sequence-3 signed catalog exists. The old sequence-2 catalog is historical.
- Omitted installed generations stop immediately after the higher-sequence
  catalog is accepted. Their data remains until explicit uninstall.

## Historical: 2026-08-28 Dark Reader MV3 supersession

この節は、以下に残る 16-package candidate の記録を履歴として保存しつつ、現在の
release contract を明確にする。旧 catalog、provenance evidence、schema 2 approval
record、CI、または TestFlight 証跡を 17-package candidate に流用してはならない。

- Then-current signed input: 17 packages, SHA-256
  `feb00e6715b9021265460490203dda33ce6eeac4093d80de32211dcc89b67028`.
  It adds `floorp.thirdparty.darkreader` 4.9.129 as a fixed app-bundled MV3
  compatibility build; it has no catalog download, remote configuration,
  news, or extension-update channel.
- The P0 policy receipt
  [`floorp-ios-webextensions-curated-catalog-p0-policy-approval.json`](floorp-ios-webextensions-curated-catalog-p0-policy-approval.json)
  is the maintainer's approved 17-package/1Password-operation policy input.
  It is not the exact signed-candidate schema 2 approval record.
- The then-current managed signer output was sequence 2, SHA-256
  `230b81ba2b5dd7fde5471b05680d3d17c8fcd8e2db4ad483d6a00ee4bfa0bd6a`;
  its root-public-key file remains SHA-256
  `23146d4cb799673205a0372ae6b6e319a0e0e16df744bfa5695ae2508384dee8`.
  It was generated in a clean checkout of
  `b133ab51243ae829ed24ebdd52f3fa848204ea91`; its catalog-only rotation
  contract pinned the previous signed catalog and root bytes and refused a
  root-key change.
- The candidate and external workflows then required 17 packages before Apple
  credentials are used. Their protected root raw-key digest and the external
  schema 2 approval digest must be read back or registered only after normal
  public-output integration is verified.

## Historical release-direction record through 2026-08-28

- 2026-08-27: 依頼者（Floorp iOS maintainer）は、現在の 16 本の固定・同梱
  WebExtensions を初回 External TestFlight candidate として採用することを承認した。
  通常の review、CI、正規の `main` 統合を通過した後に限り、管理済み signer による
  catalog 署名と既存の正規 workflow による Beta App Review 提出も承認した。この承認は
  任意導入、remote code/list、サイレント更新、権限昇格、fail-open を許可するものではない。
- 2026-08-28: 依頼者は Floorp iOS の唯一の maintainer / P0 承認責任者として、固定・同梱
  16 package、1Password SSH Agent の鍵運用、署名済み失効運用、private mode と data-retention
  policy、既存の安全境界を承認した。13 本の第三者 compatibility build は、確認済み MIT
  license、preserved `LICENSE`/`NOTICE`、固定 source/archive provenance を再配布根拠として採用する。
  この記録は、存在しない Legal、Privacy、Security、Product、Release、または作者の別承認を
  release gate にしていた以前の表現を置換する。exact signed candidate は引き続き schema 2 の
  candidate-bound P0 record と protected digest を必要とする。非秘密の policy record は
  [`floorp-ios-webextensions-curated-catalog-p0-policy-approval.json`](floorp-ios-webextensions-curated-catalog-p0-policy-approval.json)
  に canonical JSON で保存する。
- 2026-08-26: 依頼者はリリース作業の続行を承認し、pre-distribution の実機確認を
  TestFlight インストール後の確認に繰り延べるよう指示した。
- 2026-08-27: 依頼者は、この候補について External TestFlight の Beta App Review 提出まで
  進めることを承認した。ただし、この承認は P0/P5、通常の main 統合、または Apple の
  審査可否を代替しない。
- 2026-08-26: 依頼者（maintainer）は、通常の review・CI を通過した既存の統合経路で
  `main` へマージすることを許可した。この許可は direct push、新規 PR、CI の迂回、または
  P0/P5 ゲートの免除を意味しない。
- この繰り延べは **TestFlight candidate の実機確認順序** だけを変更する。
  P5 完了、一般公開、またはリモート catalog の有効化を承認するものではない。
- App Store Connect の既存の外部グループとアクセス可能な TestFlight 画面は確認済み。
  ただし、App Store Connect へのアクセスは technical verification、license/notice/provenance、
  または Apple の実審査を代替しない。
- 2026-08-27: `origin/main` と Xcode Cloud post-clone script を読み取り確認した。既存の
  `Floorp TestFlight Deploy (Xcode Cloud)` は checkout を main SHA に照合するが、Xcode Cloud の
  `sourceBranchOrTag` には可変の `main` reference を渡す。catalog signer を呼ばず、catalog
  candidate の証跡には使えない。`Floorp Public Beta Release` は Notes Sync 用の固定版番号 workflow
  であり、本候補に流用してはならない。
- 2026-08-27: GitHub の有効 ruleset `Protect Floorp iOS main` を読み取り確認した。`main` には
  pull request、解決済み review thread、必須 status check `Validate workflows` と
  `Build and unit test` が必要であり、direct push は正規経路にならない。ruleset 自体は
  signed Git commit を要求していない。依頼者は通常 PR と follow-up public-output PR を承認しており、
  PR を作成せずにこの候補を main へ統合する経路は用いない。
- 2026-08-28: existing normal PR #139 を確認した。依頼者は通常の review/CI/main integration と
  必要な follow-up PR の作成を承認している。direct push、ruleset bypass、CI/review の省略は行わない。
- 2026-08-28: 1Password `iOS Extensions` Vault の SSH Agent には `Floorp/catalog/root` と
  `Floorp/catalog/leaf` の公開鍵が存在することを、秘密鍵を閲覧・書出しせずに確認した。root の
  raw-32-byte SHA-256 は指定済み trust anchor
  `d69df8b7bda4b1a66636ef421be53b86f99f4cf38cea0f900b63b801e889f6a3` と一致した。leaf の
  public identity は adapter の公開設定にのみ使用し、catalog signing の key ID、adapter SHA、
  rotation/revocation record は maintainer の candidate-bound P0 record に結び付ける。
- 2026-08-27: 初回 signed candidate の構成順序を再確認した。現在の Xcode Cloud workflow は
  main の完全一致 SHA を build するだけで catalog signer を呼ばない。そのため「main 統合後に
  初めて signer を動かす」と、最初の binary に signed `catalog.json` と root public key を
  同梱できない。安全な選択肢は、(a) maintainer の managed signer が review 対象の immutable artifact input を
  source-bound に署名し、その**公開出力だけ**を最初の PR に含める、または (b) infrastructure を
  先に main へ統合し、main に固定された input を署名して公開出力を第 2 PR で統合する、のいずれか
  である。private key はどちらの場合も GitHub、Xcode Cloud、app bundle に置かない。
- 2026-08-27: managed signer の handoff contract を追加し、署名対象を同一 clean Git
  checkout の `CuratedCatalog` に固定した。review-quarantined archive の再検証、検証済み
  `catalog-input.json` byte snapshot のみの署名、private key 読込直前の clean recheck、既定の
  public output path、source checkout 外の audit evidence を必須にする。これは signer 実行や
  candidate-bound maintainer record を代替しない。
- 2026-08-27: [managed-signer handoff](floorp-ios-webextensions-managed-signer.md)
  を追加した。root/leaf の非 export Ed25519 key を、checkout 外で SHA-256 固定された
  adapter の canonical stdin/stdout protocol に接続できる。adapter は private key を
  返さず、release tool は response の key ID/public key/Ed25519 signature を即時検証する。
  GitHub/Xcode Cloud に signer を置かず、public output のみを第 2 normal integration へ渡す。
- 2026-08-27: release control を再設計した。通常の `Floorp TestFlight Deploy (Xcode Cloud)` に
  任意 `catalog_release` switch を置く方式は、switch を外すだけで signed-catalog verifier を
  通らず App Store Connect mutation へ到達できるため撤回した。候補専用の
  `Floorp Curated Catalog TestFlight Candidate` は、annotated
  `floorp-catalog-<40 lowercase commit SHA>` tag のみを受け付け、tag 名・tag commit・checkout・
  現在の `origin/main` HEAD が一致すること、canonical root/leaf signature、expiry、
  固定 16 record、bundle ID/channel/marketing version、全 FWEA1 digest/inventory/manifest を
  Apple credential 前に確認する。Xcode Cloud は同じ tag からだけ起動する。post-clone gate は
  実際の `CI_GIT_REF`、`CI_TAG`、`CI_COMMIT`、manual workflow、bundle ID、checkout、再取得した
  current `origin/main` を `xcodebuild` 前に全照合し、tag move、stale main、auto start、別 workflow
  を archive 前に fail closed にする。候補は非同期実行を許さず、completed run の
  `sourceCommit.commitSha` が tag commit と異なれば fail closed する。候補 workflow 自身は外部 group
  割当・Beta App Review 提出をしない。
- この構成は GitHub の protected immutable annotated tag、Xcode Cloud の manual tag start、
  candidate build を外部 TestFlight に自動公開しない Xcode Cloud 設定を前提にする。これらは
  repository から自己証明できないため、`IMMUTABLE_CANDIDATE_REF_MISSING` と
  `EXTERNAL_SUBMISSION_PATH_MISSING` の P0 release gate に記録する。
- 2026-08-28: candidate build と External TestFlight mutation は異なる GitHub environment
  に分離した。`floorp-curated-catalog-candidate` は root trust anchor と Xcode Cloud API
  credential、`floorp-curated-catalog-external-release` はそれらに加えて P0 approval record
  digest を必要とする。repository から reviewer protection や secret value は自己証明できない。
  secret value や private key は読んでいない。未設定なら credential step より前に fail closed
  する。
- 2026-08-28: GitHub Environment API の read-only metadata で、両方の curated environment に
  `FLOORP_CURATED_CATALOG_ROOT_PUBLIC_KEY_SHA256` secret 名が存在することを確認した。secret value
  は読み取らず、署名済み root と照合するまで trust anchor は完了扱いにしない。両 environment に
  別人の required reviewer を仮定しない。候補／external の secret 分離、manual workflow、
  protected digest の scope は実在する technical control として別途確認する。
- 2026-08-28: repository ruleset `21688477` `Protect Floorp curated catalog candidate tags` を
  active にし、`refs/tags/floorp-catalog-*` の deletion と non-fast-forward update を禁止した。
  bypass actor は空で、現在の administrator も bypass できない。両 curated environment は
  `floorp-catalog-*` tag だけを受け付ける custom deployment policy に変更し、admin bypass を
  無効化した（candidate policy `58437683`、external-release policy `58437684`）。これは
  single-maintainer の責任を別人 approval に置換せず、tag 以外から credential を使わせない
  technical control である。
- 2026-08-27: Apple の現行 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
  を再確認した。3.2.2(i) は第三者 apps/extensions/plug-ins を App Store 類似または general-interest
  collection として表示する UI を明示的に不許可としている。一方 3.2.1(ii) は specific approved need
  向けの第三者 app collection を robust editorial content とともに許容し得るが、現在の 16 本は
  accessibility だけに限定されない横断的な collection であり、これを根拠に例外扱いしてはならない。
  4.7 は binary に埋め込まれていない software を対象に追加条件を置くため、app-bundled FWEA1 が
  4.7 の対象外であると自己判断する根拠にはならない。Apple の事前見解を前提にせず、技術的・
  license 上の candidate gate が通った exact 16-package build を Beta App Review に提出し、
  実際の審査結果を `EXTERNAL_REVIEW_PENDING` に記録する。

## 現在の安全な状態

- `FloorpWebExtensionFeature.managedRemoteSource` は bootstrap で有効化されない。
- 公開 UI は同梱 catalog だけを表示し、任意 URL、Chrome ウェブストア、CRX/ZIP、
  共有シート、ローカルファイルからの導入経路を持たない。
- verifier、artifact decoder、package-store の catalog transaction は P0-gated の内部
  接続点である。Dark Reader の constrained FWEA1 と review workspace はローカルで生成済みだが、
  root private key、input archive、review workspace、remote endpoint は app target に含めない。
  signed `catalog.json` と root public key が無い build はこれらの FWEA1 を受理できず、
  起動時に fail closed する。
- 失効は generation の runtime/DNR/page origin を停止し、別 artifact や古い generation
  を自動選択しない。`storage.local` と dynamic DNR state は明示的 uninstall まで保持する。
- catalog-v1 は future-dated revocation を受理しない。停止を将来まで延期する durable
  scheduler は未実装のため、catalog service は即時有効の失効だけを発行する。
- leaf key の rotation は、artifact bytes が同じ場合も新しい immutable generation を必要とする。
  同じ generation を別 leaf に再承認しないため、mutable registry record の signer 書換えで
  旧 key revocation を回避できない。
- signed replacement は権限差分の有無にかかわらず、native confirmation なしには適用しない。
  candidate semantic version は導入済み version より厳密に新しくなければならず、同値・旧 version は
  後続の署名 catalog でも rollback として拒否する。

## 必須ゲート

| ID | 状態 | 責任者 | 完了に必要な証跡 |
| --- | --- | --- | --- |
| `REQUESTER_RELEASE_DIRECTION` | approved — 2026-08-31 | Sole Floorp iOS maintainer | 現行 catalog を固定・同梱 Dark Reader 1件へ縮小する指示。これは新候補の TestFlight/External 提出を自動承認せず、通常 PR/CI/review と release gate を維持する。 |
| `MAINTAINER_P0_POLICY` | approved — 2026-08-31 | Sole Floorp iOS maintainer | canonical policy receipt が one-package input、1Password key operation、profile isolation、明示 uninstall までの data retention を束縛する。exact signed candidate の schema-2 approval は pending。 |
| `REDISTRIBUTION_BASIS_VERIFIED` | source verified / candidate evidence pending | Maintainer / Engineering | Dark Reader 1件は MIT、preserved `LICENSE`/`NOTICE`、固定 revision/archive digest、`SourceProvenance` を持つ。candidate signing 時に実 archive を再照合し、source-bound evidence を発行する。 |
| `EXTERNAL_REVIEW_PENDING` | blocked pending signed build | Maintainer / Apple | sequence-3 signing、exact approval、normal integration、Internal smoke 後に限り、Dark Reader-only build の Beta App Review 提出を判断する。 |
| `UPSTREAM_ARTIFACT_MISSING` | one artifact verified / signed candidate pending | Engineering / QA | Dark Reader FWEA1 の artifact/manifest/inventory digest、静的検査、1/1 functional harness はローカル検証対象。sequence-3 catalog、source-bound build、実機/P5 evidence は未完了。 |
| `MANAGED_SIGNING_EVIDENCE_MISSING` | pending | Maintainer | clean source commit と固定 Dark Reader archiveから、同じ root/leaf custodyで sequence 3 を署名し、checkout外に provenance evidence を出す。旧 sequence-2 output は再利用しない。 |
| `RELEASE_TRUST_ANCHOR_MISSING` | partially verified / blocked | Maintainer | 両 curated environment に `FLOORP_CURATED_CATALOG_ROOT_PUBLIC_KEY_SHA256` secret 名が存在することを read-only metadata で確認済み。value は読まず、actual signed root の raw SHA-256、key ID、1Password custody、environment secret を照合するまで完了にしない。source tree の root key 自身を信頼根拠にしてはならない。 |
| `GITHUB_ENVIRONMENT_SCOPE_MISSING` | implemented / release credentials pending | Maintainer / GitHub | candidate と external-release は別 environment で、external のみ P0 approval digest を要求する。両 environment は `floorp-catalog-*` tag の custom policy と admin-bypass disabled を readback 済みで、別人 reviewer は単独 maintainer model では要求しない。root trust-anchor の実値照合、candidate/external の必要 credential、manual dispatch と workflow readback は signed candidate 後に確認する。 |
| `IMMUTABLE_CANDIDATE_REF_MISSING` | partially configured / tag pending | Maintainer / GitHub | active repository ruleset `21688477` が `floorp-catalog-*` の delete / force update を禁止し bypass actor を持たない。public-output PR の通常 merge 後、`floorp-catalog-<40 lowercase commit SHA>` annotated tag を then-current exact `main` にだけ作成する。workflow と Xcode Cloud post-clone は tag 名・tag commit・checkout・`origin/main` HEAD・manual workflow・bundle ID を credential/archive 前に fail closed で照合する。 |
| `P0_APPROVAL_RECORD_MISSING` | pending exact signature | Sole Floorp iOS maintainer | sequence-3 catalog の ID/input/catalog/root/leaf/sequence/schema/version/expiry を canonical schema-2 record に束縛し、normal review 後にその digest を protected environment へ登録する。 |
| `CATALOG_COMPOSITION_SEQUENCE_MISSING` | sequence 3 pending | Maintainer / Engineering | clean committed one-package input を managed signer で署名し、public output を normal PR/CI/main integration へ通す。private key を CI に追加しない。 |
| `RELEASE_IDENTITY_PENDING` | blocked | Maintainer / App Store Connect | 新しい source-bound build number を通常 policy で割り当てる。既存 TestFlight build は再利用しない。 |
| `EXTERNAL_SUBMISSION_PATH_MISSING` | implemented / blocked pending evidence | Maintainer / App Store Connect | `Floorp Curated Catalog External TestFlight` は processed build を exact Xcode Cloud tag run、catalog evidence、tag SHA、App Store build ID、reviewer details、既存 external group に readback で束縛する。Apple credential 前に canonical P0 record と protected `FLOORP_CURATED_CATALOG_RELEASE_APPROVAL_SHA256` を照合し、pending template、digest drift、wrong group は fail closed。実行、group/readback、Beta App Review state は未証跡である。 |
| `MERGE_REQUIRED` | source and public-output PRs pending | Maintainer / GitHub | Dark Reader-only source changeと、その clean commitから生成する署名済み public output/schema-2 recordを通常の review/CI/main mergeに通す。direct push、ruleset bypass、CI/review の省略は行わない。 |

### Current non-secret capability observations

- 2026-08-27 の read-only local check では Floorp Team の有効な Apple
  Distribution identity を確認した。これは iOS archive の資格であり、catalog の
  Ed25519 managed signer、candidate-bound P0 record、または Apple の実審査を代替しない。
- 同じ確認では、リポジトリおよび非秘密の環境設定に approved catalog signer command
  または selector は見つからなかった。秘密鍵・keychain 内容・token は調査も出力も
  していない。以後は 1Password SSH Agent adapter を使う managed signing evidence を記録する。
- 2026-08-27 の local device discovery では接続済み iPhone/iPad は 0 台だった。
  そのため physical-device matrix、accessibility、memory、battery、TestFlight-installed
  revocation exercise は未開始のままである。

## 再開条件と順序

1. Dark Reader-only inputを通常の review/CI/main merge に通す。main に固定された clean
   checkout から、managed signer が Dark Reader archive を再検証し、sequence-3 public signed
   catalog と checkout外の provenance evidence を生成する。
2. public signed output を第 2 normal PR/CI/main integration に通す。signed catalog の exact
   fields を schema 2 の maintainer P0 record に転記し、record raw SHA-256 を
   `floorp-curated-catalog-external-release` environment に登録する。root trust anchor は両 curated
   environment の secret と実署名済み root public key を照合する。
3. GitHub の immutable annotated tag と curated environment の scope を設定・readback し、通常 merge 後の
   current main commit にだけ `floorp-catalog-<40 lowercase commit SHA>` tag を作る。
4. 今回の marketing version/build number と catalog の audience/minimum version が一致することを
   release evidence に記録する。既存 TestFlight build を candidate として再利用しない。
5. candidate workflow の Xcode Cloud archive が `sourceCommit.commitSha` と current-main tag commit の一致を
   readback し、processed build ID を記録する。tamper/expiry/rollback/revocation/archive attack の自動試験、
   normal/private profile の実機試験、失効演習、accessibility、性能を source-bound evidence として保存する。
6. `EXTERNAL_SUBMISSION_PATH_MISSING` を満たす candidate 専用 action で、外部 group と Beta App Review
   submission を readback まで確認する。Apple の審査結果と P5 実機証跡が揃うまで完了とは扱わない。

Apple のリモートコード制約と plug-in 条件は
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) を、外部
TestFlight group と Beta App Review の操作は
[Apple の外部テスター手順](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
を一次資料として確認する。これらのページは運用開始直前に再確認すること。

2026-08-26 の確認では、Guideline 3.2.2(i) は第三者 extensions / plug-ins を
「App Store に似た、または一般的な collection」として表示する interface を不許可と
している。Guideline 4.7 は binary 外の plug-ins を扱う場合に index、個別同意、
privacy、age/material reporting の追加要件を課す。したがって、署名済み FWEA1 を
app bundle に固定しても自動的に適合を保証しない。これは Apple の事前見解を待つ
組織上の gate ではない。上記の技術・license・正規統合 gate を満たした exact candidate を
Beta App Review に提出し、Apple が求める変更があればその時点で maintainer が対応する。
