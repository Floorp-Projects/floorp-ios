# Floorp iOS: 内部 WebExtensions カタログのリリースゲート

Status: **blocked — the requester has authorized External TestFlight review, and the
candidate now has constrained local FWEA1 artifacts plus local verification. It still
fails closed until a managed signer produces the catalog and root public key; P0
approval evidence, a source-bound signed candidate, a protected release trust
anchor, a protected immutable release tag, a source-to-build readback, and a
merged main SHA are absent.**

この記録は、`floorp-ios-webextensions-internal-catalog-design.md` の P0 を実行可能な
リリース条件に変換する。未完了の項目はコードや feature flag で代替してはならない。
現時点で公開版が許可する導入元は、検証済みのアプリ同梱 catalog だけである。署名済み
catalog がない candidate では、同梱された FWEA1 であっても導入してはならない。

## このタスクで記録した指示

- 2026-08-27: 依頼者（Floorp iOS maintainer）は、現在の 16 本の固定・同梱
  WebExtensions を初回 External TestFlight candidate として採用することを承認した。
  通常の review、CI、正規の `main` 統合を通過した後に限り、管理済み signer による
  catalog 署名と既存の正規 workflow による Beta App Review 提出も承認した。この承認は
  任意導入、remote code/list、サイレント更新、権限昇格、fail-open、または
  下記 P0 の個別承認を許可するものではない。
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
  ただし、App Store Connect へのアクセスは Security、Legal/Privacy、Apple の審査、
  または artifact author の承認を代替しない。
- 2026-08-27: `origin/main` と Xcode Cloud post-clone script を読み取り確認した。既存の
  `Floorp TestFlight Deploy (Xcode Cloud)` は checkout を main SHA に照合するが、Xcode Cloud の
  `sourceBranchOrTag` には可変の `main` reference を渡す。catalog signer を呼ばず、catalog
  candidate の証跡には使えない。`Floorp Public Beta Release` は Notes Sync 用の固定版番号 workflow
  であり、本候補に流用してはならない。
- 2026-08-27: GitHub の有効 ruleset `Protect Floorp iOS main` を読み取り確認した。`main` には
  pull request、解決済み review thread、必須 status check `Validate workflows` と
  `Build and unit test` が必要であり、direct push は正規経路にならない。ruleset 自体は
  signed Git commit を要求していない。ただし依頼者の「新規 PR は作成しない」という制約と
  衝突するため、PR を作成せずにこの候補を main へ統合する経路は存在しない。
- 2026-08-28: existing normal PR #139 を確認した。依頼者は通常の review/CI/main integration を
  承認しているため、この既存 PR を更新して用いる。新規 PR、direct push、ruleset bypass は行わない。
- 2026-08-27: 初回 signed candidate の構成順序を再確認した。現在の Xcode Cloud workflow は
  main の完全一致 SHA を build するだけで catalog signer を呼ばない。そのため「main 統合後に
  初めて signer を動かす」と、最初の binary に signed `catalog.json` と root public key を
  同梱できない。安全な選択肢は、(a) Security が review 対象の immutable artifact input を
  source-bound に署名し、その**公開出力だけ**を最初の PR に含める、または (b) infrastructure を
  先に main へ統合し、main に固定された input を署名して公開出力を第 2 PR で統合する、のいずれか
  である。private key はどちらの場合も GitHub、Xcode Cloud、app bundle に置かない。
- 2026-08-27: managed signer の handoff contract を追加し、署名対象を同一 clean Git
  checkout の `CuratedCatalog` に固定した。review-quarantined archive の再検証、検証済み
  `catalog-input.json` byte snapshot のみの署名、private key 読込直前の clean recheck、既定の
  public output path、source checkout 外の audit evidence を必須にする。これは signer 実行や
  Security の鍵運用承認を代替しない。
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
- 2026-08-27: Apple の現行 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
  を再確認した。3.2.2(i) は第三者 apps/extensions/plug-ins を App Store 類似または general-interest
  collection として表示する UI を明示的に不許可としている。一方 3.2.1(ii) は specific approved need
  向けの第三者 app collection を robust editorial content とともに許容し得るが、現在の 16 本は
  accessibility だけに限定されない横断的な collection であり、これを根拠に例外扱いしてはならない。
  4.7 は binary に埋め込まれていない software を対象に追加条件を置くため、app-bundled FWEA1 が
  4.7 の対象外であると自己判断する根拠にはならない。Apple / Product の書面による reviewer exercise
  path が得られるまで `EXTERNAL_REVIEW_PENDING` は blocked のままとする。

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
- leaf key の rotation は、artifact bytes が同じ場合も新しい immutable generation を必要とする。
  同じ generation を別 leaf に再承認しないため、mutable registry record の signer 書換えで
  旧 key revocation を回避できない。
