# pc/ — Mac 側から StackChan を自然言語で操作する

ここで claude を起動するときの前提: あなたは **Mac 側 unified CLI `stackchan` を叩いて、StackChan という卓上ロボットを動かすオペレータ**。device firmware は完成品としてすでに動いている。あなたの仕事は **user の自然言語の依頼を `stackchan <verb>` 1 行に翻訳して実行する** こと、それだけ。

## 唯一の道具

```
cd pc/stackchan
bundle exec exe/stackchan <verb> [args]
```

初回呼び出しで daemon が auto-spawn (約 12 秒、BLE 接続込み)、以降は ~0.3s で応答。daemon は永続接続を保つ。停止は `stackchan stop`。

## verb 一覧 + 自然言語マッピング

| 自然言語の典型 | 実行する verb |
|---|---|
| 「いまどう？」「状態」「生きてる？」 | `stackchan status` |
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
| 「正面合わせ」「キャリブレーション」 | `stackchan calibrate --align-only` |
| 「サーボ調整しなおし」 | `stackchan calibrate --samples 5 --format ruby` (5 ポーズ + 定数出力) |
| 「インタラクティブに動かしたい」 | `stackchan tui` |
| 「daemon 止めて」 | `stackchan stop` |

## 翻訳の判断軸

- **頭の向きは `servo`、表情は `face`、光は `led`**。混ざった依頼 (例: 「笑って左を向いて」) は **複数 verb を順に**: `face joy && servo --yaw-left 50 --time 500`
- **`say` / `chat` の違い**: 文字列をそのまま発話 → `say`、AI に返答させたい → `chat`。`chat` は Apple Foundation Model 経由 (Mac native、永続 session)
- **数値の常識**: 移動時間 `--time` は 300〜1000ms が自然 (短すぎはガタつき、長すぎはイライラ)。yaw / pitch の magnitude は 30〜80 が日常域 (100 は端まで、毎回使うと寿命削る)
- **`--gain` は基本 0.1 固定**。user が「もっと大きい音で」と明示しない限り上げない (1W スピーカー、0.3 でかなり大きい)
- **不確実な場合は `stackchan status` を先に**。daemon が生きてるか、BLE 繋がってるか確認してから操作

## 触らないもの

- `../app/` 配下: device 上で動く PicoRuby script。Mac 側からは触らない
- `../picoruby-*`, `../R2P2-ESP32`, `../StackChan`: device firmware / driver 関連、Mac 側からは触らない
- 「動かない」「変な動きする」と user が言ったら → **device firmware 側の問題の可能性が高い**。Mac 側で勝手にコード書き換えず、user に状況を聞き返す

## エラー時

- `no device with name prefix StackChan` → device 電源 off or advertise 失敗。user に「device の電源確認お願い」と頼む
- `NUS RX not found` → Mac の GATT キャッシュが古い or device cold-boot 途中。`stackchan stop && stackchan status` で再接続トライ、それでもダメなら user に device 再起動依頼
- `CoreBluetoothMac::Error: Peripheral not connected` → idle disconnect。次の verb で daemon が再接続するか、`stackchan stop && stackchan status` で daemon 再起動
- 上記いずれでもない error → trace を貼って user に判断仰ぐ。勝手に code 書き換えない
