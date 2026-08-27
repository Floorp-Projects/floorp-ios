# Floorp iOS: 署名付き内部 WebExtensions カタログ設計

Status: signed-bundled catalog implementation contract; P0 approvals remain
required. This document does not authorize a remote package, an App Store
release, or redistribution of a third-party extension.

> 2026-08-27 safety clarification — a signed catalog authenticates fixed
> artifacts but never substitutes for the user's native confirmation. Every
> immutable replacement, including a same-or-reduced-authority security fix,
> stays on the current generation until a product-owned dialog binds the
> installed generation, replacement generation, artifact digest, and concrete
> authority delta. This preserves the requested no-silent-update boundary.

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

> 2026-08-26 実装上の明確化 — 最初の External TestFlight candidate は、**署名済みで
> アプリに同梱した catalog と FWEA1 だけ**を使う。端末は catalog／artifact をネットワーク
> から取得せず、アプリ資源中の `catalog.json`、root 公開鍵、固定 `FWEA1` を全て検証する。
> `managedRemoteSource` は有効化しない。この変更は、任意 URL や remote code を導入する
> ためではなく、実配布前に catalog の全 trust contract を検証可能にするための、より狭い
> 導入面である。

### 1.1 非目標

- Chrome ウェブストア、Firefox Add-ons、または任意 URL をアプリ内に一覧・
  検索・導入する一般ストア。
- CRX、ZIP、共有シート、ローカルファイルからの公開版への任意導入。
- カタログを通さない JavaScript、WASM、ルールリスト、CSS、画像の取得または
  更新。
- network catalog や任意 bytes による既存拡張の置換。更新は必ず新しい不変世代とし、
  catalog 署名・対象アプリ・期限・連番・失効・artifact/manifest/inventory digest と
  package preflight をすべて再検証する。権限差分の有無にかかわらず、更新は native
  confirmation なしに適用しない。
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

#### 2026-08-26: External TestFlight policy gate

最初の External TestFlight candidate は、catalog が署名済み・同梱済みであることだけを
理由に提出してはならない。Apple の現行 App Review Guideline 3.2.2(i) は、第三者の
apps、extensions、plug-ins の一般的 collection を表示する interface を不許可としている。
また、Guideline 4.7 は binary 外で提供する plug-ins に index、個別の同意、privacy、
年齢・reporting safeguards を求める。

2026-08-27 に Apple の現行ガイドラインを再確認した結果、3.2.1(ii) は specific approved need
に向けた第三者 app collection を robust editorial content とともに許容し得る。一方、現在の
16 本は accessibility だけに限定されない appearance/privacy/productivity/developer-tools を含む
横断的な collection であり、この条項を自己判断の例外根拠にしてはならない。4.7 は binary 外の
software を対象にするため、FWEA1 が app bundle にあることだけで 4.7 の適用可否を決めることも
できない。

従って、13 本の第三者互換ビルドを含む 16 本の固定 catalog は、次のいずれかを immutable release evidence として
記録するまで公開 candidate では無効のままとする。

1. Apple が、固定で non-downloadable な product-curated set の reviewer exercise path と
   許容性を確認する。
2. Product が user-facing surface を一般的な第三者 extension collection でなくなるよう
   範囲変更し、Security と Legal がその新しい review rationale を記録する。

これは verifier を弱める理由、任意 installer を公開する理由、または
`managedRemoteSource` を有効化する理由にはならない。

#### 2026-08-27: release-composition clarification

署名済み public output をアプリ bundle に入れるため、managed signer は clean な
reviewed source commit に対して `Artifacts/Signed/catalog.json` と root public key を
発行し、その出力も通常の review/CI/main integration を通る必要がある。Xcode Cloud は
source tree を archive するだけなので、main 統合後に signer を初めて実行しても、その
最初の binary に output は存在しない。したがって pre-merge source-bound signing、または
input を main に統合した後の public-output 専用の第 2 integration のどちらかを選ぶ。
private key を CI、Xcode Cloud、アプリ bundle に置くことでこの順序を迂回してはならない。

