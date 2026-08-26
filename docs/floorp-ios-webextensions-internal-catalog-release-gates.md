# Floorp iOS: 内部 WebExtensions カタログのリリースゲート

Status: **blocked — the requester has authorized External TestFlight review, and the
candidate now has constrained local FWEA1 artifacts plus local verification. It still
fails closed until a managed signer produces the catalog and root public key; P0
approval evidence, a source-bound signed candidate, and a merged main SHA are absent.**

この記録は、`floorp-ios-webextensions-internal-catalog-design.md` の P0 を実行可能な
リリース条件に変換する。未完了の項目はコードや feature flag で代替してはならない。
現時点で公開版が許可する導入元は、検証済みのアプリ同梱 catalog だけである。署名済み
catalog がない candidate では、同梱された FWEA1 であっても導入してはならない。

## このタスクで記録した指示

- 2026-08-27: 依頼者（Floorp iOS maintainer）は、現在の 16 本の固定・同梱
  WebExtensions を初回 External TestFlight candidate として採用することを承認した。
  通常の review、CI、正規の `main` 統合を通過した後に限り、管理済み signer による
  catalog 署名と既存の正規 workflow による Beta App Review 提出も承認した。この承認は
  任意導入、remote code/list、silent update、権限昇格、fail-open、または下記 P0 の
  個別承認を許可するものではない。
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
  `Floorp TestFlight Deploy (Xcode Cloud)` は main の完全一致 SHA を Xcode Cloud に渡すだけで、
  catalog signer を呼ばない。`Floorp Public Beta Release` は Notes Sync 用の固定版番号 workflow
  であり、本候補に流用してはならない。

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

## 必須ゲート

| ID | 状態 | 責任者 | 完了に必要な証跡 |
| --- | --- | --- | --- |
| `REQUESTER_RELEASE_DIRECTION` | approved — 2026-08-27 | Requester / Floorp iOS maintainer | 現在の 16 本の固定・同梱候補を承認。通常の review、CI、正規 `main` 統合後に限る managed signer と既存正規 workflow による External TestFlight Beta App Review 提出を承認。P0/P5、direct push、新規 PR、CI 迂回、任意導入、remote code/list、silent update、権限昇格、fail-open は承認していない。 |
| `EXTERNAL_REVIEW_PENDING` | blocked | Product / Release | Apple に確認済みの reviewer exercise path と、固定同梱の 13 本の第三者互換ビルドを含む 16 本が App Review Guideline 3.2.2(i) の「第三者 extensions / plug-ins の一般的 collection」ではない、または許容されるとの書面確認。4.7 の適用時は、catalog が一般ストアではない説明、remote code 不使用、年齢区分、通報・削除・モデレーション、利用者同意、metadata/index、プライバシー説明を含める。 |
| `AGREEMENT_MISSING` | blocked | Legal / Privacy | 最初の各 artifact について、作者の再配布・更新・サポート許可、license/notice、source 公開義務、privacy declaration、保存期間、問い合わせ/通報先。 |
| `OWNER_APPROVAL_MISSING` | blocked | Security | root private key の offline custody、leaf signer と有効期間、二者承認、監査ログ、key rotation、侵害時の on-call、署名済み失効演習の承認。`keyID` の一意性と異なる公開鍵への再利用禁止も承認する。root key は CDN、GitHub Actions、アプリ、Xcode Cloud に置かない。 |
| `POLICY_DECISION_MISSING` | blocked | Product / Privacy / Security | `FWEA1`/canonical JSON/Ed25519/サイズ・DNR 上限/14 日 catalog・90 日 leaf の契約承認、失効・disable・uninstall 時の data retention/deletion policy、private browsing の初期既定値。 |
| `UPSTREAM_ARTIFACT_MISSING` | partially verified / blocked | Engineering / QA | constrained 16 FWEA1、artifact/manifest/inventory digest、静的検査と機能 harness はローカルで記録済み。ただし author-approved pilot の signed catalog、P2–P4 実機 OS matrix、失効演習、アクセシビリティ、性能・memory・battery 測定、既知 API 非互換一覧は未完了。Stage 3 fixture evidence は代替にならない。 |
| `AUTHORIZATION_MISSING` | partially verified / blocked | Release / Operations | App Store Connect の Floorp / TestFlight 読み取りアクセスと既存外部 group は確認済み。2026-08-27 読み取り時点で 0.2.0 (61) は external testing 中だが、`main` `c7c8490…` に束縛された Stage 3 fixture-only build であり、この候補には使えない。管理署名が可能であるとの申告はあるが、再確認した `Floorp TestFlight Deploy (Xcode Cloud)` と `floorp-testflight` environment は Apple code-sign/App Store Connect key だけを示し、catalog Ed25519 signer の workflow、secret、variable、または invocation は repository 側に見つからなかった。これは外部 HSM の不存在を主張するものではないが、現状の repository/CI から呼べる経路ではない。秘密鍵ではなく、承認済み signer job または invocation、root/leaf key ID、発行監査記録、署名済み `catalog.json`/root public key の受渡し先、候補用 reviewer details、署名/provisioning、Xcode Cloud mutation 権限を記録する必要がある。 |
| `RELEASE_IDENTITY_PENDING` | blocked | Release / Maintainer | `catalog-input.json` は最低 Floorp 版 `0.3.0` を要求する一方、現行 release configuration は `0.2.0`。署名の前に、今回用の marketing version と未使用の build number を通常の release policy に従って確定し、catalog audience と App Store Connect build の対応を記録する。既存 0.2.0 TestFlight build は再利用しない。 |
| `MERGE_REQUIRED` | approved in principle / pending checks | Maintainer | 2026-08-26 に依頼者（maintainer）が、通常の review・source-bound CI・通常 merge で `main` へ統合することを許可。現 candidate の PR は作成しておらず、正規 workflow は `refs/heads/main` とその完全一致 SHA を検証する。direct push、新規 PR、CI の迂回は許可されない。 |

## 再開条件と順序

1. Product、Legal/Privacy、Security、Release が上表の自分のゲートを、担当者・日時・
   immutable evidence URL 付きで `approved` に変更する。
2. managed signer が発行した root public key と signed catalog を、別途レビュー済みの
   production composition に導入する。`managedRemoteSource` はこの時点まで false のままにする。
3. author-approved pilot を使い、tamper/expiry/rollback/revocation/archive attack の自動試験、
   normal/private profile の実機試験、失効演習を source-bound evidence として保存する。
   依頼者の指示により、実機試験は TestFlight candidate のインストール後に行うが、
   結果が出るまで P5 は完了扱いにしない。
4. 今回の marketing version/build number と catalog の audience/minimum version が一致することを
   release evidence に記録する。既存 TestFlight build を candidate として再利用しない。
5. 変更を通常の review と main merge に通す。main にある完全一致 SHA でだけ、
   `Floorp TestFlight Manual` または該当する公開 beta workflow を開始する。
6. Xcode Cloud の archive、build number、App Store Connect upload、External TestFlight
   review status、外部 tester による install/retest を記録する。いずれかが失敗または未承認なら
   External TestFlight を開始・継続しない。

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
