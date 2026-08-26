# Floorp iOS: 内部 WebExtensions カタログのリリースゲート

Status: **blocked — the requester has authorized the release direction and deferred the
pre-distribution physical-device pass to TestFlight, but P0 evidence, a signed pilot
artifact, and a merged main SHA are still absent.**

この記録は、`floorp-ios-webextensions-internal-catalog-design.md` の P0 を実行可能な
リリース条件に変換する。未完了の項目はコードや feature flag で代替してはならない。
現時点で公開版が許可する導入元は、既存の digest 固定・アプリ同梱 fixture だけである。

## このタスクで記録した指示

- 2026-08-26: 依頼者はリリース作業の続行を承認し、pre-distribution の実機確認を
  TestFlight インストール後の確認に繰り延べるよう指示した。
- この繰り延べは **TestFlight candidate の実機確認順序** だけを変更する。
  P5 完了、一般公開、またはリモート catalog の有効化を承認するものではない。
- App Store Connect の既存の外部グループとアクセス可能な TestFlight 画面は確認済み。
  ただし、App Store Connect へのアクセスは Security、Legal/Privacy、Apple の審査、
  または artifact author の承認を代替しない。

## 現在の安全な状態

- `FloorpWebExtensionFeature.managedRemoteSource` は bootstrap で有効化されない。
- 公開 UI は同梱 catalog だけを表示し、任意 URL、Chrome ウェブストア、CRX/ZIP、
  共有シート、ローカルファイルからの導入経路を持たない。
- verifier、artifact decoder、package-store の catalog transaction は P0-gated の内部
  接続点である。実運用 root key、endpoint、access token、実拡張はソースに含めない。
- 失効は generation の runtime/DNR/page origin を停止し、別 artifact や古い generation
  を自動選択しない。`storage.local` と dynamic DNR state は明示的 uninstall まで保持する。

## 必須ゲート

| ID | 状態 | 責任者 | 完了に必要な証跡 |
| --- | --- | --- | --- |
| `REQUESTER_RELEASE_DIRECTION` | approved — 2026-08-26 | Requester | 本タスクで、GitHub Actions の正規ワークフローを用いること、pre-distribution 実機確認を TestFlight に繰り延べること、App Store Connect を利用することを明示。 |
| `EXTERNAL_REVIEW_PENDING` | blocked | Product / Release | Apple に確認済みの reviewer exercise path、カタログが一般ストアではない説明、リモートコード配布可否、年齢区分、通報・削除・モデレーション手順。4.7 の要件に必要な利用者同意・metadata/index・プライバシー説明も含める。 |
| `AGREEMENT_MISSING` | blocked | Legal / Privacy | 最初の各 artifact について、作者の再配布・更新・サポート許可、license/notice、source 公開義務、privacy declaration、保存期間、問い合わせ/通報先。 |
| `OWNER_APPROVAL_MISSING` | blocked | Security | root private key の offline custody、leaf signer と有効期間、二者承認、監査ログ、key rotation、侵害時の on-call、署名済み失効演習の承認。root key は CDN、GitHub Actions、アプリ、Xcode Cloud に置かない。 |
| `POLICY_DECISION_MISSING` | blocked | Product / Privacy / Security | `FWEA1`/canonical JSON/Ed25519/サイズ・DNR 上限/14 日 catalog・90 日 leaf の契約承認、失効・disable・uninstall 時の data retention/deletion policy、private browsing の初期既定値。 |
| `UPSTREAM_ARTIFACT_MISSING` | blocked | Engineering / QA | author-approved pilot の signed catalog、artifact/manifest/inventory digest、静的検査、P2–P4 実機 OS matrix、失効演習、アクセシビリティ、性能・memory・battery 測定、既知 API 非互換一覧。Stage 3 fixture evidence は代替にならない。 |
| `AUTHORIZATION_MISSING` | partially verified / blocked | Release / Operations | App Store Connect の Floorp / TestFlight 読み取りアクセスと既存外部 group は確認済み。Beta App Review details、署名/provisioning、保護された Actions environment secrets、Xcode Cloud mutation 権限の実証は未記録。 |
| `MERGE_REQUIRED` | blocked | Maintainer | 承認済み review を経た main のマージ済み SHA。正規 workflow は `refs/heads/main` とその完全一致 SHA を検証する。依頼時点の「PR を作成しない・main へ直接 push しない」を守るため、承認済み maintainer の通常の統合操作が必要。 |

## 再開条件と順序

1. Product、Legal/Privacy、Security、Release が上表の自分のゲートを、担当者・日時・
   immutable evidence URL 付きで `approved` に変更する。
2. 承認された root public key と artifact host allow-list を、別途レビュー済みの
   production composition に導入する。`managedRemoteSource` はこの時点まで false のままにする。
3. author-approved pilot を使い、tamper/expiry/rollback/revocation/archive attack の自動試験、
   normal/private profile の実機試験、失効演習を source-bound evidence として保存する。
   依頼者の指示により、実機試験は TestFlight candidate のインストール後に行うが、
   結果が出るまで P5 は完了扱いにしない。
4. 変更を通常の review と main merge に通す。main にある完全一致 SHA でだけ、
   `Floorp TestFlight Manual` または該当する公開 beta workflow を開始する。
5. Xcode Cloud の archive、build number、App Store Connect upload、External TestFlight
   review status、外部 tester による install/retest を記録する。いずれかが失敗または未承認なら
   External TestFlight を開始・継続しない。

Apple のリモートコード制約と plug-in 条件は
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) を、外部
TestFlight group と Beta App Review の操作は
[Apple の外部テスター手順](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
を一次資料として確認する。これらのページは運用開始直前に再確認すること。