2026-08-27 の release-source binding 明確化として、catalog candidate は通常の
`main` TestFlight dispatch に任意の switch を足して起動してはならない。候補専用の
`Floorp Curated Catalog TestFlight Candidate` workflow は、現在の `origin/main` HEAD と同じ commit を
指す、保護された annotated `floorp-catalog-<40 lowercase commit SHA>` tag からだけ手動起動する。この
workflow は tag 名・annotation・tag commit・現在の `main` SHA の完全一致を Apple credential より先に確認し、protected release
environment の独立 root public-key SHA-256 と canonical signed catalog、固定 16 record、
bundle ID/channel/marketing version、全 FWEA1 digest/inventory/manifest を fail closed で
照合する。Xcode Cloud には branch ではなく同じ tag を `sourceBranchOrTag` として渡す。さらに
source-controlled post-clone gate が `CI_GIT_REF`、`CI_TAG`、`CI_COMMIT`、承認済み manual
workflow/bundle ID、実 checkout、取得し直した current `origin/main` の全一致を `xcodebuild` 前に
要求するため、tag move、stale main、auto start、別 workflow は archive 前に停止する。候補は
非同期完了を許さず、完了した run の `sourceCommit.commitSha` が tag の commit と一致しなければ
失敗にする。

GitHub の tag protection / force-update 禁止と、Xcode Cloud の manual tag start、および build
完了時に外部 TestFlight group / Beta App Review へ自動公開しない設定は repository 外の P0
release gate である。候補 workflow 自身は外部 group 割当・Beta App Review 提出を行わない。
それらは、source commit と processed App Store Connect build の readback を再確認した別の
明示的 release action に限る。この gate は managed-signing approval や Apple/Legal approval の
代替ではない。3.2.2(i) の書面上の reviewer path が得られない場合、より安全な代替は
Floorp-managed 3 package に初回 scope を縮小することだが、これは Product/Maintainer の
明示的な scope change が必要であり、16 package を自動的に置換してはならない。

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
| P0-gated catalog transport（未接続） | 固定 endpoint から catalog/失効情報を取得し、認証ヘッダーを付与する。任意 URL を受け取らない | ネットワーク応答は未信頼 |
| `FloorpWebExtensionCatalogVerifier` | canonical JSON、root/leaf 署名鎖、対象アプリ、有効期限、連番、鍵失効を検証 | レビュー済み composition が渡すアプリ同梱 root 公開鍵 |
| `FloorpWebExtensionArtifactDownloader` | 検証済みレコードで選択済みの一成果物のみを取得し、許可 host、redirect、サイズ、SHA-256 を検証 | 検証済みレコードの digest、サイズ、endpoint allow-list |
| `FloorpWebExtensionPackageStore`（拡張） | 事前検証済みファイルを世代付きで原子的に導入・削除・復元 | verifier と downloader の検証結果 |
| `FloorpWebExtensionManifest`（既存） | MV3 manifest の閉じたサブセットとリソース参照を preflight | 導入候補の展開済みリソース |
| `FloorpWebExtensionCoordinator`（既存） | プロファイル／private mode／サイト権限を毎操作で適用 | 有効な package generation |
| Extensions UI（既存 + P0-gated 拡張） | 公開版は同梱 catalog のみを表示する。承認後に限り、検証済み catalog の表示、導入確認、更新・失効状態を追加する | 検証済み catalog の表示専用メタデータ |

### 3.2 導入フロー

1. build/review 環境だけが ZIP、XPI、CRX、HTTPS、source checkout、または local
   input を**未信頼な審査入力**として受け取る。展開、安全検査、互換パッチ、license／notice
   と provenance の固定を済ませ、非圧縮 `FWEA1` と record digest を生成する。この入力
   parser は iOS client には存在しない。
2. managed signer が canonical `catalog.json` と root/leaf 署名鎖を発行する。公開版には
   root public key、署名済み catalog、`FWEA1` だけを同梱し、private key、input archive、
   review workspace、remote endpoint は同梱しない。
