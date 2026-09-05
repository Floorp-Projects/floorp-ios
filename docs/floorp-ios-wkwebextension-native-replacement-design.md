# Floorp iOS `WKWebExtension` ネイティブ置換設計

- Date: 2026-09-04
- Status: Implemented / physical-device release validation pending
- Product floor: iOS / iPadOS 18.4 以降
- Runtime: WebKit の公開 `WKWebExtension` API のみ
- Legacy policy: 旧 Floorp WebExtension runtime、互換レイヤー、永続データ、切替フラグを最終成果物から全面削除

## 0. 実装状況（2026-09-03）

ネイティブ host、adapter、installer、registry v2、transaction/rollback、権限 UI、
action/options、通常・プライベート分離、extension URL surface history、旧 runtime の
全面削除、iOS 18.4 への deployment target 引き上げまで実装済みである。

iOS 26.5 Simulator / WebKit 8624.2.5.10.4 では、公式 Dark Reader Chrome MV3 ZIP の
`background.service_worker` が cold start 時に `loadBackgroundContent` の完了を返さず、
初回 content-script message の欠落、popup の loader 固着、非同期 toggle 処理の途中終了を
起こすことを確認した。nonpersistent background page への変換で初回 startup と action は
安定したが、35秒 idle 後には `DOCUMENT_CONNECT` が成功扱いのまま捨てられ、background が
wake しない。content script の有限再送、long-lived `runtime.Port`、`persistent: true` の
いずれもこの idle wake を保証しないため、package 内の回避策には依存しない。

そこで Dark Reader は、background を
`scripts: ["background/floorp-compat.js", "background/index.js"]`、`persistent: false` とし、
Safari storage の sentinel、unknown-error 限定 retry、直列化、exact readback、UI mutation と
close handshake を追加した Floorp 派生資産を同梱する。
派生 SHA-256 は `ebbb916a7b2bd8e3c5c6e538316fe3eea2e11875432522934f489697654cd761`、
上流 ZIP の SHA-256 は `20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64`
である。patch、再現 build script、両 digest、上流 revision を provenance に固定し、
App Review でも「無変更」とは表現しない。

派生資産の acceptance では background readiness、初回 navigation の暗色化、popup / GET_DATA、
site toggle と global toggle の off/on、空の `context.errors` を確認済みである。idle wake は
host navigation preflight で扱う。Dark Reader が有効でアクセス可能な main-frame HTTP(S)
navigation は policy decision を一時保留し、`loadBackgroundContent` の completion を待ってから
同じ action を一度だけ再評価する。3秒の上限で失敗時も通常 browsing を止めず、診断を残す。
35秒 idle、アプリ terminate/relaunch 直後の初回 page、実アプリ UI install は、この経路を含む
リリース前の実機相当検証対象とする。最小 DNR 拡張による block/redirect、
registry/rollback/history、Firefox 追跡防止と WebExtension 所有 content rule の共存も
integration test で確認している。

公式 uBOL Safari ZIP 2026.825.1619 から Floorp 派生 package を再現可能に生成する。
upstream SHA-256 は `89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94`、
派生 SHA-256 は `0bf4f4ce6716a971bcf03bf1e18612161a6005152a37b591bf54200b00eb5a6d`、
source commit は `080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b`、license は
`GPL-3.0-or-later` である。`uBOLite-floorp-ios-2026.825.1619.patch` は manifest に WebKit
公開権限 `declarativeNetRequestFeedback` を宣言して upstream の Developer-mode Matched
rules 導線を有効にし、popup の active tab にある数値の `windowId` を matched-rules の
`browser.tabs.create` へ伝えて、同じ通常／プライベート window に明示的に開く。さらに、
Report 導線も source の window ID／incognito を渡し、同一 URL の検索・再利用・新規 tab を
同じ window／realm に限定して、作成結果の privacy realm を検証する。
起動時の DNR・content script・設定・session storage・managed policy を待ち、起動中に届いた
Safari realm 更新を完了後に直列化する。起動中の失敗は readiness まで保持しつつ、後続の成功で
一時的な realm error を回復できる。閉鎖済み window の stale focus event を無害化してから、
Safari の local/session storage を領域別に直列化し、WebKit の unknown error だけを有限 retry
する。Safari local storage は最初の read より前に内部 sentinel を書いて DB を作成し、その行を
保持する。sentinel は uBO のキー列挙から除外する。read failure は空データとして扱わず、最終失敗を
readiness へ伝播する。content script
登録は既存内容を比較し、同一なら無操作、新規 ID は register、変更 ID は update、不要 ID は
指定 remove とする。さらに Safari では inert な persistent sentinel を更新前に1件保持する。WebKit の
update が対象行を delete してから add する際も DB が空にならず、使用中の
`RegisteredContentScripts.db` が unlink されることを避ける。ruleset details は ID 順へ正規化してから
script 定義を作り、列挙順の揺れを変更と誤判定する cold-start update も防ぐ。
local/session と realm 記録は同じ直列化・unknown-error 限定 retry 経路を使う。登録処理は
実状態を再読込する3回の bounded convergence とし、register/update/remove の部分適用後も
sentinel を更新・削除せず exact readback まで進める。background の起動／wake ごとに必ず実行し、
途中の API failure 後に sentinel だけが残った場合も欠落・stale 登録を自己修復する。
background listener の `{ error }` 応答は UI 共通送信層で reject へ変換する。filtering/popup mode は
content-script 更新失敗時に保存値を rollback し、popup slider、dashboard control、editor は旧値を
保持して自動 reload を行わない。popup/dashboard は error を `role=alert` で表示し、restore/import は
最初の失敗で中断する。dashboard の filter-list 変更は 997ms debounce と実行中 mutation を
単一 queue で直列化する。Floorp は Done、`window.close()`、外部 link 遷移の前に page-world の
`floorpPrepareToClose()` を待ち、DNR enabled rulesets の readback が要求選択と一致した
`{ ready: true }` の場合だけ surface を破棄して readiness cache を無効化する。失敗時は
dashboard を開いたまま accessible error を残す。Filter lists pane が一度も描画されず ruleset
mutation revision が 0 の場合は空 DOM を選択として適用せず、native の現 enabled set を readback
するだけにする。`beforeunload` flush は補助であり、終了順序の
保証には使わない。MV3 background page から WebKit の static DNR 更新が失敗する場合、readiness は
`foregroundReconciliationRequired` を返す。host は同じ context の可視 extension page で
`js/floorp-reconcile.js` を読み込み、durable target の static/derived DNR と script を exact
readback まで収束させた後だけ background finalize と `{ ready: true }` を認める。
同一拡張機能 origin からのみ応答する readiness handshake を context の初回 activation に使う。
`scripts/package-ubol-ios.sh` がこの監査済み差分を再現する。package の宣言どおり iOS 18.6
未満では利用不可にする。

