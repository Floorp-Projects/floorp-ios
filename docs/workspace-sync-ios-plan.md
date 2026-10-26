# Desktop ワークスペースの iOS 受信・コピー計画

作成日: 2026-10-26 JST。改訂日: 2026-10-26 JST。状態: 初回範囲を実装中。ソース実装と公開受け入れの進捗は `workspace-discovery-architecture.md` を参照。

初回公開は、Desktop が Firefox Sync に公開したワークスペースの一覧・読み取り専用プレビューと、選択したページを独立した iOS のタブとしてコピーして開く機能に限定する。クラウド側の変更は一覧・プレビューだけに反映し、作成済みのコピーへ継続適用しない。

双方向同期は後続フェーズとする。初回公開の完了条件に、iOS のローカルワークスペース管理、既存タブの所属移行、ライブタブの遠隔更新・削除、Workspace BSO の書き込みを含めない。後続の仕様判断や Desktop 側の変更が未完了でも、受信・コピー機能は独立して一般公開できる。

## 決定した初回公開の製品仕様

| 操作・出来事 | 初回公開での動作 |
| --- | --- |
| 共有ワークスペースを見る | 同じ Mozilla Account の Desktop が公開した名前・アイコン・タブ一覧を表示する |
| ワークスペースをプレビューする | URL・タイトル・ピン状態・順序を表示する。Web ページ自体を読み込まない |
| ページを開く | 1 件・選択した複数・全件を、操作元の通常ウィンドウへ独立したコピーとして作成する |
| iOS でコピーを閲覧・並べ替え・閉じる | iOS の通常タブとして扱う。Workspace BSO の変更・削除を生成しない |
| Desktop が URL・タイトル・順序を変更する | 受信一覧・プレビューを更新する。既存のコピーを変更しない |
| Desktop がタブやワークスペースを削除する | 受信キャッシュと一覧に反映する。既存のコピーを閉じない |
| 受信機能を停止する・ログアウトする | 受信処理と未完了のコピー処理を停止する。作成・保存済みのコピーは残す |
| 共有内容を iOS から編集する | 初回公開の対象外。双方向同期とともに後続で設計する |

「独立したコピー」はワークスペースの共有状態と連動しないという意味である。通常の Firefox タブ同期が有効なら、コピーした通常タブの URL は既存の「他の端末のタブ」に送信され得る。「ローカル限定」「端末外に送信しない」という説明は使わない。

既存の通常タブを「ローカル」ワークスペースへ移行しない。iOS のワークスペース作成・切り替え・所属・名前変更・削除 UI は初回公開の前提から外す。Private Browsing のタブは取得元・コピー先に含めない。

## 対象リビジョンと既存実装

| 対象 | 調査基準 | 意味 |
| --- | --- | --- |
| Floorp Desktop | `a218c5b9751dbfb6882721a51f916f15c5c5e99e` | `floorp-workspaces` v1 と、その後の停止・再開およびナビゲーション競合修正を含む |
| Floorp iOS | `d8ecf7aad2a972448176eb24c004a8d5611d33f2` | Notes Sync はあるが、ワークスペースのモデル・タブ所属・同期エンジンはない |
| Application Services | `e1c77eb6e333ef667456504100c7b09763b8ad35` | 現行 Floorp iOS 用 `.5` の基準。新エンジンの追加元とする |

