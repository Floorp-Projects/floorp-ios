# Floorp iOS: 署名付き内部 WebExtensions カタログ設計

Status: proposed design. This document does not authorize a remote package,
an App Store release, or redistribution of a third-party extension.

## 1. 目的と決定

Floorp iOS は、Chrome Manifest V3 (MV3) を入力仕様として利用する
**Floorp 内部カタログ**を提供する。ユーザーが導入できるのは、Floorp が
事前検証・署名した不変のパッケージだけである。

これは Chrome ウェブストアをブラウズして任意の拡張機能を導入する機能では
ない。Chrome ウェブストアは候補の発見、作者・ライセンスの確認、および
配布許可を得るための外部情報源に留める。カタログに載せる版は、Floorp が
審査した成果物のハッシュで固定する。ストアに同じ拡張 ID の新しい版が
公開されても、Floorp の導入済みパッケージは変化しない。

この方針は、現在の `FloorpWebExtensionBundledCatalog` と
`FloorpWebExtensionPackageStore` が持つ「同梱・digest 固定・プロファイル
所有」の安全境界を、リモート配布へ拡張するものである。現在の実装範囲は
[MV3 compatibility limitations](floorp-ios-webextensions-mv3-limitations.md) を
正とする。

### 1.1 非目標

- Chrome ウェブストア、Firefox Add-ons、または任意 URL をアプリ内に一覧・
  検索・導入する一般ストア。
- CRX、ZIP、共有シート、ローカルファイルからの公開版への任意導入。
- カタログを通さない JavaScript、WASM、ルールリスト、CSS、画像の取得または
  更新。
- 既存拡張のサイレントな置換。更新は新しい不変世代として扱う。
- MV2、`webRequestBlocking`、DNR リダイレクト／ヘッダー変更、完全な
  Service Worker 互換。

開発用・社内検証用のローカル導入は、別バンドル ID・別署名鍵・明示的な
開発者設定に限定する。公開版のコードパスやカタログ鍵と共用してはならない。

### 1.2 App Review の前提

リモートで提供するプラグイン／コードの可否、カタログ画面の表示方法、
年齢区分、通報と削除の運用は App Review と法務の承認が必要である。特に
一般的な第三者拡張ストアに見える UI は避ける。P0 の承認記録なしに P5 の
公開配布へ進んではならない。