2026-09-03 の full acceptance は、既定 113,100 static rules、日本語 1,906 rules、
network・dynamic・session blocking、通常・プライベート、generic cosmetic、custom /
procedural cosmetic、stock scriptlet、ruleset 更新、background suspension/wake 後の状態復元を含めて
162.250秒で合格した。公式 Safari build が無効化している strict-block interstitial は
既知の upstream WebKit 制約として検出し、通常の遮断機能とは別に扱う。

リリース前に残る外部ゲートは実機回帰と App Review である。GPL は Floorp の公開ソースと
審査メモへの明示を条件とし、技術的不合格には扱わない。

## 1. 結論

Floorp iOS の独自 WebExtension 実行系を、iOS 18.4 で公開された以下の
WebKit API へ置き換える。

- `WKWebExtension`: ZIP、manifest、リソースの読み込みと検証
- `WKWebExtensionContext`: 1拡張機能・1実行領域の状態、権限、action、options
- `WKWebExtensionController`: context の load/unload、WebView への統合、タブ・ウィンドウイベント
- `WKWebExtensionTab` / `WKWebExtensionWindow`: Floorp のタブ・ウィンドウを WebKit に公開する adapter

置換後、Floorp は `browser.tabs`、`browser.storage`、`browser.runtime`、DNR、
background、content script を実装しない。Floorp が引き続き持つのは、
インストール元の信頼確認、ユーザー権限 UI、拡張機能の有効・無効、
通常・プライベートの分離、Floorp のタブ UI との接続だけである。

リリース版には旧 runtime への fallback を残さない。ネイティブ host の初期化に
失敗した場合は、拡張機能を無効な状態にして通常のブラウズを続け、設定画面に
エラーを表示する。旧 runtime を起動することはない。

### 1.1 「全面削除」の範囲

本設計では次を全面削除の対象とする。

1. iOS 18.3 以下の Floorp iOS 製品サポート
2. 現在の独自 manifest parser、JS bridge、API host、DNR compiler、background
   page、storage、alarm、action、content-script coordinator
3. 通常・プライベートの旧 package store とその永続データ
4. 旧 runtime を再度有効にできる feature flag と fallback 分岐
5. 旧実装だけを検証する fixture、テスト、性能証跡、設計文書

共有ライブラリが別製品でも使われる場合、そのライブラリ自体の deployment target
まで機械的に引き上げる必要はない。ただし Floorp の app、first-party extension、
test host、UI test target は 18.4 に揃える。

## 2. 置換の境界

| 領域 | 置換後の所有者 | Floorp の責任 |
| --- | --- | --- |
| manifest / locale / icon parse | WebKit | 結果とエラーを UI に表示 |
| `browser.*` / `chrome.*` | WebKit | host 依存 API の delegate を実装 |
| content scripts / isolated worlds | WebKit | 対象 WebView に controller を接続 |
| background lifecycle | WebKit | load/unload とエラー監視 |
| DNR static/dynamic/session rules | WebKit | パッケージ互換試験、エラー表示 |
| extension storage | WebKit | profile の persistent controller と uninstall data purge を管理 |
| permissions / host access | WebKit context + Floorp UI | 同意取得、保存、復元 |
| tabs / windows | Floorp adapter | 実タブ操作と lifecycle 通知 |
| action popup / options | WebKit runtime + Floorp surface | 固定 popup の privacy-safe WebView と options modal を表示 |
| package trust / bundled catalog | Floorp | app code signature、固定 digest、provenance、配布方針 |
| install/update/uninstall transaction | Floorp | ZIP の staging と registry commit |

`WKWebExtension` は WebExtension ストアや Floorp の配布署名サービスではない。
ZIP を実行可能な WebExtension として解釈する部分は WebKit が担うが、
「その ZIP を Floorp が信頼して配布してよいか」は引き続き Floorp が判断する。

## 3. 目標構成

```text
Floorp app-bundled catalog / package ZIP
           |
           v
FloorpWebExtensionInstaller ---- FloorpWebExtensionRegistry
           |                      (app-owned metadata only)
           v
      WKWebExtension
           |
           v
FloorpWebExtensionProfileHost (1 / profile)
           |
           v
persistent WKWebExtensionController
           |
           +--- WKWebExtensionContext (1 / installed extension)
           |
           +--- normal WKWebViews  (persistent website data store)
           `--- private WKWebViews (non-persistent website data store)
                         |
                         v
            Tab / Window adapters + Floorp UI