- signed replacement は権限差分の有無にかかわらず、native confirmation なしには適用しない。
  candidate semantic version は導入済み version より厳密に新しくなければならず、同値・旧 version は
  後続の署名 catalog でも rollback として拒否する。

## 必須ゲート

| ID | 状態 | 責任者 | 完了に必要な証跡 |
| --- | --- | --- | --- |
| `REQUESTER_RELEASE_DIRECTION` | approved — 2026-08-27 | Requester / Floorp iOS maintainer | 現在の 16 本の固定・同梱候補を承認。通常の review、CI、正規 `main` 統合後に限る managed signer と既存正規 workflow による External TestFlight Beta App Review 提出を承認。P0/P5、direct push、新規 PR、CI 迂回、任意導入、remote code/list、サイレント更新、権限昇格、fail-open は承認していない。 |
| `EXTERNAL_REVIEW_PENDING` | submission authorized / acceptance pending — 2026-08-27 | Product / Release | Maintainer の再検討により、正規 `main` 統合・管理署名・candidate binding を満たした exact 16-package build は、Apple の事前見解を待たず Beta App Review に提出する。提出 notes は fixed app-bundled catalog、外部/任意導入・remote code/list・silent update が無いこと、署名/digest/audience/expiry/sequence/revocation/explicit consent、各 package の権限・データ挙動を明記し、Guideline 3.2.2(i) について必要な具体的変更の指摘を求める。これは Apple の受理、4.7 対応、または外部 tester への利用可能化を承認済みと扱うものではない。拒否時は同一構成を反復提出せず、指摘に応じて再判断する。 |
| `AGREEMENT_MISSING` | blocked | Legal / Privacy | 最初の各 artifact について、作者の再配布・更新・サポート許可、license/notice、source 公開義務、privacy declaration、保存期間、問い合わせ/通報先。 |
| `OWNER_APPROVAL_MISSING` | blocked | Security | root private key の offline custody、leaf signer と有効期間、二者承認、監査ログ、key rotation、侵害時の on-call、署名済み失効演習の承認。`keyID` の一意性と異なる公開鍵への再利用禁止も承認する。root key は CDN、GitHub Actions、アプリ、Xcode Cloud に置かない。 |
| `POLICY_DECISION_MISSING` | blocked | Product / Privacy / Security | `FWEA1`/canonical JSON/Ed25519/サイズ・DNR 上限/14 日 catalog・90 日 leaf の契約承認、失効・disable・uninstall 時の data retention/deletion policy、private browsing の初期既定値。 |
| `UPSTREAM_ARTIFACT_MISSING` | partially verified / blocked | Engineering / QA | 16 constrained FWEA1 と artifact/manifest/inventory digest、静的検査・16/16 functional harness はローカルで記録済み。13 第三者 source は immutable revision に固定し、全 13 本に archive/license/reviewed-member/local-derivation を exact-key で束縛する `SourceProvenance` record を追加した。Very Good AdBlock の 16 static-`block` rule mapping も維持する。候補用の実 archive を signer に渡して再照合し、candidate-bound provenance evidence を保存するまでは「実 archive 検証済み」とは扱わない。Floorp-managed 3 本も full source commit に固定した。ただし author-approved pilot の signed catalog、P2–P4 実機 OS matrix、失効演習、アクセシビリティ、性能・memory・battery 測定、既知 API 非互換一覧は未完了。Stage 3 fixture evidence は代替にならない。 |
| `AUTHORIZATION_MISSING` | partially verified / blocked | Release / Operations | App Store Connect の Floorp / TestFlight 読み取りアクセスと既存外部 group は確認済み。2026-08-27 読み取り時点で 0.2.0 (61) は external testing 中だが、`main` `c7c8490…` に束縛された Stage 3 fixture-only build であり、この候補には使えない。managed signer handoff は実装済みだが、実 archive を使う signer invocation、root/leaf key ID、二者承認、発行監査記録、署名済み `catalog.json`/root public key の受渡し先は未記録である。秘密鍵ではなく、承認済み signer job または invocation、候補用 reviewer details、署名/provisioning、Xcode Cloud mutation 権限を記録する必要がある。 |
| `RELEASE_TRUST_ANCHOR_MISSING` | blocked | Security / Release | protected `floorp-curated-catalog-candidate` と `floorp-curated-catalog-external-release` environment に、approved root public key の raw-32-byte SHA-256 を `FLOORP_CURATED_CATALOG_ROOT_PUBLIC_KEY_SHA256` として登録し、key ID/custody record と照合する。source tree の `root-public-key.txt` 自身を信頼根拠にしてこの条件を満たしてはならない。 |
| `IMMUTABLE_CANDIDATE_REF_MISSING` | blocked | Release / Security | `floorp-catalog-<40 lowercase commit SHA>` の annotated tag を、通常 merge 後の**現在の** exact `main` commit にだけ作成でき、force update/delete を release approver 以外に許さない GitHub tag protection を設定する。候補 workflow は tag 名・tag commit・checkout・`origin/main` HEAD の完全一致を credential 前に確認し、Xcode Cloud `Floorp TestFlight Manual` が同じ tag を `sourceBranchOrTag` として解決できることを read-only preflight で記録する。Cloud 側も post-clone で `CI_GIT_REF`/`CI_TAG`/`CI_COMMIT`/workflow/bundle ID/checkout/current `origin/main` を archive 前に再照合する。tag/branch の同名混同、tag move、古い main commit の再利用、branch-only dispatch、auto start、async/no-wait は候補経路で許可しない。 |
| `EXTERNAL_SUBMISSION_PATH_MISSING` | implemented / blocked pending evidence | Release / App Store Connect | `Floorp Curated Catalog External TestFlight` は processed build を exact Xcode Cloud tag run、catalog evidence、tag SHA、App Store build ID、reviewer details、既存 external group に readback で束縛する。Apple credential より前に canonical P0 approval record と protected `FLOORP_CURATED_CATALOG_RELEASE_APPROVAL_SHA256` を照合する。`pending` template、digest drift、未保護 environment、複数／internal group は fail closed。実 candidate での実行、group/readback、Beta App Review state は未証跡である。既存 Notes Sync workflow や Xcode Cloud の自動外部公開では代替しない。 |
| `P0_APPROVAL_RECORD_MISSING` | blocked | Legal / Privacy / Security / Product / Release | `docs/floorp-ios-webextensions-curated-catalog-release-approval.json` は `pending` template である。exact signed catalog の ID/input SHA/catalog SHA/root SHA/leaf key/sequence/schema/version/expiry と、五つの opaque approval evidence ID を含む canonical `approved` record を通常 review で統合し、その raw SHA-256 を protected external-release environment に登録する。Maintainer の release direction はこの五者承認を代替しない。 |
| `ENVIRONMENT_PROTECTION_MISSING` | blocked | Release / Security | `floorp-curated-catalog-candidate` と `floorp-curated-catalog-external-release` に required reviewers と least-privilege secret scope を設定する。external environment には Legal/Privacy record digest を含む P0 approval gate が必要で、candidate environment から external mutation credential を継承してはならない。 |
| `CATALOG_COMPOSITION_SEQUENCE_MISSING` | blocked | Security / Release / Maintainer | 現行 Xcode Cloud は main の source tree をそのまま archive し catalog signer を呼ばない。従って「main 統合後に署名」と「初回 binary に signed catalog を同梱」を両立するには、(a) review 対象 input の source-bound pre-merge signing、または (b) infrastructure main 統合後の public signed output 用第 2 PR、あるいは Security 承認済みの別 composition mechanism が必要。private key を CI に追加してこの矛盾を解くことは許可されない。 |
| `RELEASE_IDENTITY_PENDING` | partially configured / blocked | Release / Maintainer | `catalog-input.json` の最低 Floorp 版と release configuration は `0.3.0` に整合済み（build number は `4`）。通常の `main` 統合後に App Store Connect で `0.3.0 (4)` が未使用であることを確認し、既に使われていれば通常の versioning policy に従って未使用 build number を割り当てる。catalog audience と実際の App Store build の対応を記録するまでこの gate は完了しない。既存 0.2.0 TestFlight build は再利用しない。 |
| `MERGE_REQUIRED` | blocked — normal review pending | Maintainer / reviewer | GitHub の有効 main ruleset は pull request、解決済み review thread、`Validate workflows`、`Build and unit test` を必須にする（required approval count は 0）。既存の normal PR #139 を更新して用いる。新規 PR、direct push、ruleset bypass は行わない。通常レビューと CI 成功後に Maintainer が merge を実行する。ruleset は signed Git commit を要求していないが、ローカルの signing policy を無断で無効化してはならない。 |

