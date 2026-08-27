# Floorp iOS: 内部 WebExtensions カタログのパイロット候補

Status: **proposal — catalog への掲載・導入・外部配布を承認するものではない。**

この候補表は、`floorp-ios-webextensions-internal-catalog-design.md` の閉じた
Stage 3 / catalog-v1 境界に合わせて、最初に評価する拡張の形を選ぶためのものである。
候補はすべて Floorp が審査した固定 `FWEA1` artifact として作る。Chrome Web Store、任意の
URL、CRX/ZIP、共有シート、または upstream の自動更新から取り込む候補は含めない。

## 全候補に共通する掲載前ゲート

- 署名済み catalog record、対象アプリ、有効期限、sequence、artifact／manifest／inventory
  digest、immutable generation をすべて検証できること。
- remote JavaScript、WASM、DNR list、`update_url`、runtime code generation、任意 fetch を
  持たないこと。更新は利用者の明示的同意を伴う新 generation とする。
- 最小 host permission、normal/private profile ごとの同意、無効化・削除・失効時の
  storage/DNR 保持方針を package review で決めること。
- 第三者 package は確認済みの再配布ライセンス、local `LICENSE`/`NOTICE`、pinned
  provenance、candidate-time archive re-verification をそろえること。これを確認できない
  候補は除外する。upstream author の架空の別承認は要求しない。
- `managedRemoteSource` の P0 composition、production root key、endpoint allow-list が
  承認済みになるまでは、候補を公開版の remote catalog に載せないこと。

## 優先順位 A — Floorp 管理の小規模パイロット

| 候補 | 主な機能 | 使う互換プロファイル | なぜ最初に向くか | 明確な制約 |
| --- | --- | --- | --- | --- |
| **Floorp Site Appearance** | 許可サイトだけに固定 CSS と孤立 content script を適用し、文字幅・配色・余白を調整する。 | P2 content-script + P4 action-storage | 最小権限でサイト同意、private opt-in、disable、generation 更新を一通り実証できる。 | ネットワークなし、`all_frames` なし、ページ main world への注入なし。action は任意で、未宣言時の空状態も試験する。 |
| **Floorp Tracker Block Lite** | 成果物内に固定した小さな広告・追跡 block DNR corpus と、サイト単位の除外 UI。 | P3 DNR + P4 action-storage | DNR compiler、非対応 action の導入拒否、private 分離、失効時の rule 停止を測るのに適する。 | 最初は `block` だけ。`redirect`、header modification、`allowAllRequests`、リモート filter 購読を含めない。 |
| **Floorp Reading Highlights** | 許可サイト上の選択テキストをローカルに保存・再表示する孤立 content script。 | P2 content-script + P4 action-storage | `storage.local`、options、削除・更新時のデータ方針、アクセシビリティを実利用に近い形で試せる。 | 通信・同期なし。private は既定 off で、通常 profile とデータを共有しない。 |
| **Floorp Session Timer** | action popup、options、`storage.local`／`storage.session`、`alarms` による端末内タイマー。 | P4 action-storage | host permission を要さず、popup/options/alarms と action 未宣言の安全な空状態を独立して検証できる。 | ネットワーク・分析送信なし。alarm の wake/lifecycle 制約を超える機能を宣言しない。 |

推奨する最初の二本は **Floorp Site Appearance** と **Floorp Tracker Block Lite** である。
前者で P2/P4 のユーザー同意・profile 分離を、後者で P3 の DNR fail-closed を、互いに
依存しない小さな artifact として検証できる。

## 優先順位 B — upstream を出発点にできるが、そのままは載せない候補

| 候補 | 期待できる価値 | 掲載前に必須の作業 |
| --- | --- | --- |
| **Dark Reader を参考にした Floorp-managed appearance variant** | ダークテーマ／サイト別見た目調整の需要を検証できる。 | upstream manifest・互換な再配布ライセンス・notice・pinned provenance を確認し、広い host permission、remote asset、未対応 API を除いた Floorp 管理 artifact を別 generation として作る。upstream の成果物をそのまま取り込まない。 |
| **uBlock Origin を参考にした Floorp-managed blocker variant** | 広く理解されている広告・追跡防止の期待値を把握できる。 | 再配布ライセンス、source 公開義務、notice、pinned provenance を確認し、固定かつ小規模な block-only DNR corpus に限定する。完全な upstream 機能、filter subscription、scriptlet、redirect/header modification は対象外。 |

これらは「既存プロジェクトを無根拠に再配布する」候補ではない。調査・互換性比較・
license/notice/provenance 確認の出発点であり、その再配布根拠を確認できない限り
P2/P3 の実機パイロットにも使わない。

## 初期カタログから除外する類型

| 類型・例 | 除外する理由 |
| --- | --- |
| 任意コード実行／サイト隔離を大きく変えるもの（例: NoScript 系） | main-world 注入、広範な script policy、複雑なサイト例外が最小の content-script profile を超える。 |
| Cookie・キャッシュを自動削除するもの（例: Cookie AutoDelete 系） | Safari/WebKit の cookie・profile policy と衝突しやすく、private separation とデータ削除の P0 方針を先に決める必要がある。 |
| 外部リストや CDN を常時取得する blocker／privacy tool | remote DNR list、silent behavior change、取得先の privacy review が catalog-v1 の fail-closed 境界に反する。 |
| Container、多重 identity、password manager、SponsorBlock、校正・翻訳系 | containers、credentials、動画サービス API、機微な入力内容、外部 AI/同期など、現行の MV3 互換プロファイルまたは privacy review の範囲を超える。 |

## 候補を一件選んだ後の順序

1. license、notice、provenance、データ保持方針を確認し、再配布根拠を記録する。
2. 閉じた manifest preflight と `FWEA1` builder で immutable artifact を作り、review
   metadata・digest・compatibility profile を固定する。
3. normal/private profile、site permission、disable/delete/update/revocation、action 有無、
   accessibility、性能を実機で測定する。
4. 署名済み失効演習を行い、release evidence を P0/P5 ゲートに添付する。
5. 承認済みの production composition でだけ signed catalog に掲載し、外部 TestFlight の
   review と tester install を開始する。