```

### 3.1 新しい構成要素

新実装は `firefox-ios/Floorp/NativeWebExtensions/` に置き、旧ディレクトリの
型名を流用しない。

| 型 | actor | 役割 |
| --- | --- | --- |
| `FloorpWebExtensionProfileHost` | `@MainActor` | profile ごとの persistent controller、context、delegate、adapter の所有者 |
| `FloorpWebExtensionHostRegistry` | `@MainActor` | profile から host を取得し、WebView 構成と UI へ提供 |
| `FloorpWebExtensionInstaller` | `actor` | verify、stage、install、update、rollback、uninstall |
| `FloorpWebExtensionRegistry` | `actor` | app-owned metadata と permission snapshot の原子的保存 |
| `FloorpWebExtensionControllerDelegate` | `@MainActor` | permission、window/tab 作成、options、action popup、禁止 API |
| `FloorpWebExtensionAdapterRegistry` | `@MainActor` | Floorp Tab/Window と WebKit adapter の安定した同一性を保持 |
| `FloorpWKWebExtensionTab` | `@MainActor` | `WKWebExtensionTab` 準拠 |
| `FloorpWKWebExtensionWindow` | `@MainActor` | `WKWebExtensionWindow` 準拠 |
| `FloorpWebExtensionNavigationRouter` | `@MainActor` | 通常 URL と拡張 URL の WebView 切替 |
| `FloorpWebExtensionSettingsViewController` | `@MainActor` | install、permission、private、errors、options UI |
| `FloorpWebExtensionLegacyCleanup` | `actor` | 既知の旧パスだけを一度限り削除 |

`WKWebExtension`、context、controller、tab/window protocol は UI actor API である。
Installer actor は file/digest/journal 処理だけを行い、parse、context 構築、load/unload は
必ず `FloorpWebExtensionProfileHost` の `@MainActor` method へ委譲する。

## 4. normal/private の分離

### 4.1 controller は profile あたり1個

profile ごとに stable UUID を持つ persistent controller を1個生成し、normal/private
双方の WebView へ同じ controller を接続する。installed extension ごとの context も
1個だけ生成する。これは WebKit が private window を
`WKWebExtensionContext.hasAccessToPrivateData` で公開する標準モデルに合わせるためである。

| 領域 | controller / context | `WKWebsiteDataStore` | `WKUserContentController` |
| --- | --- | --- | --- |
| normal tab | profile の persistent controller/context | persistent | normal 専用 |
| private tab | 同じ controller/context | non-persistent | private 専用 |

private toggle は context の `hasAccessToPrivateData` を変更し、その値を registry へ
保存する。OFF の context には WebKit が private window/tab/cookie を公開しない。
controller/context を private 用に二重起動しないため、background、`onInstalled`、
action、DNR、runtime ID の意味が Safari とずれない。

このモデルでは private tab の cookie、cache、website storage は non-persistent だが、
拡張機能自身の永続 area（`browser.storage.local` / `sync`）と拡張設定は profile の
extension storage である。`storage.session` の lifecycle は WebKit に任せる。private
access を許可した拡張機能は、private page から得た情報を自身の永続 storage へ保存
できる。設定 UI でこの点を明示する。Floorp 独自に storage API だけを ephemeral 化しない。

### 4.2 論理ウィンドウ

Floorp は1つの UI scene 内に normal/private の両方のタブを保持し、表示モードを
切り替える。一方 `WKWebExtensionWindow.isPrivate` は、その window の存続中に
変化しない前提で WebKit に cache される。

そのため、1つの `WindowUUID` を WebKit へ直接公開せず、次の2つの論理 window
adapter に分ける。

```text
Floorp scene WindowUUID X
  |- FloorpWKWebExtensionWindow(X, normal)  -> normal tabs only
  `- FloorpWKWebExtensionWindow(X, private) -> private tabs only
```

同じ controller の delegate は、context の `hasAccessToPrivateData` に応じて WebKit が
filter できるよう、normal/private 両方の論理 window を返す。privacy mode の切替時は
表示された realm の adapter を `didFocusWindow` で通知する。これにより private 属性が
途中で変化する adapter を作らずに済む。

## 5. WebView 構成

### 5.1 初期化順序

profile startup で次の順に構築する。

1. normal の標準 `WKWebViewConfiguration` の専用 copy を作る
2. その copy を `WKWebExtensionController.Configuration.webViewConfiguration`
   の基底構成にし、profile の persistent controller を生成する
3. controller に delegate を設定する
4. normal/private の tab 構成に別々の `WKUserContentController` と、persistent /
   non-persistent の適切な `WKWebsiteDataStore` を設定する
5. 両方の tab 構成の `webExtensionController` に同じ profile controller を設定する
6. その後に限り、tab restore と最初の `WKWebView` 作成を許可する

現在の `Tab.createWebview` は `userContentController` を作り直す。この処理の後でも
`webExtensionController` が残るようにし、`WKWebView` initializer の直前に次を
assert する。

- normal/private tab は profile の同じ controller
- private tab の data store は non-persistent
- normal/private の `WKUserContentController` は同一 instance ではない

content script と DNR を最初の navigation から有効にするため、この構成は scene
開始後に後付けしない。

### 5.2 拡張 URL 用 WebView

WebKit の公開契約では、拡張 URL は必ずその context の
`context.webViewConfiguration` で作った WebView に読み込む必要がある。
通常構成の WebView へ拡張 URL を読み込むことも、拡張構成の WebView へ通常 URL を
読み込むこともできない。

| target URL | 使用する構成 |
| --- | --- |
| `http` / `https` / Floorp internal page | tab の normal/private 標準構成 |
| extension A の base URL | extension A context の `webViewConfiguration` の copy |
| extension B の base URL | extension B context の `webViewConfiguration` の copy |

private tab の extension surface は、context 構成の copy に既存の private
non-persistent data store と private 専用 `WKUserContentController` を設定してから
WebView を作る。context が同じでも private surface を persistent store で作らない。

## 6. URL 境界を越える navigation

`FloorpWebExtensionNavigationRouter` は navigation action の URL を
`controller.extensionContext(for:)` で判定する。

### 6.1 normal page から extension page

1. 通常 WebView の navigation を cancel
2. 該当 context、tab の private state、`hasAccessToPrivateData` を確認
3. context の構成から extension WebView を生成
4. Tab の active surface を extension WebView へ切り替える
5. 元の通常 WebView は破棄せず suspend して back-forward state を保持
6. extension URL を load
7. controller へ URL/loading property change を通知

### 6.2 extension page から normal page

1. extension WebView の navigation を cancel
2. suspend 済みの通常 WebViewを active surface に戻す。存在しなければ標準構成で生成
3. 対象 URL を通常 WebView で load
4. 不要になった extension WebView を破棄

別の extension context へ移動する場合も同様に、移動先 context 専用の WebView へ
切り替える。

`Tab.webView` は active surface を返す computed property に変更し、内部では
`websiteSurface` と一時的な `extensionSurface` を所有する。surface 切替時は現在の
`LegacyTabDelegate.didCreateWebView` / `willDeleteWebView` の責務を
attach/detach callback へ整理し、BrowserViewController の KVO、autofill、UI delegate、
navigation delegate を active WebView だけに結び直す。suspend は detach であり、
通常 WebView の破棄ではない。

Floorp の通常ページ向け `UserScriptManager` script、reader mode、autofill script は
website surface のみに入れる。extension surface には WebKit が context 用に生成した
構成と、ブラウザ UI が不可欠と確認された処理以外を注入しない。拡張ページと通常
ページの script world を Floorp 側で混在させない。

### 6.3 history 境界

WebView をまたぐ履歴は `WKBackForwardList` だけでは表現できないため、Tab に
`FloorpNavigationSurfaceHistory` を追加する。境界ごとに次を保持する。

- source surface (`website` または context identifier)
- source WebView の interaction state
- target URL
- push / replace の navigation 意味

各 active WebView 内に back/forward item がある場合は WebKit の履歴を優先する。
item がなく surface history がある場合にだけ別 surface へ戻す。Tab を閉じる時は
active/suspended の全 WebView を閉じる。

この処理は uBOL の DNR redirect 先 `strictblock.html` を動かすための release blocker
である。popup や options だけ動いても、この条件を満たすまでは uBOL 対応としない。

### 6.4 popup と options

