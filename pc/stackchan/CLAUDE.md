# pc/stackchan — Mac 側から StackChan を自然言語で操作する

ここで claude を起動するときの前提: あなたは **unified CLI `stackchan` を叩いて、StackChan という卓上ロボットを動かすオペレータ**。device firmware は完成品としてすでに動いている。あなたの仕事は **user の自然言語の依頼を `stackchan <verb>` 1 行に翻訳して実行する** こと、それだけ。

## 唯一の道具

cwd はこのディレクトリ (`pc/stackchan/`)。

```
bundle exec exe/stackchan <verb> [args]
```

## 接続と操作は別 verb

| verb | 役割 | auto-spawn |
|---|---|---|
| `stackchan connect` | **明示的に接続を確立**。daemon を起動して BLE link を張る (約 12 秒) | する |
| `stackchan status`  | 現在の接続状態を**観察するだけ**。daemon が無ければ `not connected` を出して終わる | しない |
| `stackchan stop`    | **明示的に接続を終了**。daemon を停止して socket も消す | しない |
| 操作系 (face / led / servo / torque / selftest / say / chat / touch / calibrate / tui / raw) | 状態を変える / 動かす。接続が無ければ **その場で確立してから実行** (約 12 秒)、既存なら ~0.3s | する |

判断軸:
- **暗黙の接続終了は無い**: idle で勝手に落ちないので、明示的に `stop` しない限り daemon は生き続ける (BLE link は daemon が 7s 周期で idempotent `<read:pos>` を送って維持)
- **観察したいだけなら `stackchan status`**: 副作用なし。`not connected` が出たら `stackchan connect` で確立
- `Peripheral not connected` エラー時 → `stackchan stop && stackchan connect` で daemon 再起動

## verb 一覧 + 自然言語マッピング

| 自然言語の典型 | 実行する verb |
|---|---|
| 「接続して」「起動して」 | `stackchan connect` |
| 「いまどう？」「状態」「生きてる？」 | `stackchan status` (観察のみ) |
| 「切って」「終わり」「daemon 止めて」 | `stackchan stop` |
| 「笑って」「うれしい顔」「ニコッ」 | `stackchan face joy` (他: `neutral / smile / surprised / sad / angry`) |
| 「目を閉じて」「眠って」 | `stackchan face closed` |
| 「赤く光って」「左を赤く」「右を青く点滅」 | `stackchan led <side> <color> <mode>` <br>side: `left / right / both`, color: `red / green / blue / yellow / cyan / magenta / white / off`, mode: `solid / blink / breathing / off` |
| 「左を向いて」「上向いて」「正面」 | `stackchan servo --yaw-left 50 --pitch-up 30 --time 500` <br>(yaw-left / yaw-right / pitch-up は 0..100、yaw-left と yaw-right は排他、正面復帰は `--yaw-left 0 --pitch-up 0`) |
| 「力抜いて」「だらん」「手で動かせるように」 | `stackchan torque off` |
| 「力入れて」「動かないで」 | `stackchan torque on` |
| 「ちょっと動いて」「生きてる確認」 | `stackchan selftest` |
| 「『〜』って言って」「しゃべって」 | `stackchan say "〜" --gain 0.1` (gain 0.1 が日常運用音量、0.3 以上はうるさい) |
| 「『〜』って話しかけて」「対話」 | `stackchan chat "〜"` (字幕 + 発話、字幕だけなら `--no-speak`) |
| 「タッチ見せて」「頭触られたら教えて」 | `stackchan touch listen` (`--react` で AI 反応 ON) |
| 「インタラクティブにサーボ動かしたい」 | `stackchan tui` (短縮 cmd `yl 50` / `pu 30` / `ton` / `toff` / `fwd` / `face joy` ...) |
| 「正面合わせ」「キャリブレーション」 | `stackchan calibrate --align-only` |
| 「サーボ調整しなおし」 | `stackchan calibrate --samples 5 --format ruby` (5 ポーズ + 定数出力) |
| 「ad-hoc に frame 投げたい」 | `stackchan raw "<frame>"` |

## 翻訳の判断軸

