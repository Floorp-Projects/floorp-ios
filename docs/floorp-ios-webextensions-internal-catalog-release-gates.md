# Floorp iOS: 内部 WebExtensions カタログのリリースゲート

Status: **blocked — the sole maintainer has approved P0 policy and External
TestFlight submission for the fixed 16-package candidate, and PR #139 has
merged to `main`. A managed 1Password signer has now produced and locally
verified the source-bound catalog, root public key, provenance evidence, and
candidate-bound P0 record. It remains fail-closed until those public outputs
pass the forthcoming normal PR/CI/`main` integration, then the release
trust-anchor readback, immutable release tag, and source-to-build readback
succeed. The current `main` integration CI for PR #139 succeeded on
2026-08-28.**

この記録は、`floorp-ios-webextensions-internal-catalog-design.md` の P0 を実行可能な
リリース条件に変換する。未完了の項目はコードや feature flag で代替してはならない。
現時点で公開版が許可する導入元は、検証済みのアプリ同梱 catalog だけである。署名済み
catalog がない candidate では、同梱された FWEA1 であっても導入してはならない。

## このタスクで記録した指示

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
  接続点である。16 本の constrained FWEA1 と review workspace はローカルで生成済みだが、
  root private key、input archive、review workspace、remote endpoint は app target に含めない。
  signed `catalog.json` と root public key が無い build はこれらの FWEA1 を受理できず、
  起動時に fail closed する。
- 失効は generation の runtime/DNR/page origin を停止し、別 artifact や古い generation
  を自動選択しない。`storage.local` と dynamic DNR state は明示的 uninstall まで保持する。
- catalog-v1 は future-dated revocation を受理しない。停止を将来まで延期する durable
  scheduler は未実装のため、catalog service は即時有効の失効だけを発行する。
- managed signer は同じ clean checkout の review-only `revocations.json` だけを読んで
  失効を署名する。そこには key または immutable generation と catalog 発行時刻以前の
  `effectiveAt` だけを記録でき、URL、replacement、artifact、remote list、遅延実行を
  記録できない。release verifier はその input digest/count と signed catalog の完全一致を
  再確認する。`revocations.json` は app resource ではない。
- leaf key の rotation は、artifact bytes が同じ場合も新しい immutable generation を必要とする。
  同じ generation を別 leaf に再承認しないため、mutable registry record の signer 書換えで
  旧 key revocation を回避できない。
- signed replacement は権限差分の有無にかかわらず、native confirmation なしには適用しない。
  candidate semantic version は導入済み version より厳密に新しくなければならず、同値・旧 version は
  後続の署名 catalog でも rollback として拒否する。

## 必須ゲート