- iOS 26.5 では `WKWebExtensionAction.popupViewController` / `popupWebView` が
  controller の永続 `WKWebsiteDataStore` を継承することを実測した。そのため
  private tab の action ではこれらの getter を呼び出さない
- bundled catalog に digest 固定の `action.default_popup` path を保持し、
  `context.webViewConfiguration` の copy に元 tab と同一の data store と surface 専用
  `WKUserContentController` を設定した WebView で表示する
- action の user gesture は公開 API `userGesturePerformed(in:)` で開始し、popup の
  close、元 tab の遷移／終了／選択解除、scene focus 移動、disable、private 許可取消、
  uninstall、host teardown のすべてで `clearUserGesture(in:)` と WebView 停止を行う
- package verifier は popup path の完全一致と ZIP entry の存在を確認し、
  `action.setPopup` / `action.openPopup` と予約済み `_execute_*` command を拒否する
- options は `context.optionsPageURL` と `context.webViewConfiguration` を使う専用 modal
  とし、通常タブの WebView を不要に切り替えない
- uBO options の終了は package の close handshake を最大5秒待つ。明示的な
  `ready: true` 以外では閉じず、interactive swipe も禁止する。host teardown だけは待たず破棄する
- extension が `tabs.create` で拡張 URL を開いた場合は、最初から extension surface の
  Tab を作る

この popup surface は WebKit の context configuration を使い、`browser.*` の実行は
引き続き WebKit が担う。旧 `FloorpWebExtensionPageHost` や popup 用 JS bridge は残さない。

## 7. Tab / Window adapter

adapter は `Tab` 自体を protocol 準拠させず、安定した wrapper object として作る。
WebKit は object identity を tab/window identity として使うため、同じ Floorp Tab に
毎回新しい wrapper を返してはならない。

### 7.1 Tab adapter が提供する情報と操作

- realm に対応する window、index、parent
- active WebView、title、URL、loading、selected/active/private state
- activate、close、load URL、reload、go back、go forward
- parent の設定、mute/reader/pinned のうち Floorp が実装可能なもの
- `shouldBypassPermissions = false`

未実装の optional method は、成功したように見せる no-op にしない。
WebKit が feature detection できるよう method を実装しないか、該当 API を
`context.unsupportedAPIs` に指定する。

### 7.2 lifecycle の接続

既存の `TabManagerDelegate` と `TabEventHandler` から次を controller へ送る。

| Floorp event | WebKit notification |
| --- | --- |
| tab add | `didOpenTab` |
| tab remove | `didCloseTab` |
| selected tab change | `didActivateTab` |
| URL/title/loading change | `didChangeTabProperties` |
| reorder / move | `didMoveTab` |
| logical window open/close | `didOpenWindow` / `didCloseWindow` |
| scene focus / privacy switch | `didFocusWindow` |

context load 前の初期 tab/window 一覧は controller delegate の
`openWindowsFor` と `focusedWindowFor` から返す。restore 完了後に同じ tab を
`didOpenTab` で二重通知しないよう、adapter registry に published 状態を持つ。
WebView surface の切替は同じ Floorp Tab adapter の内部変更なので `didReplaceTab` は
送らず、URL/loading などの property change だけを送る。

### 7.3 action の実行

拡張機能メニューを開く直前に `context.action(for:)` を取得し、label、icon、badge、
enabled state を表示する。ユーザーが押した直後にも action の identity、
`isEnabled`、`presentsPopup`、元 tab の selected/focused/privacy state を再確認する。
固定 popup がある reviewed bundled extension では `userGesturePerformed(in:)` と
前節の privacy-safe surface を使う。popup を持たない action だけは
`context.performAction(for:)` で WebKit の click semantics を使う。`didUpdateAction` delegate で
表示中のメニューを更新する。

## 8. Package と install 経路

### 8.1 v1 で許可する source

| source | v1 | 信頼根拠 |
| --- | --- | --- |
| app bundle の reviewed ZIP | 有効 | app code signature + catalog の固定 SHA-256 |
| remote catalog | 未提供 | v1 binary に download、更新、install 経路を持たせない |
| ユーザーが任意 ZIP を import | 無効 | 配布・App Review・安全審査を別途設計するまで不可 |

Floorp は ZIP を自前で展開して manifest を実行しない。
`WKWebExtension(resourceBaseURL:)` へ ZIP の file URL を直接渡す。
Floorp 側の事前処理は app-bundled source、固定 metadata、digest、総サイズ、ファイル形式の
上限確認に限定する。

### 8.2 install transaction

```text
download / bundled URL
        |
        v
verify source + digest + size
        |
        v
immutable staging
        |
        v
WKWebExtension(resourceBaseURL: ZIP)
        |
        +-- fatal/unapproved diagnostic --> reject + remove staging
        |
        v
permission summary + user confirmation
        |
        v
create context(s), restore grants, controller.load
        |
        +-- failure --> unload partial contexts + rollback
        |
        v
commit registry + immutable package reference
```

`WKWebExtension` が返す display name、version、icon、requested permissions、
requested/optional match patterns を install UI の正本にする。Floorp 独自の完全な
manifest model は作らない。

initializer 自体の失敗は常に reject する。`WKWebExtension.errors` は、object を
生成できる非致命的な診断も含み得るため、一律に失敗とはしない。reviewed catalog
package は OS/package version ごとに承認済み error code の集合を記録し、新規または
未知の診断が増えた場合だけ release/install を停止する。load 後に発生する
`WKWebExtensionContext.errors` は settings に表示し、同期 load failure でない限り
自動 uninstall しない。

catalog item は次だけを持つ。

- Floorp catalog ID
- bundle resource または managed URL
- expected SHA-256 と version
- stable context identifier / reviewed base URL scheme / base URL host
- package-specific minimum OS
- source/license/review metadata
- product policy で明示的に無効にする host-dependent API

拡張 ID による runtime 分岐は作らない。

### 8.3 base URL と runtime ID

各インストール時に stable context identifier と host を生成し、更新後も保持する。

- `context.uniqueIdentifier`: registry の stable ID
- `context.baseURL`: catalog で固定した `<reviewed-scheme>://<stable-host>/`

既定 scheme は `webkit-extension` とする。review 済みの Safari package が upstream の
WebKit compatibility 分岐に scheme を利用する場合に限り、catalog がその scheme を固定し、
context 作成前に `WKWebExtension.MatchPattern.registerCustomURLScheme` で登録する。現在は
review 済みの uBlock Origin Lite Safari 派生 asset にだけ `safari-web-extension` を使い、
upstream の Safari 向け回避策を有効にする。任意 package が scheme を指定する経路は持たず、
extension ID による JavaScript patch や runtime API 分岐も作らない。