3. 起動時の verifier は canonical JSON、署名鎖、`audience`、`minAppVersion`、
   `expiresAt`、連番、失効を検証し、全ての同梱 artifact の SHA-256、manifest、inventory、
   manifest preflight まで通してから catalog を可視化する。ひとつでも欠けるか不正なら、
   catalog package は新規導入・更新・再有効化を fail closed する。
4. UI は署名済み metadata の互換性、権限要約、プライバシー表示、ライセンス、版、
   provenance を表示する。導入ボタンは、選択した固定 `generation` にだけ紐付く。
5. package store は検証済み resource map を profile 専用 staging directory に materialize
   し、DNR と許可 API を preflight してから atomic rename する。失敗時は staging を破棄し、
   現世代を維持する。
6. UI は最終的なサイト・API 権限をネイティブ画面で同意取得する。必要な同意が
   完了するまで、導入済みでも inactive とする。private browsing は通常 profile のコピー
   ではなく、別の ephemeral package installation として明示同意を要する。
7. 同意後にだけ、package store が新世代を原子的に active にし、coordinator が
   古い runtime／content rule を解放して新世代を合成する。

### 3.3 更新・失効・オフライン動作

- 新しい `generation` は新しい immutable artifact である。任意 URL、任意 bytes、
  extension-provided update URL、古い generation への自動 rollback は行わない。
- replacement は署名・audience・期限・sequence・revocation・artifact/manifest/inventory
  digest・FWEA1・preflight を満たすだけでは適用しない。candidate の semantic version が
  導入済み version より厳密に大きいこと、old/new version・generation・artifact digest・
  追加 API・追加 host（なければその旨）を表示する一回限りの native confirmation が成功する
  ことを必須とする。同値または旧 version を指す後続署名カタログは fail closed する。
- 更新履歴には generation、version、digest、適用時刻、`userApproved` を残す。catalog の
  再取得、署名の有効性、権限差分が空であることは confirmation の代替にならない。
- 緊急失効では該当 generation を無効化し、DNR、content script、background、
  popup／options の package origin を停止する。失効はロールバック先を指定せず、
  古い世代への自動復帰もしない。利用者が後で承認済みの別 generation を明示的に
  導入する場合にも、通常の署名・digest・同意検証を再実行する。
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
  "signingKey": {
    "keyID": "catalog-2026-q3",
    "publicKey": "base64url-ed25519-public-key",
    "notBefore": "2026-08-01T00:00:00Z",
    "notAfter": "2026-10-01T00:00:00Z",
    "signature": "base64url-root-signature"
  },
  "packages": [],
  "revocations": [],
  "signature": "base64url-ed25519-signature"
}
```

`sequence` は catalog ID ごとに単調増加とし、受理済みの最大値をキーチェーンまたは
改ざん検出可能なアプリ保存領域に保存する。時計が大きく後退した端末は更新を停止し、
既存の有効世代のみを使う。

### 4.2 パッケージレコードと掲載審査メタデータ

`catalog-v1` の実行可能な wire record は §4.4 に列挙した技術フィールドだけである。
以下の publisher/privacy/review フィールドは、P0 承認後に artifact ごとの掲載審査
記録・release evidence として必須にする。未承認のサーバー metadata を実行時の権限、
URL、コードとして扱ってはならない。

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
| `availability` | `available`, `updateAvailable`, `withdrawn`, `revoked`。最低 app version は catalog の `audience` で固定する。 |

成果物は `manifest.json`、宣言済みリソース、ライセンス・notice、Floorp 審査
メタデータだけを含む。`update_url`、リモート module、リモート DNR list、実行時の
コード生成、未宣言リソースは拒否する。

### 4.3 ローカル保存形式

プロファイル配下のパスは概念上次の形とする。

```text
WebExtensions/
  packages/<extensionID>/<generation>-<artifactSHA256>/...
  registry.json