| ID | 状態 | 責任者 | 完了に必要な証跡 |
| --- | --- | --- | --- |
| `REQUESTER_RELEASE_DIRECTION` | approved — 2026-08-28 | Sole Floorp iOS maintainer | 固定・同梱 16 package、鍵運用、失効、private mode/data retention、通常 PR/CI/review/main 統合と正規 Beta App Review 提出を承認。任意導入、remote code/list、silent update、権限昇格、fail-open、手順迂回は承認していない。 |
| `MAINTAINER_P0_POLICY` | approved — 2026-08-28 | Sole Floorp iOS maintainer | P0 の組織上の承認責任者は maintainer 一人である。存在しない Legal/Privacy/Security/Product/Release/作者の別承認を要求しない。exact signed candidate を束縛する canonical schema 2 record も生成済みで、normal PR review と protected digest 登録を待つ。 |
| `REDISTRIBUTION_BASIS_VERIFIED` | verified / signed candidate evidence generated | Maintainer / Engineering | 13 third-party package は MIT、preserved `LICENSE`/`NOTICE`、固定 revision/archive digest、`SourceProvenance`、reviewed local derivation を持つ。clean `main` checkout で全 13 quarantine archive を再検証し、candidate-bound provenance evidence（SHA-256 `dbc6b0f5701a9c0d96a39347768a5cc28aa11846a373fb57853e47a0946a0213`）を発行した。根拠が欠ける future package は署名前に除外する。 |
| `EXTERNAL_REVIEW_PENDING` | submission authorized / acceptance pending | Maintainer / Apple | 正規 `main` 統合・管理署名・candidate binding を満たした exact 16-package build は、Apple の事前見解を待たず Beta App Review に提出する。提出 notes は fixed app-bundled catalog、任意導入・remote code/list・silent update が無いこと、署名/digest/audience/expiry/sequence/revocation/explicit consent、各 package の権限・データ挙動を明記する。Apple の受理と external availability は実審査まで pending である。 |
| `UPSTREAM_ARTIFACT_MISSING` | signed candidate verified / P5 pending | Engineering / QA | 16 constrained FWEA1、artifact/manifest/inventory digest、静的検査、16/16 functional harness と全 artifact を束縛する signed catalog は生成・ローカル検証済み。13 third-party source provenance と Very Good AdBlock の 16 static-`block` mapping も再検証済み。P2–P4 実機 OS matrix、失効演習、アクセシビリティ、性能/memory/battery 測定、既知 API 非互換一覧は候補ビルド後の未完了項目である。Stage 3 fixture evidence は代替にならない。 |
| `MANAGED_SIGNING_EVIDENCE_MISSING` | complete locally / normal PR integration pending | Maintainer | 1Password SSH Agent adapter（SHA-256 `f1cacd7a4fb2f5916700fd4c9c85ca15cf571df861b114d941e101e8eccdfcea`）で clean main checkout と実 archive を再検証し、root/leaf key ID、署名済み `catalog.json`（SHA-256 `0c803682309f3677be04e6b9b293441f66ae36402075137ee3c9af07a53ac8cf`）、root public key、source-external provenance evidence を発行した。秘密鍵を GitHub、Xcode Cloud、app bundle、ログに置いていない。 |
| `RELEASE_TRUST_ANCHOR_MISSING` | partially verified / blocked | Maintainer | 両 curated environment に `FLOORP_CURATED_CATALOG_ROOT_PUBLIC_KEY_SHA256` secret 名が存在することを read-only metadata で確認済み。value は読まず、actual signed root の raw SHA-256、key ID、1Password custody、environment secret を照合するまで完了にしない。source tree の root key 自身を信頼根拠にしてはならない。 |
| `GITHUB_ENVIRONMENT_SCOPE_MISSING` | implemented / release credentials pending | Maintainer / GitHub | candidate と external-release は別 environment で、external のみ P0 approval digest を要求する。両 environment は `floorp-catalog-*` tag の custom policy と admin-bypass disabled を readback 済みで、別人 reviewer は単独 maintainer model では要求しない。root trust-anchor の実値照合、candidate/external の必要 credential、manual dispatch と workflow readback は signed candidate 後に確認する。 |
| `IMMUTABLE_CANDIDATE_REF_MISSING` | partially configured / tag pending | Maintainer / GitHub | active repository ruleset `21688477` が `floorp-catalog-*` の delete / force update を禁止し bypass actor を持たない。public-output PR の通常 merge 後、`floorp-catalog-<40 lowercase commit SHA>` annotated tag を then-current exact `main` にだけ作成する。workflow と Xcode Cloud post-clone は tag 名・tag commit・checkout・`origin/main` HEAD・manual workflow・bundle ID を credential/archive 前に fail closed で照合する。 |
| `P0_APPROVAL_RECORD_MISSING` | approved locally / protected digest registration pending | Sole Floorp iOS maintainer | canonical schema 2 record now binds the exact signed catalog ID/input SHA/catalog SHA/root SHA/leaf key/sequence/schema/version/expiry and one opaque `maintainerApproval`; raw SHA-256 is `c279d3cfcb0e2a5e202c76cb5db3bcbb17eb17aadf0a158cd9505fa53c2cb500`. Integrate it by normal review, then register that public digest in the protected external-release environment. |
| `CATALOG_COMPOSITION_SEQUENCE_MISSING` | signing complete / public-output PR pending | Maintainer / Engineering | Xcode Cloud は main source tree を archive するだけで signer を呼ばない。そこで infrastructure を main に統合後、main に固定された input を maintainer の managed signer で署名し、public signed output を第 2 normal PR/CI/main integration で導入する。private key を CI に追加して解決してはならない。 |
| `RELEASE_IDENTITY_PENDING` | partially configured / blocked | Maintainer / App Store Connect | `catalog-input.json` の最低 Floorp 版と release configuration は `0.3.0`、build number は `4`。main 統合後に App Store Connect で `0.3.0 (4)` の未使用を確認し、必要なら通常の versioning policy に従って未使用 build number を割り当てる。既存 0.2.0 TestFlight build は再利用しない。 |
| `EXTERNAL_SUBMISSION_PATH_MISSING` | implemented / blocked pending evidence | Maintainer / App Store Connect | `Floorp Curated Catalog External TestFlight` は processed build を exact Xcode Cloud tag run、catalog evidence、tag SHA、App Store build ID、reviewer details、既存 external group に readback で束縛する。Apple credential 前に canonical P0 record と protected `FLOORP_CURATED_CATALOG_RELEASE_APPROVAL_SHA256` を照合し、pending template、digest drift、wrong group は fail closed。実行、group/readback、Beta App Review state は未証跡である。 |
| `MERGE_REQUIRED` | partially complete / public-output PR pending | Maintainer / GitHub | PR #139 は `ab6235fd7c6694aa97217d1626411ef0af0a3796` として通常 merge 済みである。main ruleset は pull request、解決済み review thread、`Validate workflows`、`Build and unit test` を必須にする（required approval count は 0）。署名済み public output と schema 2 record の follow-up PR も通常の review/CI と main merge に通す。direct push、ruleset bypass、CI/review の省略は行わない。 |

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

1. PR #139 は通常の review/CI/main merge を完了した。main に固定された clean checkout から、
   managed signer が 13 upstream archive を再検証し、public signed catalog/root key/provenance
   evidence を生成する。`managedRemoteSource` は false のままにする。
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