### 8.4 Dark Reader の iOS compatibility package

Dark Reader は runtime 分岐ではなく、review 済みの派生 ZIP として catalog に固定する。
画像、CSS、locale は上流のまま、manifest の background 宣言を iOS 対応の
nonpersistent background page 形式へ置換する。さらに Floorp compatibility script が
Safari storage の作成・直列化・unknown-error 限定 retry・exact readback を担当し、background
と各 UI surface は mutation 完了と close readiness を明示応答する。

- 上流: `darkreader-chrome-mv3.zip` v4.9.129、SHA-256
  `20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64`
- 派生: `darkreader-floorp-ios-mv3-4.9.129.zip`、SHA-256
  `ebbb916a7b2bd8e3c5c6e538316fe3eea2e11875432522934f489697654cd761`
- patch: `Bundled/darkreader-floorp-ios-mv3-4.9.129.patch`
- build: `scripts/package-darkreader-ios.sh`
- license: MIT、source revision `c2a707302a39b8047543712e9c582bac07835d34`

build script は上流 digest を検証してから patch を適用し、timestamp と ZIP metadata / ordering
を正規化する。CI verifier は派生 ZIP、patch、build script、provenance、manifest の
`background.scripts` と `persistent: false` を fail-closed で照合する。

この manifest 変換だけでは WebKit が idle 後に background を自動 wake する保証にならない。
そのため catalog は Dark Reader と uBO Lite に `requiresNavigationBackgroundReadiness` を設定する。
権限を持つ main-frame HTTP(S) navigation の policy callback では、host が次を行う。

1. 元の `WKNavigationAction` を保留する。
2. 読み込み済み extension context に public `loadBackgroundContent` を呼ぶ。
3. Dark Reader は毎回3秒を上限に待ち、失敗を diagnostic log に残して navigation を許可する。
   uBO Lite は context lifecycle 内の通常／private 各 realm の初回だけ strict readiness を最大90秒待ち、
   一過性の WebKit probe は15秒以内の単位で再試行し、
   失敗時は navigation を止めて次回に再試行し、成功した realm は以降の navigation で待機しない。
4. action identity を prepared set に入れ、同じ policy chain を一度だけ再評価して navigation を許可する。

prepared identity は再評価時に consume し、preflight の無限再帰を防ぐ。extension が無効、URL
access がない、private access がない、subframe、非 HTTP(S) の場合は preflight しない。
uBO Lite の成功 cache は context unload/update/teardown、private access 境界で破棄する。
scene の8秒 UI budget を過ぎても enabled uBO の cold restore が未完了なら初回 HTTP(S) navigation は
fail-closed のまま terminal readiness を待つ。restore error も広告素通しにはせず、明示 disable で解除する。
Dark Reader の timeout/error は通常 browsing を止めない。package 側の storage/readback と
UI close handshake はデータ永続性を保証するが、navigation の可用性方針は host の3秒
fail-open を維持する。

## 9. Registry と WebKit state

新 registry は `WebExtensionsV2/registry-v2.json` に原子的に保存する。
package bytes は bundled resource を直接参照するか、managed package の場合のみ
`WebExtensionsV2/packages/<catalog-id>/<digest>/extension.zip` に置く。

1 extension record は次を持つ。

```text
top-level: schemaVersion / controllerIdentifier

extension record:
catalogID
contextIdentifier
baseURLHost
packageSource / packageReference / sha256
installedVersion
enabled
allowedInPrivateBrowsing
grantedPermissions + expiration
deniedPermissions + expiration
grantedMatchPatterns + expiration
deniedMatchPatterns + expiration
hasRequestedOptionalAccessToAllHosts
installedAt / updatedAt
transactionState
```

permission key は `WKWebExtensionPermission.rawValue`、match pattern は pattern string、
expiration は ISO-8601 で保存する。context を load する前に復元する。WebKit の
permission notification を監視し、変更後の context snapshot を registry へ保存する。

WebKit が所有する次のデータを registry へ複製しない。

- `browser.storage.*`
- dynamic/session DNR rules
- background listener/state
- registered content scripts
- action state
- alarm state
- extension page website data

## 10. 権限と host-dependent API

### 10.1 初回権限

install UI で required API permission と host match pattern を人間向けに要約する。
ユーザーが承認した項目だけを context の grant dictionary に入れる。optional permission
は必要になった時に controller delegate から native consent UI を表示する。

private access は host permission と分け、設定画面の独立した toggle とする。
toggle は `context.hasAccessToPrivateData` を変更して永続化する。OFF にした時点で
private tab/window/cookie への extension access を失効させる。既に private page の DOM
へ注入済みの効果を確実に除くため、Floorp が該当 private tab だけを自動で reload する。

### 10.2 初期状態で禁止する API

v1 では少なくとも次を `unsupportedAPIs` または delegate error で fail closed にする。

- `browser.runtime.connectNative`
- `browser.runtime.sendNativeMessage`
- Floorp native application との任意 message channel
- Floorp が adapter を実装していない window mutation

対応していない API を Floorp の JS bridge で補完しない。将来対応する場合も、
extension ID ではなく API 単位で adapter を追加する。

## 11. Startup / enable / update / uninstall

### 11.1 startup

1. `FloorpWebExtensionLegacyCleanup` を一度実行
2. registry を読み、整合性、中断 transaction、stable controller UUID を回復
3. profile ごとの persistent controller を構築
4. enabled extension の ZIP から `WKWebExtension` を生成
5. permission、ID、private-access state を設定した context を load
6. context error notification の監視を開始
7. host state を `.ready` または `.degraded(errors)` にする
8. scene/tab restore の gate を解除

起動に失敗した1拡張機能は隔離して他の extension とブラウザ起動を妨げない。
controller 自体の初期化に失敗しても scene は開始するが、extension UI に degraded
状態を表示する。

### 11.2 enable / disable

- disable は先に disabled を永続化し、popup/options を閉じ、影響を受けたタブを reload
  してから context を unload する
- WebKit が同一プロセス内の同一 extension identity の unload/load を安全に完了できない
  OS では、unload 後の enable は context を再 load しない。要求元 process ID と
  `enableOnNextColdLaunch` を registry に保存し、拡張機能は inactive のままにする
- 次のコールド起動では process ID が変わったことを確認して context を1回 load し、
  background readiness の成功後に enabled を commit して deferred state を消す。失敗時は
  disabled に戻し、次のコールド起動へ再度 defer する