### Current non-secret capability observations

- 2026-08-27 の read-only local check では Floorp Team の有効な Apple
  Distribution identity を確認した。これは iOS archive の資格であり、catalog の
  Ed25519 managed signer、鍵保管承認、または二者承認を代替しない。
- 同じ確認では、リポジトリおよび非秘密の環境設定に approved catalog signer command
  または selector は見つからなかった。秘密鍵・keychain 内容・token は調査も出力も
  していないため、`OWNER_APPROVAL_MISSING` と `AUTHORIZATION_MISSING` は継続する。
- 2026-08-27 の local device discovery では接続済み iPhone/iPad は 0 台だった。
  そのため physical-device matrix、accessibility、memory、battery、TestFlight-installed
  revocation exercise は未開始のままである。

## 再開条件と順序

1. Product、Legal/Privacy、Security、Release が上表の自分のゲートを、担当者・日時・
   immutable evidence URL 付きで `approved` に変更する。
2. Security が approved root public key の SHA-256 を protected
   `floorp-curated-catalog-candidate` と `floorp-curated-catalog-external-release`
   environment に登録し、後者には approved P0 record の raw SHA-256 も登録する。managed signer
   が発行した root public key と signed catalog を、別途レビュー済みの production composition に
   導入する。`managedRemoteSource` はこの時点まで false のままにする。