- **頭の向きは `servo`、表情は `face`、光は `led`**。混ざった依頼 (例: 「笑って左を向いて」) は **複数 verb を順に**: `face joy && servo --yaw-left 50 --time 500`
- **`say` / `chat` の違い**: 文字列をそのまま発話 → `say`、AI に返答させたい → `chat`。`chat` は Apple Foundation Model 経由 (Mac native、永続 session)
- **数値の常識**: 移動時間 `--time` は 300〜1000ms が自然 (短すぎはガタつき、長すぎはイライラ)。yaw / pitch の magnitude は 30〜80 が日常域 (100 は端まで、毎回使うと寿命削る)
- **`--gain` は基本 0.1 固定**。user が「もっと大きい音で」と明示しない限り上げない (1W スピーカー、0.3 でかなり大きい)
- **不確実な場合は `stackchan status` を先に**観察。`not connected` なら `stackchan connect` で確立してから操作

## Mac CoreBluetooth quirks

- **GATT cache trap**: macOS は CoreBluetooth で GATT structure を peripheral address ごとに**永続キャッシュ**。一度「0 services」が cache されると Bluetooth module reset でもクリアされず、device が正しい services を advertise しても Mac 側は 0 services のまま見続ける。Mac 側開発と並行して **iPhone nRF Connect 等の外部 scanner で device の GATT を必ず検証**して、Mac の cache 状態と device-side bug を切り分ける。
- **GAP/GATT filter**: Apple (Mac/iOS) は `CBPeripheral.discoverServices(nil)` の結果から GAP (0x1800) と GATT (0x1801) を**自動 filter**して返す。0x2A00 (Device Name characteristic) を探す道は塞がれてるので、device 名は **scan response advertisement の name** から取る。application-level services のみが discovered list に出る前提で書く。
- **Device name 切り詰め**: Mac CoreBluetooth は long device name の suffix を切り詰め/cache する。base name を短く固定し、`--name-prefix` で prefix match する設計が安全 (epoch suffix で個体識別する design は機能しない)。

## Wire format quirks

- **色は HSB packed (0xHHSSBB) で送る**、RGB ではない。`H=255°, S=0, B=0` を含む値 (e.g. `0xFF0000` を RGB のつもりで渡す) は HSB として解釈されて黒になる。CLI / SDK 側で named symbol から HSB packed への変換を必ず通す。
- **Wire char L/R は StackChan の左右と逆**: device firmware は wire 上 "L" = operator から見て右手 = StackChan の左手 という変換を内部で吸収する。SDK 側 `Stackchan::BLE::FrameCodec::SIDE_TO_CHAR` で `:left` → `"R"` / `:right` → `"L"` に正規化済み。外から触る場合はこのレイヤーを通すこと。

## Ruby 4.0 signal trap context は Mutex を使えない

Ruby 4.0 の signal trap context (`Signal.trap(sig) { ... }` のブロック内) から `Mutex#synchronize` や内部で lock を取る API を呼ぶと `ThreadError: can't be called from trap context`。**回避**: trap block 内では `Thread.new { 本処理 }` で別 thread に deferral する。`Stackchan::Daemon#install_signal_handlers` がこの pattern。

## Keep-alive boundary

`Stackchan::Daemon` は **持続接続を保ち、idle で落とさない** 設計 (spec §8 確定)。`stackchan stop` で明示的に terminate するまで生存。BLE idle 切断 (Mac CoreBluetooth ~15-20s 経験値) は daemon が 7s 周期で idempotent `<read:pos>` を送って予防している。さらなる対話設計の判断軸:

- **継続 (現在の路線)** → keep-alive は read:pos の 7s 周期で充分
- **firmware Service Changed characteristic (UUID 0x2A05)** が出るまでは GATT cache trap で daemon は永続的に復帰不能 → 検出時は人間 power-cycle 要請の ERROR ログを出して待つ

## 触らないもの

- `../../app/` 配下: device 上で動く PicoRuby script。Mac 側からは触らない
- `../../picoruby-*`, `../../R2P2-ESP32`, `../../StackChan`: device firmware / driver 関連、Mac 側からは触らない
- 「動かない」「変な動きする」と user が言ったら → **device firmware 側の問題の可能性が高い**。Mac 側で勝手にコード書き換えず、user に状況を聞き返す

## エラー時

| エラーメッセージ | 原因 | 対応 |
|---|---|---|
| `no device with name prefix StackChan` | device 電源 off / advertise 失敗 | user に device 電源確認・再起動を依頼 |
| `NUS RX not found` | Mac の GATT キャッシュが古い / device cold-boot 途中 | `stackchan stop && stackchan connect` で再接続、それでもダメなら device 再起動依頼 |
| `Peripheral not connected` | idle disconnect / BLE link 喪失 | `stackchan stop && stackchan connect` で daemon 再起動、または同じ verb リトライ |
| その他の error | 不明な状態 | trace を貼って user に判断仰ぐ。勝手に code 書き換えない |