- 設定画面は「再起動後に有効」を明示し、待機中の要求をキャンセルできる。以前の起動で
  無効のまま終了した extension は、新しいプロセスでは通常どおりその場で有効化できる

### 11.3 update

1. 新 ZIP を stage し、旧 context を動かしたまま parse/validate
2. 同じ controller で対象 identity の load を一度でも試行済みなら、旧 context を変更せず
   「Floorp の再起動が必要」として更新を中止する。コールド起動後も未 load の disabled
   context はこの制約に該当しない
3. 対応済み bundled package migration は、次のコールド起動で context を生成する前にだけ実行する
4. permission snapshot と旧 package reference を rollback record に保存し、新 context を1回 load する
5. background readiness が成功したら registry を commit し、旧 managed package を削除する
6. load に失敗した場合は新 context を fail-closed で unload して旧 record を戻し、同一プロセスでは
   旧／新どちらの identity も再 load せず、次のコールド起動で回復を再試行する

crash recovery 用に `preparing`、`switching`、`committed` の journal state を持つ。
起動時に `committed` でない update は旧 package を正として、context の初回 load 前に回復する。

### 11.4 uninstall

1. registry record を `pendingPurge` にし、package reference、context ID、base URL を保持
2. context を profile controller から unload
3. `fetchDataRecord` で対象 context の WebKit data record を取得
4. unload で無効化済みとなる `.session` を除いた
   `WKWebExtensionController.allExtensionDataTypes` を指定して永続データを削除
5. registry の permission/context record と managed ZIP を削除
6. crash で `pendingPurge` が残った場合は context を再構築せず、保持した identity から
   次回 startup で data purge を再試行

## 12. Settings UI

設定画面には次を表示する。

- installed / available
- enable と、unload 後の再有効化、更新、アンインストール直後の再インストールに
  再起動が必要な状態
- 「プライベートブラウジングで許可」と、拡張機能自身の設定/storage は profile に
  残り得る旨の disclosure
- required/optional API permission と site access
- version、source、license
- `WKWebExtension.errors` と `WKWebExtensionContext.errors` の診断
- options page
- update / uninstall
- package minimum OS を満たさない場合の unavailable 表示

native v1 では Dark Reader を自動インストールしない。旧 registry を完全削除する一方、
過去に user が uninstall した拡張機能を黙って再インストールしないためである。
Dark Reader は reviewed bundled catalog item としてユーザーが明示的に install する。

将来自動インストールを復活させる場合は、旧 uninstall intent を保持する tombstone
migration が必要になり、「旧データを全面削除」という本決定の例外として別承認する。

## 13. iOS version policy

### 13.1 deployment target

次を `IPHONEOS_DEPLOYMENT_TARGET = 18.4` に変更する。

- `Client` / Floorp app
- app に埋め込む first-party extension target
- Client test host / UI test target
- CI の最低 OS simulator と release validation matrix

`WKWebExtension` path から `if #available(iOS 18.4, *)` と旧 fallback を削除する。
deployment target 引き上げ後、first-party app 内の 18.4 未満向け availability branch
も dead-code cleanup の対象にする。third-party/shared package は利用先を確認して別に扱う。

### 13.2 package-specific floor

app の floor と extension package の floor は別である。現在の uBOL Safari manifest は
`browser_specific_settings.safari.strict_min_version = 18.6` を宣言している。

- iOS 18.4 / 18.5: native WebExtension host と対応 package は利用可、現行 uBOL は unavailable
- iOS 18.6 以降: uBOL の install/enable 試験対象

manifest の minimum version を Floorp が書き換えたり無視したりしない。uBOL を全対応
端末で必須にする製品判断なら、app floor 自体を 18.6 へ上げる。

## 14. 旧実装の削除

### 14.1 source

現在の `firefox-ios/Floorp/WebExtensions/*.swift` は全て削除する。対象には以下を含む。

- API host / message runtime / page host
- runtime / coordinator / content policy coordinator
- manifest / types / i18n / permissions
- DNR compiler / content-rule-list composition
- scripts / tabs / storage / alarms / action
- package store / live package manager / catalog
- compatibility harness / Stage 3 performance evidence
- 旧 settings view controller / setting row

同じファイルを中身だけ残して native facade にしない。新実装は
`NativeWebExtensions/` に明確に作り直す。

### 14.2 呼び出し元

| 現在の場所 | 変更 |
| --- | --- |
| `FloorpBootstrapper.swift` | 約700行の composition を削除し、profile host startup/teardown 呼び出しへ置換 |
| `DependencyHelper.swift` | native profile host を tab restore 前に開始 |
| `SceneDelegate.swift` / `AppEvent.swift` | gate を native host readiness へ改名 |
| `AppDelegate.swift` | custom background release を削除、profile host teardown のみ |
| `Tab.swift` | document generation、policy prepare、bridge、custom DNR hook を削除。controller attachment と surface router を追加 |
| `BrowserViewController+WebViewDelegates.swift` | pre-navigation custom policy hook を削除し、extension URL routing を追加 |
| `BrowserCoordinator.swift` | 旧 JS popup resolver を削除し、WebKit action と native host UI へ置換 |
| `SettingsCoordinator.swift` | native settings controller へ置換 |
| `FloorpFlags.swift` | `FloorpWebExtensionFeature` と旧 runtime flag を削除 |
| `Prefs.swift` | 旧 Dark Reader install marker を削除。新 controller UUID/cleanup version のみ追加 |

### 14.3 tests / fixtures / documents

旧 `FloorpWebExtension*Tests.swift`、独自 DNR test、compatibility/performance test を
project 参照ごと削除する。`demanding-mv3`、`event-runtime-mv3`、
`content-messaging-mv3` など旧 bridge 専用 fixture も削除する。

expanded Dark Reader fixture は、上流 ZIP に review 済み Safari durability patch を再現適用した
canonical 派生 ZIP、license、provenance、patch、build script へ置換する。Floorp 独自
`fixture-metadata.json` は新 catalog metadata へ移す。

旧独自 runtime を記述する以下の文書は、native 設計・native compatibility matrix と
置換した後に削除する。

- `floorp-ios-webextensions-mv3-design.md`
- `floorp-ios-webextensions-mv3-limitations.md`
- `floorp-ios-webextensions-stage3-release-evidence.md`
- `floorp-ios-webextension-api-ubol-design.md`

### 14.4 永続データ cleanup

旧データは変換しない。profile root 配下で次の既知パスだけを削除する。