Desktop の初回実装は [PR #2938](https://github.com/Floorp-Projects/Floorp/pull/2938)。[PR #2946](https://github.com/Floorp-Projects/Floorp/pull/2946) と [PR #2979](https://github.com/Floorp-Projects/Floorp/pull/2979) の修正を含む上記リビジョンを移植基準とする。v12.20.2 には初回実装が含まれないため、相互運用試験にはワークスペース同期を搭載したデスクトップビルドを使う。

iOS の Notes は Gecko の `prefs` レコードを利用する。今回の受信機能は独立した `floorp-workspaces` エンジンを使い、Notes 用レコードや既存の「他の端末のタブ」にワークスペースデータを追加しない。認証・暗号化・通信・既存 Sync の実行経路は Application Services を利用する。

## 初回公開の一覧・プレビューとコピー UX

### 一覧・プレビュー

- iPhone はタブトレイ内の「共有ワークスペース」から専用画面を開く。iPad もタブ UI の入口から同じ画面を開く。`TabTrayPanelType` の `.tabs / .privateTabs / .syncedTabs` は維持する。
- 名前・アイコン・タブ件数と最終受信時刻を表示し、プレビューにはタイトル・URL・ピン状態を表示する。未知のアイコンは代替表示にし、キャッシュ中の元値を保持する。
- プレビューのために WKWebView を作成しない。閲覧履歴を追加せず、サイトへのプレビュー・favicon 取得通信も発生させない。アイコンは同梱素材や既存キャッシュを使う。
- タブ順序と同一 URL の別タブを保持する。URL による重複排除をしない。ワークスペース一覧自体の表示順と選択状態は端末内の状態とする。
- 状態は「取得中」「取得済み」「オフライン・前回受信分」「更新失敗」「対応外バージョン」「公開されたワークスペースなし」を区別する。取得失敗を空一覧として見せない。
- 起動・フォアグラウンド復帰・一覧表示時に、既存 Sync のスケジューラーと backoff に従って更新する。手動の再試行も設ける。バックグラウンドで常時最新になることは約束しない。
- キャッシュを使えるのは同じ profile・アカウントに限る。オフラインで前回の確認済みキャッシュからコピーする場合は、受信時刻と古い可能性を表示する。

### コピーして開く

- コピー開始時に、ユーザーが見て選択した受信 snapshot を固定する。操作中のクラウド更新によって対象 URL・件数・順序を差し替えない。
- 各コピーには新しいローカル tab UUID を発行する。クラウドの tab/workspace UUID を通常タブの同期 ID として保存せず、継続適用の対応関係を作らない。保存する来歴情報がある場合も、後続同期への自動参加には使わない。
- URL とタイトルは作成時の初期値として使う。ピン状態はプレビューで示し、コピー先では既存 iOS タブの仕様に従う。新しいピン機能や所属モデルの追加を必須にしない。
- 選択順序はプレビューのタブ順序に従う。同一 URL の別 ID は別タブとして作成する。ユーザーが再度「開く」を実行した場合は、新しいコピーの作成として扱う。
- 複数コピーは未ロード状態で保存し、選択されたタブだけを読み込む。最初のコピーを選択し、それ以外はバックグラウンドに保持する。件数を示してから実行し、大量コピーの進捗と部分失敗を表示する。
- コピー先は操作元の通常ウィンドウに固定する。Private のタブトレイには入口を置かず、Private へ挿入しない。コピー中に対象 scene が失われた場合、別 window に黙って追加せず処理を保留する。
- 同じ操作の二重タップ・再試行・クラッシュ復旧では重複作成しない。永続化した操作 ID、対象 snapshot、予定したローカル tab UUID、各タブの保存結果を使って、同じ操作の未完了部分だけを再開する。
- 現行の保存 API は永続化成功を保証する戻り値として扱わない。コピーの完了を表示する前に、通常タブの保存成功と操作記録の整合を確認できる API を用意する。結果不明時は自動で再追加せず、在庫・保存結果を確認してから再試行する。
- コピー成功後にユーザーが閉じたタブを、コピー処理の復旧で再作成しない。ログアウト・アカウント変更・機能停止時は未完了の旧世代処理を取り消し、既に保存されたタブは残す。

Cookie、ログイン状態、履歴、フォーム、ページの完全なセッション状態、コンテナー、タブスタックの構造はコピーしない。コピー先でログイン画面やモバイル向け URL に転送されても、Desktop の共有内容には反映されない。

## Desktop v1 から受け入れる契約

詳細な正本は [Desktop ADR](https://github.com/Floorp-Projects/Floorp/blob/a218c5b9751dbfb6882721a51f916f15c5c5e99e/docs/development/workspace-sync/ADR-001-workspace-tab-sync.md)。初回公開はこの契約の受信・表示に必要な部分を実装し、ローカル編集の capture・時計の採番・outbox は追加しない。

| 項目 | 初回公開の受信条件 |
| --- | --- |
| エンジンとコレクション | `floorp-workspaces`、対応 engine version は `1`。標準の Sync collection keys と `meta/global` を使用 |
| レコード | ワークスペースのメタデータ 1 件と、各タブ 1 件の BSO |
| 暗号化前の形式 | 生存レコードは `{id, entity: ...}`。削除は標準の `{id, deleted: true}` |
| ID | ワークスペースとタブは別の UUID。受信値の大文字・小文字を保持し、既存 tab ID の所属変更と不正な ID 衝突を拒否する |
| 更新の競合 | メタデータと各タブを独立して比較する。`modifiedAt`、`modifiedBy`、同値時の正規化済み JSON の順に比較 |
| 時計 | `modifiedAt` は JS の非負 safe integer。受信値を検証する。コピーによる時計更新は行わない |
| 削除 | 同じ ID では削除が生存更新に優先する。受信した削除の証跡を保持し、古いレコードで受信キャッシュを復活させない |
| 親の削除 | キャッシュ上の親と子の表示を取り下げ、後着の子で復活させない。独立した通常タブのコピーには作用させない |
| 到着順 | タブが親より先に届いても一時保存する。親の初回メタデータは時計 0 でも採用する |
| URL | 資格情報を含まない HTTP(S) のみ。Private・内部ページ・ファイル・拡張ページは対象外 |
| 文字とサイズ | name/icon は各 256 UTF-16 code units、title は 1024、URL は 8192。正規化した entity は 16 KiB UTF-8 以下 |
| 重複 URL | 別 ID のタブとして保持し、URL による重複排除をしない |

同じ時計・device ID の競合で比較する JSON は wire entity 全体ではない。メタデータは `{modifiedAt, modifiedBy, name, icon}`、タブは `{id, url, title, pinned, position, deleted, modifiedAt, modifiedBy}` の順で `JSON.stringify` した値を、JS の UTF-16 code-unit の比較で評価する。

Swift の `String.count` や UUID の再文字列化、一般的なソート済み JSON や UTF-8 のバイト比較をそのまま使わない。JS の文字列比較、JSON エスケープ、UTF-16 長、WHATWG URL 判定との差を共通 fixture で検証する。Desktop の `.localeCompare` に依存する同順位 ID の並びも対象 OS・ロケールを含めて確認する。相違を見つけた場合は、対応範囲を明示し、必要な比較規約の修正を Desktop と共有する。

### engine version と同期世代

`DEFAULT_ENGINES` に version `1` を登録するだけでは、対応外のリモート engine version を拒否できない。対象の `LocalCollStateMachine` に任せず、サーバーから取得した補完前の `meta/global` の engine version を reset・受信・適用より前に検証する。version `1` 以外なら当該 collection の処理を停止し、更新が必要な状態を表示する。engine 定義がない場合は「未公開」とし、取得失敗や空の workspace entity と区別する。初回公開の iOS は、不在の Workspace engine 定義や syncID を生成せず、Desktop による公開を待つ。

処理とキャッシュの所有者は profile、FxA account UID、feature epoch、global syncID、collection syncID、engine version、ローカルの台帳 revision で識別する。同じアカウントでも syncID が変われば旧 run を無効化する。旧 cursor・staging・受信削除の証跡を新しい collection 世代へそのまま流用せず、再取得する。対応外 engine version や engine 定義の消失を確認した場合も旧 run と未完了コピー操作を無効化し、旧キャッシュからの新規コピーを停止する。ブラウザー内に作成済みのコピーは保持する。

## 初回公開の実装分担

| 層 | 責務 | 主な追加・変更候補 |
| --- | --- | --- |
| Rust の受信モデル | wire 検証、正規化、受信マージ、親子関係、受信削除の証跡 | 新規 `components/floorp-workspaces-sync` の model/record 部分 |
| Rust の受信エンジン | `sync15`、受信キャッシュ、paging、cursor、再試行、version/association 境界 | 同 crate の store/engine、`sync_manager` の登録、UniFFI |
| Swift の受信調停 | アカウント・世代管理、snapshot と状態通知、main actor での画面更新 | 新規 `FloorpWorkspaceDiscoveryCoordinator` 等。名称は実装時に確定 |
| Swift のコピー処理 | 固定 snapshot から通常タブを作成、操作記録、保存結果の確認、再試行 | 新規 `FloorpWorkspaceCopyService` 等と既存 TabManager/TabDataStore |
| UI | 一覧、読み取り専用プレビュー、対象選択、コピー進捗、エラー・再試行 | 専用画面とタブ UI の入口 |

受信キャッシュはアカウントに属し、作成済みの通常タブとは寿命を分ける。ログアウト時は旧キャッシュと操作元のアカウント情報を画面から直ちに除去し、永続領域のキャッシュ・cursor・staging・未完了操作の元データも削除する。削除途中の再起動でも旧データを利用できない無効化状態を永続化し、次のアカウントに引き継がない。作成済みの通常タブと、再試行による重複を防ぐために必要なアカウント情報を含まない完了・取消記録は残す。

キャッシュと cursor は同じ commit 境界で永続化する。コピー操作記録と通常タブ保存は、クラッシュ後に成功・未完了・結果不明を判定できる境界を定義する。初回公開で必要な最小限の保存 API・操作記録は追加するが、全通常タブへのワークスペース所属やクラウド ID の移行は行わない。

### Application Services と Swift の変更箇所

- `components/sync15/src/engine/sync_engine.rs` の固定 `SyncEngineId` と名前解決に新エンジンを追加する。
- `components/sync15/src/client/state.rs` 等に対応 collection/version の判定と事前検証経路を追加する。`DEFAULT_ENGINES` からの共通補完をそのまま使わず、受信専用 Workspace はリモート定義がないときの自動作成対象から除外する。既存の unknown engine と declined settings を維持する。
- 初回公開の「読み取り専用」は Workspace BSO に対するものとする。Workspace の live BSO・tombstone・collection wipe は一切送らず、outbox も持たない。共通 Sync が必要とする認証・鍵・`meta/global` の初期化は通常経路で扱い、その制御情報の書き込みまでゼロであるとは説明しない。
- 共通 Sync の初期化で `meta/global` を補完する場合も、不在の Workspace 定義を追加しない。既存 engine version を下げず、他 engine や declined settings を維持する。受信機能の停止をサーバー側の engine 無効化・collection 削除へ変換しない。
- `components/sync_manager` に crate dependency と registry を追加する。登録対象を強参照し、Weak registry の登録だけで寿命を失わないようにする。
- `enabled_changes` の true/false は Notes と同様に拒否し、汎用 `All` と available/togglable engine 一覧から除外する。端末内 policy と実行ごとの明示的な engine 選択で受信を制御する。
- エンジンの `apply` 等が返す outgoing は常に空とし、Workspace に対する POST・batch commit・DELETE が発生しないことを transport mock で検証する。共通 Sync の engine reset と、ブラウザーの通常タブ削除を結び付けない。
- `megazords/ios-rust` から型と UniFFI metadata を公開し、header/modulemap/generated Swift 生成経路へ追加する。Focus へ機能を追加する必要はない。
- `RustSyncManager.swift` の Notes 専用 engine partition、実行前の準備、結果採用、再試行、account removal を複数 Floorp provider に対応させる。Notes と Workspace 受信の ON/OFF 全 4 通りを試験する。
- 同一ソース由来の XCFramework・Swift bindings・manifest・checksums を生成し、`MozillaRustComponents/Package.swift` と `FloorpApplicationServicesPin.json` をまとめて更新する。
- 現 `.5` の source/tag/artifact hashes に依存する `FloorpNotesSyncReleaseGate` を新バイナリで再検証する。`automation/floorp/verify-ios-xcframework-release.py` に新 engine の symbol/header/generated Swift とリンクの smoke 検証を追加する。

### 初回公開に必要な受信 transport

現行 `sync15/src/client/sync.rs` は incoming を 1 request で取得し、paging は TODO としている。多数の BSO を扱う本機能では、完全な受信を初回公開の前提とする。

- `X-Weave-Next-Offset`、一貫した取得境界、412 と再取得を扱い、全 incoming と backfill の完了を確認する。
- 受信結果は staging へ保存し、完全性と世代を確認してから表示用 snapshot と cursor を確定する。途中までの結果で前回の確認済みキャッシュを置き換えない。
- 不完全な取得、復号・検証失敗、将来 entity version は失敗として保持する。影響範囲が分かる場合は対象 workspace を隔離し、分からない場合は更新未完了として前回 snapshot を保持する。初回取得で確認済み snapshot がなければエラーと再試行を表示する。
- キャッシュ上の削除を表示へ反映しても、通常タブを閉じたりナビゲーションしたりしない。受信キャッシュからブラウザーのタブ在庫への差分適用経路を作らない。
- 停止・account switch・syncID 変更は、旧 run のキャッシュ commit・UI 通知・未完了コピー操作を無効化する。初回公開では Workspace outgoing が存在しないため、送信 batch の admission/部分 ack 改修は後続へ分離する。
- 共通 transport の変更は独立 PR とし、Notes と標準エンジンの回帰試験を行う。

## 初回公開までの PR 単位の実装順

| 段階 | 内容 | 完了条件 |
| --- | --- | --- |
| 1 受信・コピーの設計と fixture | 本仕様を ADR 化。Desktop の model/wire fixture、version 判定、同期世代、cache/cursor とコピー保存の境界を確定 | 一覧・プレビュー・独立コピーの状態遷移と、通常タブ同期との説明が固定されている |
| 2 Rust 受信モデル | v1 parser、受信マージ、親子関係、受信削除の証跡を実装 | fixture 一致、Unicode・サイズ・ID・到着順・重複 URL の境界試験に合格 |
| 3 受信 transport と配布物 | paging、version preflight、association reset、engine/registry/UniFFI と XCFramework を追加 | 完全受信と世代分離が成立し、Workspace BSO の送信・削除がゼロ。Notes と通常 Sync の回帰なし |
| 4 一覧・プレビューと独立コピー | 専用画面、状態表示、通常タブへの未ロードコピー、操作記録、保存 API と部分失敗の回復を実装 | 既存タブの移行不要。再起動・二重タップ・scene 破棄・account switch で重複や誤適用がない |
| 5 初回公開の受け入れと配布 | 英日 UI、VoiceOver、大量タブ、実機 Desktop→iPhone/iPad、署名候補で検証 | 下記の初回公開検証に合格し、source SHA・Rust pin・TestFlight build に結果を結び付ける |

段階 2 と段階 4 の UI・コピー処理は、段階 1 の後に fixture/mock を使って並行できる。段階 3 の完了後に実受信を結合する。段階 1〜5 を初回公開のゲートとし、後続の双方向同期の実装・検証は条件に含めない。

## 初回公開の必須検証

| 層 | 重点ケース |
| --- | --- |
| wire/表示 | 同じ時計の競合、ID の大小文字・衝突・所属変更、親子の任意到着順、親削除、Unicode・URL・16 KiB 境界、同一 URL の別 ID、未知のアイコン |
| 受信 storage | 全ページ取得、途中失敗・412、cache/cursor の一体 commit、破損・将来 schema、オフライン、account A→B、同一アカウントでの global/collection syncID 変更 |
| version/送信禁止 | engine version 0/1/2・欠落、欠落時に Workspace 定義を自動作成しない、entity version 不一致、対応外 version・定義消失で旧キャッシュからのコピーも停止、Workspace BSO の POST・commit・DELETE がゼロ |
| コピー | 1 件・選択・全件、順序・重複 URL、未ロード保存、意図的な再コピーと同一操作の再試行の区別、保存失敗・部分成功・クラッシュ、成功後に閉じたタブを復活させない |
| ライフサイクル | コピー中のリモート変更、ログアウト・機能停止・account switch、対象 scene の消失、背景化・強制終了、旧世代の commit/UI 通知拒否 |
| 通常タブとの分離 | 受信更新・削除・reset・キャッシュ破棄で既存コピーを変更しない、ログイン・モバイル転送で Desktop を書き換えない、通常タブ同期・Private・既存復元の回帰なし |
| UX/性能 | プレビューでサイト通信・履歴追加がない、受信失敗と空一覧の区別、最終受信時刻、VoiceOver、メモリー・時間を計測した大量一覧・コピー |
| 実サービス | 標準暗号化・collection key・`meta/global`、Desktop→iPhone と Desktop→iPad、コピー後の Desktop 編集・削除でもコピーが残る、両端再起動 |

認証不要の fixture/transport mock と専用アカウントの本番サービス相互運用試験を分ける。既存 Desktop の認証済み結果を iOS の成功証跡として扱わない。feature gate の無効化でも作成済みの通常タブを残す。初回公開のユーザー向け名称・説明に、未実装の双方向同期を含めない。

## 後続フェーズ: ローカルワークスペースと双方向同期

以下は初回公開から分離した設計・実装候補であり、有効化を約束する仕様ではない。Desktop v1 の制約と利用者の作業保護を両立する ADR を先に確定し、必要な Desktop 側の変更と対応ビルドを揃えてから実装する。初回の独立コピーを、自動的に双方向同期へ昇格させない。

### 双方向同期の前に確定・解決する事項

1. **端末内の操作と共有状態の操作。** 「この端末で閉じる」「共有状態から削除する」「同期を解除する」を区別する。全閉じるが他端末にも及ぶ場合は操作名と購読開始時に範囲を明示する。閲覧中・入力中のタブへの遠隔 URL 変更・削除は保留通知または独立コピーへの退避を設計する。フォーム等を同期しないことは、作業内容を失ってよい理由にはしない。
2. **親削除と子削除の別 commit。** 全ダウンロード完了待ちだけでは、「子 tombstone は commit 成功、親 tombstone は失敗」の送信状態を判別できない。子を閉じた後で親削除が届くケースも含め、Desktop と親削除の先行 commit・子の後続掃除などの送信規約を確定する。旧 Desktop 送信側も考慮し、受信削除前のローカル内容を復元領域へ保存する。保証できる範囲と復元方法を明記し、この問題を iOS の paging だけで解決済みとしない。
3. **目的 URL と表示 URL。** 受信した同期上の目的 URL と、端末で解決した表示 URL を分ける。受信適用に伴うログイン転送、モバイル転送、タイトル変更、`pushState` を新しいローカル編集として送らない。遷移完了待ちだけでなく、明示的なローカルナビゲーションの開始を識別する。PC ログイン済み／iOS 未ログインや www/mobile 転送を受け入れ試験に含める。
4. **競合の粒度。** v1 はメタデータと各タブを独立マージするが、タブ内の URL・タイトル・ピン・順序は同じ時計で比較される。PC のピン・順序変更と iPhone の URL 変更が競合すると片方を失い得る。受容する動作と復元手段を明記するか、フィールドごとの時計等を Desktop と共通の新契約として設計する。iOS だけで変更しない。
5. **停止・再開とコピーからの購読。** 「双方向→停止→双方向」で停止中の編集を送るのか、クラウドを採用するのか、別コピーに残すのかを確定する。停止中の古い編集を再開時刻で新規更新として扱い、他端末の変更を黙って上書きしない。独立コピー・readOnly→twoWay は再取得と baseline 確立から開始し、既存コピーや URL 一致による自動統合を行わない。別アカウントへの購読は明示操作を必要とする。
6. **復元と保存の信頼性。** 正常な空、未復元、欠損、破損、部分復元を区別する load 結果と、永続化成功を返す API を用意する。既存の `nil` や `tabRestoreHasFinished` だけで完全な在庫とみなさない。保存済みの在庫世代を確認できない範囲では capture と削除生成を抑止する。初回コピー用の保存確認だけで、全 window の在庫確認まで解決したと扱わない。
7. **複数 window のタブ所有権。** workspace 定義は profile 共通、選択 workspace と選択タブは window ごととする案を検討する。同じ workspace を 2 つの iPad scene で開く場合、同期 tab ID の実体を端末内で 1 つにするか、複数実体にするかを決める。初版の候補は 1 ID につき 1 実体とし、別 window からの選択は所有 window へ誘導する。scene 破棄・window 間移動を共有タブの削除と誤認しない。
8. **エラーの解決経路。** 壊れた 1 レコードのために削除確定が保留され続ける場合、影響範囲と状態を表示する。「再試行」「ローカルコピーを残して購読解除」「再取り込み」を設け、ログアウト以外の回復方法を用意する。

### 後続でも維持する v1 契約とタブ統合条件

- 新規 workspace/tab UUID は小文字で生成する。別 workspace への移動と閉じたタブの明示的な再オープンでは新 ID とし、通常のセッション復元では生存 ID を維持する。retired ID は復活させない。Undo は必要に応じて新 ID の独立した復元として扱う。
- ローカル編集の時計は `max(現在時刻, ワークスペース内の観測済み最大時計 + 1)` とし、JS の非負 safe integer を守る。上限到達時の停止・復旧方針も確定する。
- 同じ ID の削除は全生存更新に優先する。tombstone は送信成功まで保持し、retired ID はアカウントと collection 世代に結び付ける。親削除後に保持した内容を再公開する場合は、新 workspace UUID と新 tab ID を割り当てる。
- 同期済みタブが未対応ページへ移動したら、最後の同期可能な URL・タイトル・ピン・ID を保持する。ローカルページの情報を送信せず、受信更新で強制遷移させない。
- `normalTabs` は全通常タブを返す既存契約を維持し、workspace の表示範囲は別 API にする。通常の「他の端末のタブ」は独立した設定であることを説明する。
- 一覧 index を全タブ index として使わず、選択・並べ替え・閉じるを tab ID と workspace で指定する。タブトレイ・iPad タブバー・アドレスバースワイプ・キーボード操作の表示範囲を揃える。
- タブ所属と同期 ID を必要な TabData/WindowData・旧復元経路へ保存し、移行を試験する。背景 window・未接続 scene・未ロードタブを「存在しない」と判定しない。close-by-URL と Workspace の close-by-ID を分離する。
- 適用前 baseline と pending apply を永続化し、適用できなかったリモート追加をローカル削除と誤認しない。通信中のローカル編集を incoming マージ前に取り込み、遅い遷移・204・失敗・Back・同一文書遷移・scene 破棄を区別する。
- 端末内の `readOnly / twoWay / excluded` 等を明確に分ける。readOnly と独立コピーは outbox・ローカル時計更新・ユーザー操作由来の retirement を生成しない。

### 後続の送信 transport と世代管理

現行 `sync15/src/client/sync.rs` には、先行 upload batch の commit 成功後に後続 batch が失敗すると、先行成功 ID を engine へ渡せない問題が記されている。書き込み有効化前に、batch ごとの ack API または結果不明の操作を保持して再取得・再マージする回復方式を実装する。未確認の tombstone を消さず、古い live payload を無条件に再送しない。

account/feature epoch に加え、global/collection syncID とローカル revision を run に結び付ける。reset 時の cursor、staging、pending apply、outbox、retired ID の扱いを定義し、旧世代の ack・UI 適用・送信を拒否する。対応外 engine version では reset・送信を開始しない。

各 collection POST と batch commit の直前に、epoch/association 検証と送信開始を同じ admission gate で直列化する。Swift の世代確認だけで Rust が保持する batch を止められると仮定しない。停止要求と停止完了を分け、開始済み request のサーバー commit は取り消せると保証しない。Workspace の停止で Notes・通常 Sync 全体を停止しない。共通改修には他エンジンの回帰試験を伴わせる。

### 後続フェーズの実装順と公開条件

| 段階 | 内容 | 完了条件 |
| --- | --- | --- |
| F1 共有編集の仕様と Desktop 契約 | 上記の操作・競合・停止再開・親削除・閲覧保護を ADR 化し、必要な両端変更を確定 | 未解決の保証を残したまま書き込みを有効にしない |
| F2 ローカル iOS ワークスペース | 所属・永続化・移行・表示範囲・複数 window と復元/保存 API を実装 | 完全な在庫を判定でき、既存タブ・Private・通常タブ同期を壊さない |
| F3 書き込み可能なモデルと transport | clock/capture/outbox、部分 ack、tombstone、送信 admission、reset 境界を追加 | 模擬環境で部分成功・旧世代処理・親子別 commit から安全に回復できる |
| F4 双方向のタブ適用 | baseline、pending apply、目的 URL と表示 URL、購読、close/delete/再開を実装 | 受信変更とユーザー操作を区別し、独立コピーを勝手に購読させない |
| F5 耐久・実機試験と配布判断 | オフライン競合、停止・再開、バックグラウンド、再試行、Desktop↔iPhone/iPad | 対応 Desktop ビルドと署名済み iOS 候補で、データ保護と回復手段を検証する |

後続の公開判断には、URL 変更対ピン・順序変更、close 対 reorder、親子削除の別 commit、停止中の両端編集、復元破損、保存失敗、同一アカウントの syncID reset、未ログイン・mobile 転送、入力中の遠隔変更、複数 scene の所有権、Undo Close を含める。検証に合格しても、初回の受信機能の利用者を自動的に双方向同期へ移行させない。

## 初回実装で確定した事項と公開までの残件

- 通常タブトレイの「共有ワークスペース」から専用一覧を開く。プレビューで複数選択・全件選択し、選択件数を確認してコピーする。
- Rust の確認済み cache/cursor は一括確定する。コピーは操作台帳の予定 UUID、通常タブと同時保存する receipt、台帳への保存確認の順で記録する。在庫不明時は停止し、未完了操作の明示取消後に在庫を再確認する。
- 補完前の remote metadata で version/association を検査する。コピー時も最新の受信可否を検査し、古い UI 通知からのコピーを許可しない。
- Desktop の固定リビジョンから生成した fixture で、JSON・文字列比較・URL の遷移先・並び順を照合する。
- 大量一覧・コピーの実測、VoiceOver、iPad、専用アカウントでの Desktop 相互運用、署名候補・新 Rust release/pin の固定は公開受け入れで確認する。認証不要の fixture 成功を実サービスの合格として扱わない。

一覧・プレビューと独立コピーに初回公開を限定することは決定済みとし、再度のスコープ判断事項にはしない。双方向同期の残件は F1 で解決する。

## 参照

- [Desktop v1 ADR](https://github.com/Floorp-Projects/Floorp/blob/a218c5b9751dbfb6882721a51f916f15c5c5e99e/docs/development/workspace-sync/ADR-001-workspace-tab-sync.md)
- [Desktop model/validation/merge](https://github.com/Floorp-Projects/Floorp/blob/a218c5b9751dbfb6882721a51f916f15c5c5e99e/browser-features/modules/common/workspace-sync.ts)
- [Desktop wire parser](https://github.com/Floorp-Projects/Floorp/blob/a218c5b9751dbfb6882721a51f916f15c5c5e99e/browser-features/modules/common/workspace-sync-record.ts)
- [Desktop native engine](https://github.com/Floorp-Projects/Floorp/blob/a218c5b9751dbfb6882721a51f916f15c5c5e99e/browser-features/modules/modules/workspaces/FloorpWorkspacesSync.sys.mts)
- [Desktop fixture/native/実機試験](https://github.com/Floorp-Projects/Floorp/blob/a218c5b9751dbfb6882721a51f916f15c5c5e99e/tools/workspace-sync/README.md)
- [iOS Notes Sync 設計](https://github.com/Floorp-Projects/floorp-ios/blob/d8ecf7aad2a972448176eb24c004a8d5611d33f2/docs/floorp-notes-sync-architecture.md)
- [iOS Notes Sync 実装](https://github.com/Floorp-Projects/floorp-ios/blob/d8ecf7aad2a972448176eb24c004a8d5611d33f2/firefox-ios/Floorp/FloorpNotesSync.swift)
- [iOS タブ管理](https://github.com/Floorp-Projects/floorp-ios/blob/d8ecf7aad2a972448176eb24c004a8d5611d33f2/firefox-ios/Client/TabManagement/TabManagerImplementation.swift)
- [iOS タブ永続化](https://github.com/Floorp-Projects/floorp-ios/blob/d8ecf7aad2a972448176eb24c004a8d5611d33f2/BrowserKit/Sources/TabDataStore/TabData.swift)
- [iOS 既存タブ同期](https://github.com/Floorp-Projects/floorp-ios/blob/d8ecf7aad2a972448176eb24c004a8d5611d33f2/firefox-ios/Client/AccountSyncHandler.swift)
- [Rust engine ID と登録](https://github.com/Floorp-Projects/application-services/blob/e1c77eb6e333ef667456504100c7b09763b8ad35/components/sync15/src/engine/sync_engine.rs)
- [Rust meta/global engine 定義](https://github.com/Floorp-Projects/application-services/blob/e1c77eb6e333ef667456504100c7b09763b8ad35/components/sync15/src/client/state.rs)
- [Rust 同期と汎用停止処理](https://github.com/Floorp-Projects/application-services/blob/e1c77eb6e333ef667456504100c7b09763b8ad35/components/sync15/src/client/sync_multiple.rs)
- [Floorp XCFramework の出荷手順](https://github.com/Floorp-Projects/application-services/blob/e1c77eb6e333ef667456504100c7b09763b8ad35/automation/floorp/README.md)
- [Rust collection state と reset](https://github.com/Floorp-Projects/application-services/blob/e1c77eb6e333ef667456504100c7b09763b8ad35/components/sync15/src/client/coll_state.rs)
- [iOS タブ保存 API](https://github.com/Floorp-Projects/floorp-ios/blob/d8ecf7aad2a972448176eb24c004a8d5611d33f2/BrowserKit/Sources/TabDataStore/TabDataStore.swift)