参考: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)、
[Chrome MV3](https://developer.chrome.com/docs/extensions/develop/migrate/what-is-mv3)。

## 2. セキュリティ原則

認証は「カタログを取得できる利用者・クライアント」を制御する。
**不変性と完全性は認証だけでは成立しない**ため、クライアントで検証する
署名、内容ハッシュ、世代番号を必須とする。

1. アプリに埋め込んだ root 公開鍵だけを信頼の起点とする。
2. カタログ、失効リスト、各パッケージの内容はいずれも署名と SHA-256 で検証する。
3. 署名、対象アプリ、最低アプリ版、有効期限、連番、内容ハッシュのいずれかが
   不正なら導入しない。既存の正常な導入済み世代は消さない。
4. パッケージは一度導入したら不変であり、更新は新しい世代の明示的な導入である。
5. パッケージを展開する前後で manifest と全リソースのインベントリを検証し、
   `FloorpWebExtensionManifest.preflight` に通らないものは永続化しない。
6. 失効は即時の無効化には使えるが、別コードへの置換には使わない。
7. ネットワーク障害、時刻不整合、署名不能、ロールバック疑いは fail closed とする。

### 2.1 想定する脅威と対処

| 脅威 | 対処 |
| --- | --- |
| CDN／通信経路の改ざん | TLS に加え、署名済みカタログと成果物 SHA-256 を端末で検証する。 |
| 古い安全でないカタログの再配布 | 連番、発行・失効時刻、最後に受理した連番を保存し、ロールバックを拒否する。 |
| パッケージ差し替え | カタログの `artifactSHA256`、展開後の全ファイルインベントリ、manifest SHA-256 を照合する。 |
| 署名鍵の漏えい | root 鍵で署名した短命の leaf 鍵を使う。鍵 ID、失効、ローテーション、緊急停止を実装する。root 秘密鍵はオンライン配布系に置かない。 |
| 悪意あるが正しく署名された拡張 | 受入審査、ライセンス確認、静的検査、実機検証、最小権限、失効手順で軽減する。署名は安全性の保証ではない。 |
| ZIP Slip、symlink、巨大展開 | 現行 package store の安全なパス・深さ・個別サイズ・総サイズ・ファイル数検証を、アーカイブ展開前後にも適用する。 |
| 権限の増加 | 新世代として扱い、旧世代から増えた API／ホスト権限は再同意が済むまで有効化しない。 |

## 3. アーキテクチャ

```text
Floorp account / app attestation
             │ short-lived catalog access token
             ▼
     Internal Catalog API ───────────────► signed catalog + signed revocations
             │                                         │
             │                                 verify root / leaf chain,
             │                                 audience, expiry, sequence
             ▼                                         ▼
      artifact endpoint ───────────────► catalog item selected by the user
                                                       │
                                      SHA-256 + archive safety + manifest preflight
                                                       ▼
     FloorpWebExtensionPackageStore ─► immutable profile package generation
                                                       │
                                                       ▼
                   FloorpWebExtensionCoordinator / WebKit policy + page hosts
```

サーバーは可用性とアクセス制御を担い、アプリは信頼判定を担う。したがって、
カタログ API の認証トークン、CDN の URL、レスポンスヘッダーだけを信頼の根拠に
してはならない。

### 3.1 コンポーネントの責務

| コンポーネント | 責務 | 信頼してよい入力 |
| --- | --- | --- |
| `FloorpExtensionCatalogClient`（新規） | カタログ・失効リストの取得、認証ヘッダー付与、キャッシュ | ネットワーク応答は未信頼 |
| `FloorpExtensionCatalogVerifier`（新規） | canonical JSON、署名鎖、対象アプリ、有効期限、連番、鍵失効を検証 | アプリ同梱 root 公開鍵 |
| `FloorpExtensionArtifactDownloader`（新規） | 選択済みレコードの単一成果物のみを取得し、サイズと SHA-256 を検証 | 検証済みレコードの digest とサイズ |
| `FloorpWebExtensionPackageStore`（拡張） | 事前検証済みファイルを世代付きで原子的に導入・削除・復元 | verifier と downloader の検証結果 |
| `FloorpWebExtensionManifest`（既存） | MV3 manifest の閉じたサブセットとリソース参照を preflight | 導入候補の展開済みリソース |
| `FloorpWebExtensionCoordinator`（既存） | プロファイル／private mode／サイト権限を毎操作で適用 | 有効な package generation |
| Extensions UI（拡張） | カタログ表示、導入確認、権限同意、更新・失効状態の説明 | 検証済みカタログの表示専用メタデータ |

### 3.2 導入フロー

1. クライアントは、アプリ版・配布チャネル・ロケールを添えてカタログを要求する。
   認証トークンは短命で、パッケージ署名の代わりにはならない。
2. verifier は canonical JSON を再構成し、署名鎖、`audience`、`minAppVersion`、
   `expiresAt`、連番、失効鍵を検証する。失敗時は前回の検証済みカタログだけを
   表示してよく、新規導入と更新は無効にする。
3. UI は互換性、権限要約、プライバシー表示、ライセンス、版、審査日を表示する。
   導入ボタンは、選択した固定 `generation` にだけ紐付く。
4. downloader は一時ディレクトリへ取得し、最大サイズ、SHA-256、アーカイブ形式、
   パス安全性を検証する。リダイレクト先や追加リソースの追跡取得はしない。
5. package store は全ファイルをインベントリ化し、manifest とリソース参照、
   DNR ルール、許可された API を preflight する。失敗時は一時ディレクトリを
   消去し、現世代を維持する。
6. UI は最終的なサイト・API 権限をネイティブ画面で同意取得する。必要な同意が
   完了するまで、導入済みでも inactive とする。
7. 同意後にだけ、package store が新世代を原子的に active にし、coordinator が
   古い runtime／content rule を解放して新世代を合成する。

### 3.3 更新・失効・オフライン動作

- カタログの新しい `generation` は通知できるが、自動ダウンロード・自動有効化は
  しない。ユーザーが版と変更権限を確認して更新する。
- 更新で権限が同一または縮小しても、新成果物は別の SHA-256 を持つ。旧世代は
  新世代の正常な preflight と同意が完了するまで残す。
- 緊急失効では該当 generation を無効化し、DNR、content script、background、
  popup／options の package origin を停止する。失効はロールバック先を指定できるが、
  それも署名済みカタログの既存世代に限る。
- オフライン時は有効な既存パッケージをそのまま利用する。期限切れカタログを
  使って新規導入・更新・復活はしない。

## 4. カタログと成果物のデータ契約

### 4.1 `catalog-v1` の概要

カタログは canonical JSON の UTF-8 bytes に対して署名する。JSON を取得したまま
署名検証してはならず、重複キー、非正規数値、未知の署名対象フィールド、浮動小数点
表現を拒否する。署名アルゴリズムは P0 で確定するが、iOS で標準提供される
CryptoKit を利用できる Ed25519 を第一候補とする。

```json
{
  "schemaVersion": 1,
  "catalogID": "floorp-production",
  "sequence": 42,
  "issuedAt": "2026-09-01T00:00:00Z",
  "expiresAt": "2026-09-15T00:00:00Z",
  "audience": {
    "bundleIDs": ["one.ablaze.floorp"],
    "minimumAppVersion": "0.3.0",
    "channel": "production"
  },
  "signingKeyID": "catalog-2026-q3",
  "packages": [],
  "revocations": [],
  "signature": "base64url-ed25519-signature"
}
```

`sequence` は catalog ID ごとに単調増加とし、受理済みの最大値をキーチェーンまたは
改ざん検出可能なアプリ保存領域に保存する。時計が大きく後退した端末は更新を停止し、
既存の有効世代のみを使う。

### 4.2 パッケージレコード

| フィールド | 用途 |
| --- | --- |
| `extensionID` / `generation` / `version` | Floorp 内の一意な不変世代。Chrome の item ID を実行時 ID として流用しない。 |
| `artifactURL` / `artifactBytes` / `artifactSHA256` | 一つの成果物を取得・検証するための不変参照。URL は信頼根拠ではない。 |
| `manifestSHA256` / `resourceInventorySHA256` | manifest と展開後全リソースの期待値。隠しファイルを含む差し替えを検知する。 |
| `publisher` / `sourceProvenance` | 作者、配布許可、外部ストア item URL、取得日、審査担当を記録する。外部 URL は更新取得に使わない。 |
| `license` / `noticesDigest` | 再配布許可、ライセンス全文、notice／ソース公開義務への参照。 |
| `compatibilityProfile` | `content-script`, `dnr`, `action-storage` の対応状況と、拒否される API を示す。 |
| `requestedPermissions` / `hostPatterns` | ネイティブ同意で提示する、人間が読める最小権限。 |
| `privacyDeclaration` | データ種別、送信先、保持、作者連絡先、通報先。 |
| `reviewEvidence` | 静的検査、実機 OS、テストサイト、性能、レビュー日、承認者。 |
| `availability` | `available`, `updateAvailable`, `withdrawn`, `revoked`, `minAppVersion`。 |

成果物は `manifest.json`、宣言済みリソース、ライセンス・notice、Floorp 審査
メタデータだけを含む。`update_url`、リモート module、リモート DNR list、実行時の
コード生成、未宣言リソースは拒否する。

### 4.3 ローカル保存形式

プロファイル配下のパスは概念上次の形とする。

```text
WebExtensions/
  packages/<extensionID>/<generation>-<artifactSHA256>/...
  registry.json
  accepted-catalogs/<catalogID>-<sequence>.json
  revocations/<catalogID>-<sequence>.json
```

導入中は同階層の一時ディレクトリに展開し、全検査と同意の後に rename で確定する。
確定済みディレクトリを上書きしない。`registry.json` は現在の
`FloorpWebExtensionPackageStore` の generation・profile 境界と整合させる。

## 5. 3 つの初期互換プロファイル

カタログの掲載審査は、拡張名ではなく対応プロファイルで分ける。いずれも
`manifest_version: 3`、閉じた manifest preflight、固定リソース、最小ホスト権限が
前提である。

### 5.1 プロファイル A: コンテンツスクリプト中心

| 項目 | 設計 |
| --- | --- |
| 目的 | ページ表示の補助、読書性、フォーム補助、ページ内 UI の追加など。 |
| 許可する中心機能 | manifest 宣言の `content_scripts`、固定ファイルの `scripting.registerContentScripts`、isolated world の `runtime` メッセージ。 |
| ホスト権限 | カタログの match pattern を候補として示し、ユーザーがサイト単位で許可する。`activeTab` は明示操作から期限付きで付与する。 |
| 拒否する形 | リモート JS、`eval` 相当、`func`／`code` による `executeScript`、未宣言ファイル、MAIN world の `allFrames`、任意 document ID／subframe 対象。 |
| 実行境界 | navigation ごとにプロファイル、private mode、generation、frame URL、ホスト権限をネイティブ側で確認する。 |
| 受入試験 | document-start／end、サイト許可・撤回、private mode、タブ遷移、メッセージ認証、disable／uninstall 後の不実行を実機で確認する。 |

初期の実拡張候補は、完全にローカルリソースで動き、背景 fetch、任意コード注入、
広範な subframe 操作を必要としないものに限定する。

### 5.2 プロファイル B: DNR ベースの広告・追跡防止

| 項目 | 設計 |
| --- | --- |
| 目的 | 静的な広告・追跡ブロック、明確に変換できる allow、HTTPS 化。 |
| 許可する中心機能 | `declarativeNetRequest` の静的ルール、検証済みの dynamic／session block ルール、変換可能な `allow` と `upgradeScheme`。 |
| ルール供給 | ルール JSON は成果物に固定する。フィルター購読、URL からのリスト更新、import、差分パッチは初期版では扱わない。 |
| コンパイル | `FloorpWebExtensionDNRStore` と WebKit content rule compiler が、優先度・上限・変換可能性を検査する。曖昧な優先度は有効化せず拒否する。 |
| 拒否する形 | `redirect`、request／response header modification、`allowAllRequests`、matched-rule feedback、正確な Chromium priority parity。 |
| ユーザー制御 | 拡張単位の有効／無効、サイト単位の除外、失効時の停止。サイト除外は拡張に恒久的な追加権限を与えない。 |
| 受入試験 | 静的ルール、dynamic rollback、session 消去、サイト除外、private mode、Tracking Protection／No Image Mode との共存、性能上限を実機で確認する。 |

広告ブロッカーは機能・性能・誤ブロックの影響が大きいため、ルール数、展開サイズ、
コンパイル時間、メモリ、更新頻度をカタログ審査項目に含める。現在の互換契約にない
ルール action は「一部が無視される」のではなく導入拒否とする。

### 5.3 プロファイル C: ポップアップ・設定画面・`storage`

| 項目 | 設計 |
| --- | --- |
| 目的 | ブラウザ action、`default_popup`、options page、端末内設定、`alarms`、メッセージ駆動の状態管理。 |
| 許可する中心機能 | manifest 宣言の action popup、options resource、`storage.local`／`storage.session`、`alarms`、対応済み `runtime` メッセージ。 |
| ページホスト | popup と options は package origin の固定リソースだけを開く。外部 URL は通常タブとして開き、拡張権限を引き継がない。 |
| background | 既存の遅延起動・非永続 WebKit document を使い、runtime message と alarm だけで起動する。 |
| 拒否する形 | 真の Service Worker lifecycle、`importScripts`、任意ネットワーク fetch、永続 background page、`storage.sync`、未実装の wake event。 |
| 権限更新 | `permissions.request` は可視のネイティブ同意画面が導入されるまで fail closed。ポップアップ JavaScript の呼び出しだけでは同意にならない。 |
| 受入試験 | popup の表示・閉鎖、options の再起動後復元、storage quota／削除、alarm、disable／generation replacement 時の background 解放、private profile 分離を実機で確認する。 |

このプロファイルでは、拡張がアクションを宣言していない場合にも安全な空状態を
表示する。アラートは通常の `UIAlertController` として提示し、UIKit が所有する
presentation delegate を置き換えない。

## 6. P0〜P5 実装計画

| 段階 | 実装・設計成果物 | 完了条件 |
| --- | --- | --- |
| P0: 方針と承認 | App Review・法務・プライバシー判断、作者の再配布許可、運用責任、鍵保管、失効責任、公開／beta チャネルの決定記録 | 公開版の対象・非対象、承認者、緊急停止手順、レビュー時の再現手順が文書化される。 |
| P1: 信頼基盤 | `catalog-v1` schema、canonicalization、署名鍵階層、検証器、artifact SHA-256、ロールバック・失効状態、package store への原子的導入 API | 正常・改ざん・期限切れ・ロールバック・鍵失効・ZIP 攻撃のテストベクトルが全て fail closed で通る。 |
| P2: コンテンツスクリプト | プロファイル A のカタログ表示、サイト同意、導入・無効化・削除、実拡張の author-approved pilot、実機回帰 | 許可サイトだけで固定 content script が実行され、撤回・private mode・世代置換で実行が止まる。 |
| P3: DNR | プロファイル B の static/dynamic/session ルール、ルール上限・性能計測、サイト除外 UI、既存コンテンツポリシーとの合成試験 | 非対応 action を含むパッケージは導入されず、対応ルールはトランザクションで有効／復元される。 |
| P4: Action・設定・storage | プロファイル C、popup/options host、`storage`／`alarms`、可視の optional permission 同意、action を持たない拡張の空状態 | 再起動・世代更新・無効化・private profile でも状態と権限が境界どおりに動く。 |
| P5: 外部 TestFlight と公開判断 | カタログ運用監査、失効演習、実機 OS 行列、性能・アクセシビリティ、App Review 用テストアカウントとレビューガイド、段階配布 | P0 の承認、各パッケージの evidence、失効演習、外部テスターの受入結果を満たす。 |

P2〜P4 は順番に出すが、P1 のスキーマと verifier は共通である。P3 と P4 を
先に有効化するために、P2 のサイト同意や世代管理を迂回してはならない。

## 7. UI と利用者体験

内部カタログは「ブラウザ内部の互換性カタログ」として提示し、第三者アプリの
一般ストアには見せない。

### 7.1 カタログ一覧

各項目には以下を固定表示する。

- 名前、作者、Floorp 審査済み版、更新日、対応プロファイル。
- できること／できないこと、必要なサイト、必要な権限、private browsing の扱い。
- ライセンス、プライバシー情報、問題を報告する導線、失効・非公開状態。
- 「Chrome ウェブストア由来」の場合は provenance と作者の再配布許可。Chrome
  ウェブストアへ移動する導入ボタンや、ストアを模した検索結果は置かない。

### 7.2 導入確認

導入確認は、固定 generation と差分を必ず含める。

```text
<拡張名> <version> を導入します

- 選択したサイトでページ内容を読み取り、変更します
- この端末に設定を保存します
- 対応する追跡リクエストをブロックします（該当する場合）

承認するサイト: <site list / active tab>
パッケージ SHA-256: <short digest>
```

更新時は、旧版と新版の API 権限・host pattern・DNR capability・プライバシー
宣言の差分を表示する。いずれかが増える場合は「更新」ではなく新しい同意として
扱う。

## 8. 検証計画と受入条件

### 8.1 P1 共通の自動試験

- 正しい root／leaf 鍵、未知鍵、期限切れ鍵、失効鍵、鍵ローテーション。
- canonical JSON の重複キー、順序変更、Unicode 正規化、署名対象外フィールド、
  有効期限、連番・ロールバック。
- artifact の途中切断、サイズ超過、ハッシュ不一致、圧縮爆弾、symlink、`..`、
  重複パス、未宣言ファイル、manifest 二重化。
- 一時導入に失敗した場合、旧 generation が active のままであること。
- 失効時に content script、DNR、background、popup/options resource が停止し、
  データ削除の有無は明示されたポリシーに従うこと。

### 8.2 各プロファイルの実機試験

P2〜P4 の受入試験は、少なくとも現在の配布対象 iOS と最低サポート OS、通常・
private profile、ネットワーク遮断、アプリ再起動、カタログ更新、世代失効を含める。
各カタログ項目について次を release evidence に記録する。

| 記録 | 内容 |
| --- | --- |
| provenance | 作者、配布許可、取得元、ライセンス、notice、審査日。 |
| integrity | catalog sequence、署名鍵 ID、artifact／manifest／inventory digest。 |
| compatibility | 利用した MV3 API、拒否された API、実機 OS、テストサイト、既知の制限。 |
| privacy | ホスト権限、端末内／外部データ、通信先、保持、通報先。 |
| performance | 展開、preflight、DNR compile、ページ負荷、メモリ、battery 影響の測定。 |
| rollback | 無効化、失効、旧 generation 維持・復帰の演習結果。 |

既存の [Stage 3 release evidence](floorp-ios-webextensions-stage3-release-evidence.md)
は同梱 fixture 用の記録である。内部カタログの実拡張は、これとは別に上記の
package-specific evidence を持たなければならない。

## 9. 運用責任

| 役割 | 責務 |
| --- | --- |
| Product | カタログの掲載基準、更新ポリシー、導入 UI、サポート対象の決定。 |
| Security | 鍵管理、署名生成の監査、静的検査、失効判断、侵害時の演習。 |
| Legal / Privacy | 再配布許可、ライセンス、notice、データ利用、年齢区分、通報・削除運用。 |
| Engineering | verifier、package store、権限境界、互換性テスト、性能・クラッシュ回帰。 |
| Release | App Review の説明、外部 TestFlight、段階配布、失効時の告知と復旧。 |

カタログの掲載・更新・失効は二人以上の承認を要し、誰がどの artifact digest を
いつ承認したかを監査ログに残す。秘密鍵、認証トークン、ユーザー閲覧履歴、拡張の
保存データをカタログ監査ログに含めない。

## 10. P0 で確定すべき未決事項

1. 公開版でのリモート成果物提供に対する App Review の承認経路と、必要な
   reviewer exercise path。
2. カタログ認証の方式（Floorp account、アプリ証明、地域・年齢制限）と、
   アカウントを持たない利用者への扱い。
3. root／leaf 鍵の保管、署名権限、複数承認、緊急失効の責任者。
4. package format、canonical JSON、署名方式、最大サイズ、最大ルール数、
   catalog の最大有効期間。
5. 拡張を無効化・失効したときに `storage.local` と DNR dynamic state を
   保持するか削除するか。
6. 最初の author-approved 実拡張候補と、各作者の再配布・更新・サポート許可。

これらが確定するまで、現在の同梱 fixture カタログを公開版の唯一の導入元として
維持する。