```text
WebExtensions/ContentRuleLists/normal
WebExtensions/CompatibilityEvidence/normal
WebExtensions/Packages/normal
WebExtensions/APIHost/normal
```

一時領域は、temporary directory 直下の既知 root
`floorp-webextensions-private/` だけを検証して削除する。
旧 preference `webExtensions.darkReaderMV3InitialInstallCompleted` も削除する。native v1 は
default install を行わないため、この marker を新 registry へ移さない。

cleanup は次を必須とする。

- profile root / temporary root の直下であることを canonical path で検証
- symlink を辿らない
- 列挙した相対パス以外を削除しない
- 成功後に `webExtensions.nativeLegacyCleanupVersion = 1` を記録
- 失敗は log と settings diagnostic に残し、次回再試行

`WebExtensions`、profile root、temporary root 全体への無条件 recursive delete は禁止する。

この purge では旧 `browser.storage`、拡張設定、dynamic rule、enable state を復元しない。
旧 runtime が一般ユーザー向け build に一度でも出荷済みなら、これは明示的なデータ消失を
伴う breaking migration になる。その場合は release note と事前告知を必須とし、
必要なら「全面削除」の決定を再確認する。未出荷の開発実装であれば、そのまま実施する。

## 15. 実装順序

開発中も、同じ WebView に旧 runtime と native controller を同時接続しない。
二重 content-script injection と二重 DNR を避けるためである。

### Phase 0: baseline

- current build/test result と変更中ファイルを固定
- Dark Reader の再現可能な派生 ZIP と uBOL の upstream ZIP、digest、license、provenance を用意
- iOS 18.4 / 18.6 / current simulator matrix を CI に用意

### Phase 1: OS floor と native host skeleton

- deployment target を 18.4 へ変更
- profile host、persistent controller、registry skeleton を追加
- `TabConfigurationProvider` から controller を全 WebView に接続
- 最初の navigation 前に controller が存在することを integration test

### Phase 2: adapters と lifecycle

- logical normal/private window adapters
- stable tab adapter registry
- open/close/focus/activate/change/move event wiring
- Dark Reader 対象 navigation の background-readiness preflight と一度だけの policy 再評価
- tab create/update/reload/close と permission visibility の integration test

### Phase 3: navigation surfaces と UI

- extension URL router と surface history
- action popup、options、settings UI
- permission prompt と private toggle
- strictblock redirect を含む境界 navigation test

### Phase 4: installer と transactions

- bundled ZIP verification
- registry、permission round-trip、startup restore
- install/enable/disable/cold-start update/rollback/uninstall/data purge と、同一プロセスでの
  identity 再 load 拒否
- crash journal recovery test

### Phase 5: package acceptance

- Floorp 派生 Dark Reader package の background/content/action/storage/readback/close test
- host preflight 経由の35秒 idle / terminate-relaunch cold-wake test
- iOS 18.6+ で公式 uBOL Safari package の DNR/action/options/strictblock test
- context runtime errors と性能を記録

### Phase 6: cutover と全面削除

- 全呼び出し元を native host へ切替
- 旧 source、tests、fixtures、pbxproj entries、prefs、docs を削除
- one-time legacy cleanup を有効化
- legacy symbol/file absence gate を CI に追加

### Phase 7: release validation

- clean install、upgrade、profile restore、normal/private、multi-window を実機確認
- memory pressure / background / foreground / process termination を確認
- App Review、license、privacy disclosure、package provenance の承認

## 16. Test strategy

### 16.1 unit

- registry の atomic commit、journal recovery、path validation
- digest/source validation
- permission と expiration の serialize/restore
- context の load/private-access state machine
- adapter identity と logical window filtering
- surface history の push/replace/back/forward

### 16.2 WebKit integration

- ZIP から `WKWebExtension` が生成されること
- invalid archive/manifest/DNR error が install failure になること
- controller が最初の navigation 前に全 WebView へ接続されること
- background、content script、runtime messaging、storage、action
- tab/window lifecycle と activeTab user gesture
- normal/private の cookie、website data store、UCC の分離
- private tab から開いた action popup/extension page が元 tab と同一の
  nonpersistent data store を使い、WebKit の persistent native popup を生成しないこと
- popup の `window.close()`、再表示、元 tab の遷移／終了／選択解除、scene focus 移動、
  disable/private 許可取消/uninstall で WebView と user gesture が残らないこと
- private access OFF で private tab/window/cookie が context から不可視になること
- extension-owned storage が profile 内で一貫し、private website data store と混同されないこと
- extension URL 境界を双方向に移動できること
- cold-start update rollback、uninstall data removal、update/reinstall の再起動要求

### 16.3 DNR / uBOL

Floorp 独自の static 50,000 rule limit は廃止し、数を変換・分割せず WebKit に渡す。
WebKit source の現行定数では static ruleset 100個、同時 enabled 50個、
dynamic+session 合計30,000件である。さらに WebKit の content-extension parser は現在、
1個の compiled content rule list を150,000 rulesに制限する。50,000は2020年以前の
旧上限であり、現在の上限ではない。ただし150,000も public API の安定契約ではないため、
Floorp に hardcode しない。

2026-09-02 時点の公式 uBOL Safari package は既定で `ublock-filters`、`easylist`、
`easyprivacy` を有効にし、fixture 上の rule 数は合計 113,100 件である。iOS 26.5
Simulator / WebKit 8624.2.5.10.4 で次を確認した。

- 3 ruleset の単独3通り、全ペア3通り、全件1通りがすべて compile / enable 成功
- 全件 113,100 rules の compile / enable は約4.6秒
- EasyList の実ルール `.ashx?adid=` に一致する script request が遮断され、control
  request は通過
- enabled context の復元後に browsing WebView を作る Floorp の起動順序でも遮断成功
- singleton failure が生じた場合に30,000 rules以下の dynamic chunkへ変換して再帰的に
  二分探索する opt-in 診断を追加。今回の結果では二分探索は不要
- `jpn-1` の1,906件を追加した合計115,006件でも compile / enable 成功
- EasyList の low generic `#Ad-Container` と high generic `[data-ad-name]`、日本語 list の
  low generic `.__isboostReturnAd` と high generic `div[id^="JP_"][style]` を通常・
  プライベート両方で非表示にできた
- custom CSS、procedural filter、stock scriptlet を通常・プライベート両方で確認
- dynamic rule と session rule を追加し、通常・プライベート両方の通信を遮断できた
- 日本語 ruleset 追加時に uBOL 自身が regex 上限保護のため session rules をいったん
  clear する公式挙動を確認。その後 session rule を再追加し、再び遮断できることを確認