3. author-approved pilot を使い、tamper/expiry/rollback/revocation/archive attack の自動試験、
   normal/private profile の実機試験、失効演習を source-bound evidence として保存する。
   依頼者の指示により、実機試験は TestFlight candidate のインストール後に行うが、
   結果が出るまで P5 は完了扱いにしない。
4. 今回の marketing version/build number と catalog の audience/minimum version が一致することを
   release evidence に記録する。既存 TestFlight build を candidate として再利用しない。
5. Maintainer が既存の正規 PR #139 を通常の review と main merge に通し、上記の (a)/(b) の catalog
   composition sequence を選ぶ。public signed output を
   含む exact merged commit に対して Security/Release が protected annotated
   `floorp-catalog-<40 lowercase commit SHA>` tag を作成し、tag 名・tag commit・checkout・現在の
   `origin/main` HEAD が一致することを確認して、その tag からだけ candidate workflow を開始する。
6. candidate workflow の Xcode Cloud archive が `sourceCommit.commitSha` と current-main tag commit の一致を
   readback し、processed build ID を記録する。次に `EXTERNAL_SUBMISSION_PATH_MISSING` を満たす
   candidate 専用の action で、外部 group と Beta App Review submission を readback まで確認する。
   いずれかが失敗または未承認なら External TestFlight を開始・継続しない。

Apple のリモートコード制約と plug-in 条件は
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) を、外部
TestFlight group と Beta App Review の操作は
[Apple の外部テスター手順](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
を一次資料として確認する。これらのページは運用開始直前に再確認すること。

2026-08-26 の確認では、Guideline 3.2.2(i) は第三者 extensions / plug-ins を
「App Store に似た、または一般的な collection」として表示する interface を不許可と
している。Guideline 4.7 は binary 外の plug-ins を扱う場合に index、個別同意、
privacy、age/material reporting の追加要件を課す。したがって、署名済み FWEA1 を
app bundle に固定しても、この catalog を External TestFlight に出す前に Apple の
明示的な審査経路または Product による範囲変更が必要である。