```

導入中は同階層の一時ディレクトリに展開し、全検査と同意の後に rename で確定する。
確定済みディレクトリを上書きしない。`registry.json` は現在の
`FloorpWebExtensionPackageStore` の generation・profile 境界と整合させる。
受理済み最大 sequence、最大観測時刻、失効済み key/generation は profile data ではなく
catalog ID ごとの ThisDeviceOnly Keychain に保存する。catalog 本文を将来キャッシュする
場合も、それは表示用であり、新規導入・更新・再有効化の信頼根拠にはしない。

### 4.4 実装で固定する `catalog-v1` の安全な下位契約

P0 の署名方式と配布運用はまだ承認されていない。このため実装は公開版で
`managedRemoteSource` を有効化せず、次の下位契約をテスト可能な verifier として
実装する。これは P0 の承認に代わるものではなく、承認時に安全性を下げずに接続する
ための固定点である。

- canonical JSON は UTF-8、ASCII のフィールド名、重複キーなし、整数以外の数値
  なし、NFC でないキーなしとする。署名対象は最上位の `signature` を除く全フィールド
  を UTF-8 byte 順でキーソートして再直列化した bytes とする。未知フィールド、
  小数・指数表記、`-0`、署名対象外の任意フィールドは拒否する。
- catalog は root が署名した `signingKey`（`keyID`、Ed25519 public key、
  `notBefore`、`notAfter`、root signature）を含み、その leaf で catalog 本体を署名
  する。root public key はアプリ設定からのみ渡し、root private key・catalog endpoint・
  実運用 key ID はアプリに埋め込まない。catalog と leaf の有効期間は RFC 3339 UTC の
  秒精度、catalog は最大 14 日、leaf は最大 90 日とする。
  `keyID` は公開鍵そのものの不変な運用識別子であり、異なる公開鍵に再利用してはならない。
  鍵素材を変更する場合は新しい `keyID` と新しい immutable generation を発行する。
- `packages` の各レコードは `extensionID`、`generation`、`version`、
  `artifactURL`、`artifactBytes`、`artifactSHA256`、`manifestSHA256`、
  `resourceInventorySHA256`、`compatibilityProfiles`、`availability` を持つ。
  `generation` と artifact SHA-256 の先頭 16 文字から導くローカル generation は一度
  作成したら再利用しない。artifact URL は HTTPS の事前許可 host に限り、redirect、
  query、fragment、資格情報を拒否する。
- 成果物の wire format は任意の ZIP/CRX ではない、署名済みレコード専用の
  `FWEA1`（非圧縮、固定 inventory、各ファイルの SHA-256 と byte size）とする。
  ZIP magic、symlink、絶対/親相対 path、case/NFC collision、未列挙ファイル、圧縮・
  data descriptor は受け付けない。これにより ZIP Slip と展開爆弾の入力面を公開版から
  除去する。`FWEA1` を将来変更する場合も schema version を上げ、新しい verifier を
  追加して旧 parser の受入範囲を広げない。
- resource inventory digest は、path の UTF-8 byte 順で並べた
  `[{path,sha256,size}]` の canonical JSON に対する SHA-256 とする。manifest digest と
  inventory digest は artifact digest と独立に照合する。manifest preflight の閉じた
  MV3 subset に通らない候補は、署名が有効でも導入しない。
- 受理済み最大 sequence、最大観測時刻、失効済み key/generation は ThisDeviceOnly の
  Keychain に catalog ID ごとに保存する。時刻が最大観測時刻から 5 分を超えて戻った場合、
  または sequence が同値・低下した場合は、新規導入、更新、再有効化を拒否する。既存の
  有効世代はこの失敗だけでは削除しない。さらに、一度受理した
  `(extensionID, generation)`、`artifactSHA256`、その artifact を承認した leaf `keyID` の
  束縛を同じ Keychain state に保持し、後続 catalog が同じ generation を別 digest **または別 leaf**
  に再定義した場合も reject する。鍵ローテーションでは artifact bytes が同一でも新しい immutable
  generation を発行する。この厳格化により、ローカル registry record の key ID を新 leaf に
  書き換えて旧 key revocation を回避する経路を作らない。
- 再起動時の restore と利用者による再有効化では、永続化された package record だけを
  信頼しない。P0 composition が Keychain state に対して同じ `(extensionID, generation,
  artifactSHA256, leaf keyID)` の受理済み束縛と非失効状態を再確認し、満たせない catalog package は
  runtime を起動せず durable な revoked 状態にする。これにより、古い／局所的に偽造された
  record が通常の activation retry を通って実行されることを防ぐ。鍵ローテーションは新しい
  immutable generation と明示的 update consent を必要とし、旧 leaf の record を新 leaf として
  再解釈しない。失効した旧 leaf の record は停止する。
- `revocations` は catalog の署名対象であり、key または
  `(extensionID, generation)` だけを停止できる。失効は置換や古い世代への自動復帰を
  指示できない。失効時は runtime、DNR、page origin を先に停止し、`storage.local` と
  dynamic DNR state は P0 で承認される明示的ポリシーまで保持する。導入済み record は
  root-certified leaf `keyID` を保持し、key revocation でその key が導入した全 generation
  を停止する。新しい anti-rollback state は停止成功後にだけ Keychain へ commit する。
  この停止前の fan-out は revocation の一致だけでなく、新しい Keychain acceptance state が
  exact `(extensionID, generation, artifactSHA256, leaf keyID)` binding を承認しているかも再確認する。
  そのため、ローカル registry record の署名 key や digest を差し替えても、次の catalog acceptance
  時点で normal/private の全 runtime が停止する。
- `effectiveAt` が端末の検証時刻より未来である失効レコードは、catalog-v1 では catalog
  全体を reject する。将来の失効を記録するだけでは、アプリ再起動・端末時計変更・
  background 実行不可時に停止を保証できず fail-open になるためである。この制約を緩める
  には、永続化された scheduled revocation、確実な lifecycle wake-up、再起動・時計変更時の
  再評価、実機失効演習、P0 の再承認を同時に導入しなければならない。運用側は、それまで
  即時有効な失効だけを発行する。
- 既存 catalog package の更新は、現在の local generation、候補 catalog generation、
  候補 artifact SHA-256、lifecycle revision に束縛する。権限差分の有無にかかわらず一回限りの
  native confirmation を必須とし、既定の confirmation は拒否である。catalog の再取得、署名の
  有効性だけ、または任意の remote bytes から更新を導かない。
  `compatibilityProfiles` は表示用ではなく、固定 manifest が使う content-script／DNR／
  action-storage capability family をすべて含むことを導入時・再起動時に検査する。

この下位契約は、当初の「package format が P0 の未決事項」という記述をより狭くした。
理由は、任意の ZIP/CRX parser を公開版に置かず、artifact の受入形式そのものを
catalog record と同じ不変性境界に置くためである。P0 はこの契約、サイズ・ルール上限、
鍵保管、レビュー経路を承認または差し戻さなければならない。

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

**2026-08-27 の公開カタログ境界の絞り込み。** 上表は Stage 3 の汎用 DNR engine が
検証できる互換性上限である。一方、今回 External TestFlight に向けて作成する
`CuratedCatalog` の広告・追跡防止 artifact は、静的な `block` action だけに固定する。
package store は署名済み catalog artifact を導入・再起動復元する前にこの制約を再検査し、
`allow`、`upgradeScheme`、dynamic/session rule を含む artifact を fail closed で拒否する。
これは Stage 3 の既存 fixture 互換性を削らず、外部配布する狭い profile の安全境界を
追加する変更である。将来この profile を拡張するには、別の設計・法務/プライバシー・
性能/誤ブロック審査と署名済み generation を要する。

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

TestFlight を実機 OS 行列の取得に使う場合は、source-bound な candidate を最小の
承認済みテスター範囲に配る段階として扱う。candidate のインストール自体は P5 の受入結果
ではなく、通常・private profile、失効、アクセシビリティ、性能、battery の記録が揃うまで
P5 完了や一般公開を主張してはならない。この明確化は、実機検証を TestFlight 後に行う
運用順序を許容しつつ、P0/P5 の fail-closed な公開ゲートを弱めないためである。

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