- filtering level 3、日本語 ruleset、custom filters、private access、登録 content scripts が
  background suspension/wake 後も復元された
- `WKWebView.callAsyncJavaScript` と navigation に期限を設け、初回 DNR compile 中に
  WebKit が extension page を入れ替えた場合は新しい制御 page で background readiness を
  再確認する。callback 消失を無期限待機や合格として扱わない

診断は `FLOORP_RUN_UBOL_DNR_DIAGNOSTICS=1` の時だけ実行し、JSON report を test
attachment とログへ出力する。診断用 controller を non-persistent data store で作ると、
ruleset の compile 成功後も通信遮断が適用されない偽陰性になった。本番 host と同じ
`WKWebsiteDataStore.default()` を controller の default store として使う必要がある。
これは private tab の WebView を non-persistent にする要件とは別であり、private tab は
persistent profile controller に接続したまま個別の non-persistent store を使う。

過去に観測した `[API] Failed to request resource monitor url rules ... UpdateFailed` は、
直後の `[ResourceMonitoring] ... WebPrivacy` が示すとおり WebPrivacy Resource Monitoring
の失敗である。`declarativeNetRequest.updateEnabledRulesets()` の成否、context errors、
実通信の遮断結果と分離して判定する。

uBOL acceptance は少なくとも次を end-to-end で確認する。

- 51 static ruleset の parse と既定 ruleset の enable
- block / allow / redirect / allowAllRequests
- dynamic/session rule update、normal/private tab への適用、private access gate
- 公式 Safari build が WebKit bug 298199 のため strict-block rules を生成しないことを
  明示的な既知制約として検出。upstream が再有効化した版では `strictblock.html` への
  local redirect と通常 URL への復帰を必須に戻す
- action popup、options/dashboard、filtering mode change
- app restart 後の extension state と、private website data の非永続性
- unsupported rule/API が silent no-op にならず error/feature detection になること

### 16.4 performance

- controller/context startup time
- uBOL rule load 完了時間
- normal/private 両方の tab を開いた時の memory
- action popup first-open latency
- update と uninstall purge time

性能 gate は実機で採取し、旧 custom DNR compiler の数値とは比較しない。

## 17. Definition of Done

次を全て満たした時だけ置換完了とする。

1. Floorp app と first-party test target の minimum OS が 18.4
2. 全 normal/private WebView に、作成時点から同じ profile controller が接続される
3. WebExtension API、DNR、storage、background の Floorp 独自 JS 実装が存在しない
4. 旧 runtime と native controller が同時実行される経路がない
5. normal/private の website data store、UCC、logical window が分離される
6. extension URL への移動と復帰が同じ Floorp Tab identity で動く
7. permission、private toggle、action、options、install/update/uninstall が動き、update と
   uninstall 後の reinstall は同一プロセスで identity を再 load せず再起動を要求する
8. Dark Reader acceptance が通る
9. iOS 18.6+ で uBOL acceptance が通る
10. 旧 source、tests、fixtures、feature flags、prefs、永続領域が削除される
11. `WKWebExtensionContext.errors` を settings と diagnostics で確認できる
12. clean install、upgrade、multi-window、private、restart の実機試験が通る

CI では少なくとも次の旧 symbol が0件であることを検査する。

```text
FloorpWebExtensionAPIHost
FloorpWebExtensionMessageRuntime
FloorpWebExtensionDNRCompiler
FloorpWebExtensionRuntime
prepareFloorpWebExtensionPolicy
FloorpWebContentPolicyCoordinator
```

## 18. リリース前に残る製品判断

技術設計としての推奨値は次で固定する。

| 判断 | 推奨 |
| --- | --- |
| app minimum OS | iOS 18.4 |
| uBOL minimum OS | package 宣言どおり iOS 18.6 |
| legacy fallback | なし |
| arbitrary ZIP import | v1 では無効 |
| remote catalog | v1 では未提供 |
| Dark Reader default install | なし、catalog から明示 install |
| native messaging | 無効 |

uBOL の GPL code 同梱は、Floorp の該当 release source を公開し、版、上流／派生 digest、
互換 patch、再現 build script、license、対応 source を App Review notes へ明記する。GPL を
技術的 release blocker にはしない。提出時は
`docs/app-review-notes-native-webextensions.md` の placeholder を公開済み release commit
へ置き換え、Apple の審査結果を外部 release gate とする。両拡張は Floorp 派生資産で
あること、各 patch と再現 build script、上流と派生の両 digest、license、上流 source
revision を同じ notes に明記し、無変更の upstream asset とは表現しない。
また、idle 後の background wake を host navigation preflight の `loadBackgroundContent` で同期し、
Dark Reader は毎 navigation を3秒 fail-open、uBO Lite は context ごとの通常／private 初回を
90秒 fail-closed（15秒以内の probe 単位で再試行）として成功後に cache することを
review notes と試験手順に明記する。
Dark Reader と uBOL はそれぞれの license notice と provenance JSON も ZIP とは別の
app bundle resource として同梱する。

## 19. 根拠資料

- [WebKit Features in Safari 18.4](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/)
- [`WKWebExtension` public header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebExtension.h)
- [`WKWebExtensionContext` public header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebExtensionContext.h)
- [`WKWebExtensionController` public header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebExtensionController.h)
- [`WKWebExtensionControllerDelegate` public header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebExtensionControllerDelegate.h)
- [WebKit WebExtension limits](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Shared/Extensions/WebExtensionConstants.h)
- [WebKit content rule parser の現行150,000件上限](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionParser.cpp)
- [WebKit の50,000件から150,000件への変更](https://github.com/WebKit/WebKit/commit/d069434deaa0)
- [uBOL Safari manifest](https://github.com/gorhill/uBlock/blob/master/platform/mv3/safari/manifest.json)
- [uBOL Safari compatibility layer](https://github.com/gorhill/uBlock/blob/master/platform/mv3/safari/ext-compat.js)
- [uBOL Lite 2026.825.1619 release](https://github.com/uBlockOrigin/uBOL-home/releases/tag/2026.825.1619)
- [WebKit bug 317981: initial background load 中の message drop](https://bugs.webkit.org/show_bug.cgi?id=317981)
- [WebKit bug 277588: iOS Service Worker と background scripts workaround](https://bugs.webkit.org/show_bug.cgi?id=277588)
- [WebKit bug 298199](https://bugs.webkit.org/show_bug.cgi?id=298199)
- [Floorp native WebExtensions App Review notes](app-review-notes-native-webextensions.md)
