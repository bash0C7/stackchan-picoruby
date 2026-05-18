# Kawaii AI Robot — whole design

**Date:** 2026-05-18
**Status:** approved (D1-D5 推奨案、scope 分割 NG)
**Branch:** (TBD per-phase feature branch)

## Goal

StackChan を kawaii AI 対話ロボットとして完成させる。3 機能 (servo / AI 対話 / touch sensor) を**一貫した whole 体験**として設計する (個別機能の分離 spec ではない)。

完成時の体験:

1. 平常時は idle (LED 青 breathing + Neutral face + 首ゆっくり微振動)
2. ユーザが**おでこを触る** (push-to-talk) → wake、face は Listening、首は前向き
3. **Mac mic** が SFSpeechRecognizer で STT、AI 推論中は face=Doubt + LED 紫 pulse
4. **Apple Foundation Model** (`rb-foundation-model-mac`) で返答生成、emotion tag prefix `(Happy)(Sad)` 等付き
5. emotion tag に応じて **face + LED color + servo motion** を 1 BLE frame で atomic 切替、同時に **Mac speaker** から TTS 再生
6. TTS 終了で idle に戻る
7. 左/右 touch = secondary action (会話 cancel / mute toggle)

## Non-goals (今回 spec 外、別 spec 化)

- **WiFi 周り全部** (sdkconfig COEX 再有効化、`picoruby-net-websocket` 統合)
- **Stack-chan mic / speaker 経由の audio path** (I2S codec ES8311、PCM stream)
- **Camera (GC0308)**
- **IMU (BMI270 + BMM150)**
- **NFC、microSD、PCF8563 RTC、camera、external network LLM**
- 多 StackChan 同時制御

mic + camera + WiFi は技術的に大きいので別 scope に切り出し。それまでは **BLE only + Mac mic/speaker** で kawaii 体験を成立させる。

## Architecture overview

```
┌────────────────────────────────────────────────────────────────┐
│ Mac (USB-powered desktop next to robot)                        │
│                                                                │
│   ┌──────────────────┐   ┌──────────────────────────────────┐ │
│   │ Mac built-in mic │──►│ rb-apple-speech-mac (new)        │ │
│   └──────────────────┘   │   SFSpeechRecognizer push-stream │ │
│                          └──────────────┬───────────────────┘ │
│                                         │ transcript          │
│                                         ▼                     │
│   ┌──────────────────────────────────────────────────────────┐│
│   │ stackchan-ai-companion (new daemon)                       ││
│   │   - state machine (IDLE/LISTENING/THINKING/SPEAKING/ERR)  ││
│   │   - Foundation Model call w/ system prompt (emotion tag) ││
│   │   - emotion parse → (face, led, servo) tuple             ││
│   │   - BLE frame compose → stackchan-ble-client              ││
│   │   - TTS schedule → rb-apple-speech-mac                    ││
│   └────────────┬─────────────────────────┬───────────────────┘│
│                │                          │                    │
│                ▼                          ▼                    │
│   ┌──────────────────┐   ┌──────────────────────────────────┐│
│   │ Mac speaker      │◄──│ rb-apple-speech-mac TTS          ││
│   └──────────────────┘   │   AVSpeechSynthesizer            ││
│                          └──────────────────────────────────┘│
│                                                                │
│   ┌──────────────────────────────────────────────────────────┐│
│   │ stackchan-ble-client (extended bidirectional)             ││
│   │   - write: combo frame (F/L/R/G/B/S/M/X/Y/V/H/Q)          ││
│   │   - notify subscribe: <T:...> <P:...> <B:...> <E:...>     ││
│   └────────────┬─────────────────────────────────────────────┘│
└────────────────┼───────────────────────────────────────────────┘
                 │ BLE NUS bidirectional
                 ▼
┌────────────────────────────────────────────────────────────────┐
│ StackChan (CoreS3, PicoRuby + R2P2-ESP32)                      │
│                                                                │
│   ┌──────────────────────────────────────────────────────────┐│
│   │ picoruby-stackchan-protocol (extended)                    ││
│   │   - FrameParser (KV grammar、key 追加: X/Y/V/H/Q/T/P)     ││
│   │   - Dispatcher (face/led/servo/home の 1 frame atomic)    ││
│   │   - main loop: BLE recv + headtouch poll + notify         ││
│   └────┬─────────┬──────────┬─────────────────────────────────┘│
│        │         │          │                                  │
│        ▼         ▼          ▼                                  │
│   ┌──────────┐ ┌──────┐ ┌──────────────────────────────────┐  │
│   │ ILI9342  │ │ WS28 │ │ picoruby-scservo (new)           │  │
│   │ face     │ │ 12   │ │   SCS0009 UART driver (Feetech)  │  │
│   │ render   │ │ LED  │ │   move(x,y)/rotate_x/home/feedback│ │
│   └──────────┘ └──────┘ └──────────────────────────────────┘  │
│                                                                │
│   ┌──────────────────────────────────────────────────────────┐│
│   │ picoruby-stackchan-headtouch (new)                        ││
│   │   Si12T 3-zone I2C poll + debounce + event detect         ││
│   │   → front/left/right + press/release                      ││
│   └──────────────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────────────────┘
```

## Conversation state machine

```
        ┌──── TTS done / timeout ────┐
        │                            │
        ▼                            │
    [IDLE] ──── touch:front ───►[LISTENING]
        ▲                            │
        │                       touch:front:rel
        │                            │
        │                            ▼
        │                       [THINKING] ── Foundation Model →
        │                            │
        │                  emotion tag parse
        │                            │
        │                            ▼
        └─── audio done ─────── [SPEAKING]

    [ERROR] (BLE 切断 / Foundation Model unavailable etc)
       ↑ どの状態からでも transition、回復で [IDLE] へ
```

5 状態。各状態は `(face_id, led_color, led_mode, servo_x, servo_y, servo_v)` の tuple で表現。**状態遷移 1 回 = BLE 1 frame** で atomic 適用 (Stack-chan 側はステートレス)。

### State tuple table

LED color は (R,G,B) on wire (HSB → ble-client SDK で変換)。side は両方 (S:B) を default。

| State | face | LED (R,G,B) | LED mode | servo X | servo Y | servo V |
|---|---|---|---|---|---|---|
| IDLE | neutral | (0, 0, 64) | breathing | 0 (center) | 550 | 0 |
| LISTENING | neutral | (0, 200, 0) | breathing | 0 | 550 (前向き) | 0 |
| THINKING | surprised | (128, 0, 128) | pulse | 100 (傾き) | 600 | 0 |
| SPEAKING | (emotion tag に応じ §6 マッピング) | (同上) | breathing-fast | 0 | 500 | 100 (軽 wobble) |
| ERROR | sad | (200, 0, 0) dim | blink | 0 | 550 | 0 |

## Decisions

| # | 判断 | 値 |
|---|---|---|
| D1 | STT/TTS location | **両方 Mac**。新 gem `rb-apple-speech-mac` で SFSpeechRecognizer (push-stream STT) + AVSpeechSynthesizer (TTS、voice/rate/pitch 制御で kawaii 化) |
| D2 | 会話 wake trigger | **forehead touch = push-to-talk**、押下中 listening、離して STT 確定 |
| D3 | 感情タグ規約 | **robo8080 6 種** `(Neutral)(Happy)(Sleepy)(Doubt)(Sad)(Angry)`、system prompt で強制 |
| D4 | servo API | 公式踏襲 `move(x,y)/move_x/move_y/rotate_x/home/stop`、単位 10=1°、X=±1280、Y=0-900 (推奨 5-85)、SCS0009 UART 1Mbaud |
| D5 | BLE 構成 | 既存 NUS 双方向: write=Mac→robot (combo frame)、notify=robot→Mac (touch / battery / error)、1 connection |
| D6 | scservo driver impl | **Pure PicoRuby on `picoruby-uart`** (picoruby-mpu6886 と同じ host テスト可能な pattern)。C 拡張 mrbgem は最後の手段 |

## Component responsibilities

### Device 側 mrbgems

| gem | Type | Responsibility |
|---|---|---|
| `picoruby-scservo` | **新規** Pure PicoRuby | SCS0009 (Feetech) UART 1Mbaud protocol。pan (id=1) / tilt (id=2) 制御、Present_Position feedback read。host CRuby + uart gem mock でテスト可能 |
| `picoruby-stackchan-headtouch` | **新規** Pure PicoRuby | Si12T 3-zone I2C poll、debounce (50ms)、press/release event 検出。`HeadTouch.new(...).poll → events` で event 列を返す pull API |
| `picoruby-stackchan-protocol` | **拡張** | FrameParser に key `X/Y/V/H` (servo) と `T` (touch event outbound) 追加、Dispatcher に servo route、main loop に headtouch poll + notify 送信、Face::Sad / Face::Angry 新規追加 |
| `picoruby-stackchan-led` | (touch 不要、無変更) | |
| `picoruby-ili9342` | (touch 不要、無変更) | |

### Mac 側 gems

| gem | Type | Responsibility |
|---|---|---|
| `stackchan-ble-client` | **拡張** | bidirectional 化: `Client#subscribe { |event| ... }` API 追加、combo frame DSL に `pan:`, `tilt:`, `rotate:`, `home:` 追加。test-only `inject_notify` API (Phase C verify 用) |
| `rb-apple-speech-mac` | **新規別 repo** | `~/dev/src/github.com/bash0C7/rb-apple-speech-mac`。`rb-foundation-model-mac` と同じ Swift binding pattern。`Speech::Recognizer.new.push_audio(pcm) → stream { |partial, final| }`、`Speech::Synthesizer.new.speak(text, voice:, rate:)` + `render_pcm(text) → bytes` |
| `stackchan-ai-companion` | **新規別 repo** | `~/dev/src/github.com/bash0C7/stackchan-ai-companion`。orchestrator daemon。state machine + Foundation Model + emotion parser + ble-client + rb-apple-speech-mac 統合。`exe/stackchan-ai-companion-daemon` で long-running |

## Frame protocol grammar (BLE NUS 双方向)

### Mac → robot (write to NUS RX char)

KV 形式、全 key optional、来た key だけ apply、1 frame で atomic state 遷移。
**既存の F/L/R/G/B/S/M キーは触らず、追加分は X/Y/V/H/Q のみ**。

```
<F:1,L:1,R:255,G:128,B:0,S:B,M:p,X:-200,Y:600,V:0,H:0,Q:1>
 │   │   │     │     │    │   │   │      │    │   │   │
 face LED red  green blue side mode pan   tilt  rot home query
 idx  en                                              (1=goHome) (1=要求 P notify)
```

| Key | Type | Range | 意味 | 新規/既存 |
|---|---|---|---|---|
| F | int | 0..n (FACE_TABLE index) | face id | 既存 |
| L | int | 0/1 | LED enable flag (1 のとき R/G/B/S/M を適用) | 既存 |
| R | int | 0-255 | LED red | 既存 |
| G | int | 0-255 | LED green | 既存 |
| B | int | 0-255 | LED blue | 既存 |
| S | char | "R"/"L"/"B" | side (StackChan 視点で R=left, L=right, B=both)。memory `project_stackchan_wire_format.md` 参照 | 既存 |
| M | char | s/p/b/o (solid/breathing/blink/off) ほか既存規約 | LED mode | 既存 |
| X | int | -1280 to 1280 | servo pan (10=1°) | **新規 (B)** |
| Y | int | 0 to 900 (推奨 50-850) | servo tilt | **新規 (B)** |
| V | int | -1000 to 1000 | rotate_x velocity (0=stop) | **新規 (B)** |
| H | int | 0 or 1 | 1=goHome を発火 | **新規 (B)** |
| Q | int | 0 or 1 | 1=現在の servo position を `<P:x,y>` notify で即返す (verify 用) | **新規 (B)** |

LED の HSB packed (0xHHSSBB) 入力は **ble-client SDK 側で吸収** (`hsb_to_rgb.rb`)、wire に乗る時点では R/G/B 分離済。

ACK は既存 `.` (success) / `?` (parse error) 1 byte notify そのまま。combo frame の atomic 適用 = 全 key を適用してから ACK 返す。

### Robot → Mac (notify from NUS TX char)

```
<T:front>             ← touch press (front/left/right)
<T:front:rel>         ← touch release
<P:-200,598>          ← servo position response (Q:1 で要求された時のみ)
<B:67>                ← battery percent (low-freq heartbeat、5s 毎)
<E:scservo_timeout>   ← error/debug string
```

| Key | 意味 | 新規/既存 |
|---|---|---|
| T | touch event (press / release) | **新規 (C)** |
| P | servo position (X,Y) response | **新規 (B)** |
| B | battery percent | **新規 (任意 phase)** |
| E | error/debug string | **新規 (任意 phase)** |

### Combo frame composability

state machine の 1 transition で `F / L / S / M / X / Y / V` を**全部 1 frame に詰める**。device 側 dispatcher は **全 attribute 適用してから ACK** (atomic 適用、中途半端な face/LED 状態が見えない)。

## Emotion → device state mapping (D3)

`(Neutral) text` のような prefix から tag 抜き出し:

| Tag | face | LED (R,G,B) | LED mode | servo motion hint |
|---|---|---|---|---|
| Neutral | neutral | (64, 64, 64) (dim white) | breathing | center hold |
| Happy | joy | (255, 128, 0) (warm orange) | breathing-fast | nod (Y を一瞬 -50 して戻す) |
| Sleepy | closed | (64, 0, 64) (dim purple) | breathing-slow | tilt down 30° |
| Doubt | surprised | (0, 200, 0) (green) | blink | tilt 15° |
| Sad | **sad** (新 face) | (0, 0, 100) (dim blue) | breathing-slow | tilt down 15° |
| Angry | **angry** (新 face) | (200, 0, 0) (red) | blink-fast | 小刻み振動 (V 短時間 ±200) |

motion hint は orchestrator が "primary state + brief gesture" として送る (Phase E で詳細)。

system prompt:

```
あなたは Stack-chan という kawaii デスクトップロボット。
返答は必ず `(EmotionTag) 本文` の形で。
EmotionTag は Neutral / Happy / Sleepy / Doubt / Sad / Angry のいずれか。
返答は 2 文以内、関西弁、ですます調禁止、kawaii tone。
```

## Phasing (内部段階、scope 分割では無い)

各 phase = 実装 + **claude が単独叩ける `rake ...:verify` task** セット。Phase 完了 = verify PASS。

| Phase | 実装 | autonomous verify | HITL 1 回だけ |
|---|---|---|---|
| **A**: Face 拡張 | `Face::Sad`, `Face::Angry` を `picoruby-stackchan-protocol/mrblib/` に追加、`FACE_TABLE` 拡張、ble-client / notifier の `--face` 候補拡張 | `rake r2p2:face_verify FACE=sad` — Mac BLE write → ACK assert + **frame buffer SHA hash compare** vs `spec/golden/face_sad.sha256` | 初回 calibration: 「sad / angry 見た目 OK?」HITL 確認 → hash 登録 |
| **B**: Servo | `picoruby-scservo` 新規、`picoruby-stackchan-protocol/dispatcher.rb` に servo route (X/Y/V/H/Q) 追加、ble-client に `pan/tilt/rotate/home/query_position` DSL | `rake r2p2:servo_verify` — `<X:300,Y:600,Q:1>` write → `<P:x,y>` notify 受信 → 期待値 ±2° assert、`<V:200>` で rotate → 1s 後 stop、`<H:1>` で home + `<Q:1>` で (0,550) assert | 初回 calibration: pan +100 がどっち向き / tilt +100 がどっち、wire 入れ替わり判定 |
| **C**: Touch | `picoruby-stackchan-headtouch` 新規、main loop で poll → BLE notify `<T:...>`、ble-client に `subscribe` API + test-only `inject_notify` | `rake r2p2:touch_verify` — no-touch baseline (50 sample 全 0 assert) + `inject_notify('<T:front>')` で fake event → Mac subscribe 受信 assert | 初回 1 回: 実 hardware 触ってもらって Si12T 経由で notify 飛ぶ smoke |
| **D**: speech-mac | `rb-apple-speech-mac` 新規別 repo、Swift binding (SFSpeechRecognizer + AVSpeechSynthesizer)、Ruby API、examples | `rake speech:verify` — `say -v Kyoko "ええ天気やな" -o test.aiff` → SFSpeechRecognizer feed → transcript 期待 assert + TTS render → PCM bytes 非空 + 長さ ±20% assert | 無し (Mac 完結) |
| **E**: ai-companion + E2E | `stackchan-ai-companion` 新規別 repo、state machine + Foundation Model + emotion parse + ble-client + speech-mac 統合、`exe/stackchan-ai-companion-daemon` | `rake stackchan_ai_companion:e2e_verify` — mock touch inject → 実 or mock Foundation Model → 期待 state sequence assert + 期待 BLE frame sequence assert + TTS audio file 生成 assert | kawaii demo gif 録画 (test ではなく deliverable) |

Phase 間依存: A → B/C 並行可 → D 並行可 → E (全依存)

## Testing strategy

**原則: claude が 1 command で言える PASS を default、HITL は本当に視認しかない瞬間だけ**

### claude 完全自動 (default)

- 全 mrbgem の unit test (host CRuby + test-unit + Bundler、`rake test`)
- frame protocol round-trip (host parser → dispatcher mock)
- BLE smoke (`rake r2p2:ble_verify` 拡張、各 phase の verify task)
- Servo position assert (SCS0009 feedback read 経由)
- Touch event assert (inject_notify 経由)
- Face render assert (frame buffer SHA hash compare)
- LED state assert (write 直後 PY32 register read back)
- Mac STT/TTS pipeline (synthetic WAV in / PCM bytes out)
- Foundation Model query format (emotion tag prefix 存在 assert)
- State machine (全 I/O mock)
- E2E conversation (mock touch + 実 or mock LLM)

### HITL (各 phase 1 回だけ、calibration 用)

- Phase A 初回: 新 face (sad / angry) の見た目 OK → frame hash 登録
- Phase B 初回: servo 物理方向 (pan +100 = どっち / tilt +100 = どっち) → wire swap 判定
- Phase C 初回: 実 hardware touch → Si12T が driver 経由で notify 出す smoke
- Phase E 完了時: kawaii demo gif 録画 (deliverable)

**Phase 1-3 既存 BLE/face/LED の hash 登録 / 物理方向 calibration も Phase A 開始時にまとめて 1 回やる**。それ以降は全部 claude 完結。

### 実装上の鍵 (test infra)

- **Face hash compare**: `Face.draw_to_buffer` で 320×240×2 byte RGB565 をメモリに書く path 分離 → SHA256 → golden file 対比。LCD 物理描画は別 entry point
- **Touch fake inject**: ble-client に `inject_notify(frame_str)` test-only API、production path には残さない (`#fileprivate` or `test_helper.rb` 経由)
- **Servo position read**: ble-client → device に `<Q:1>` query → device は SCS0009 protocol の `0x38 (Present_Position)` を UART read → `<P:x,y>` notify で return。verify task はこの round-trip で position assert
- **STT synthetic audio**: `say -v Kyoko ... -o tmp/test.aiff` → SFSpeechRecognizer 入力 (file 経由 push) → transcript assert

### Error handling 規約

- silent rescue 厳禁 (CLAUDE.md `~/dev/src/CLAUDE.md` 規約)
- recoverable 失敗 (BLE 一時切断、SCS0009 timeout single) → INFO log + retry
- 致命的 (Foundation Model unavailable、I2C bus dead) → ERROR log + state=ERROR transition + 上位に propagate
- test code は `omit "reason: #{e.message}"` で skip 理由可視化

## Non-obvious gotchas (実装時注意)

- **cold-boot sleep 3000ms**: BLE init 前に `sleep_ms 3000` で BTstack thread yield (CLAUDE.md / `project_ble_phase3_btstack_starve_finding.md` 参照)
- **wire L/R swap**: `picoruby-stackchan-led` で既に swap 済 (`feedback_stackchan_wire_format.md`)、servo も初回 calibration で同様判定
- **Mac CoreBluetooth GATT cache trap**: `feedback_mac_corebluetooth_gatt_cache_trap.md` 既知、subscribe 拡張時に再度引っかかる可能性、iPhone nRF Connect 並行検証残す
- **Ruby 4.0 trap context**: signal trap から Mutex 禁、`feedback_ruby4_trap_mutex.md` 既知、ai-companion daemon の SIGINT/TERM 処理で Thread.new deferral 必須
- **PicoModem upload race**: bring-up app は固定時間 sleep + exit、dispatcher loop は exit hatch 必須 (CLAUDE.md `bring-up app の書き方`)
- **AW9523 reg 0x02 = 0b00000111**: WS2812 5V rail enable、cold-boot で必須 (CLAUDE.md)
- **PY32 GPIO 0 (VM_EN)**: servo 電源、cold-boot で HIGH + 200ms settle 必要 (servo 駆動の前提)

## Repo / file layout

### このリポジトリ (`stackchan-picoruby`)

```
mrbgems/
  picoruby-scservo/                          (new, Phase B)
    mrbgem.rake
    mrblib/scservo.rb
    examples/servo_smoke.rb
    Rakefile
    test/test_scservo.rb
  picoruby-stackchan-headtouch/              (new, Phase C)
    mrbgem.rake
    mrblib/headtouch.rb
    examples/touch_smoke.rb
    Rakefile
    test/test_headtouch.rb
  picoruby-stackchan-protocol/               (extend A,B,C)
    mrblib/face_sad.rb                       (new, A)
    mrblib/face_angry.rb                     (new, A)
    mrblib/dispatcher.rb                     (extend B,C: X/Y/V/H/T)
    mrblib/application.rb                    (extend C: touch poll loop)
    spec/golden/face_sad.sha256              (new, A)
    spec/golden/face_angry.sha256            (new, A)
pc/
  stackchan-ble-client/                      (extend, all phases)
    lib/stackchan_ble_client/client.rb       (subscribe, inject_notify, servo DSL)
  stackchan-notifier/                        (extend A: --face sad/angry)
Rakefile                                     (add face_verify/servo_verify/touch_verify)
```

### 別 repo

```
~/dev/src/github.com/bash0C7/rb-apple-speech-mac/     (new, Phase D)
  Cargo style: Swift binding + Ruby gem (rb-foundation-model-mac 踏襲)
  lib/apple_speech_mac.rb
  ext/swift/...
  examples/{stt_basic,tts_basic,push_stream}.rb

~/dev/src/github.com/bash0C7/stackchan-ai-companion/  (new, Phase E)
  exe/stackchan-ai-companion-daemon
  lib/stackchan_ai_companion/{state_machine,emotion_parser,orchestrator}.rb
  Gemfile (path: stackchan-ble-client, rb-apple-speech-mac, rb-foundation-model-mac)
  test/...
```

## Out of scope (再掲)

- WiFi 関連 (sdkconfig COEX、websocket、HTTP/MQTT)
- mic / speaker / I2S codec / audio stream
- camera (GC0308)
- IMU (BMI270 + BMM150)
- NFC、microSD、PCF8563 RTC、外部 LLM API

これらは別 spec で扱う。

## References

### 公式 / pre-art

- [M5Stack StackChan Servo API (公式)](https://docs.m5stack.com/en/arduino/stackchan/servo) — D4 verb / 単位の出典
- [M5Stack StackChan official](https://docs.m5stack.com/en/stackchan)
- [robo8080/M5Unified_StackChan_ChatGPT](https://github.com/robo8080/M5Unified_StackChan_ChatGPT) — D3 感情タグ 6 種規約の出典
- [rt-net/stack-chan ChatGPT mod](https://github.com/rt-net/stack-chan/blob/main/firmware/mods/chatgpt/README_ja.md) — PC-centric architecture pattern
- [Stack-chan Hackaday project](https://hackaday.io/project/181344-stack-chan-javascript-driven-super-kawaii-robot)

### 本リポジトリ既存 spec

- `2026-05-14-stackchan-protocol-design.md` — frame KV grammar の出典、本 spec で key 追加
- `2026-05-14-stackchan-led-protocol-extension-design.md` — LED L/M/S key の出典
- `2026-05-16-ble-mac-autonomous-verification-loop-design.md` — `rake r2p2:ble_verify` autonomous loop pattern、本 spec の verify task はこれを Phase ごとに増殖
- `2026-05-17-claude-code-notification-bridge-design.md` — daemon + worker + tuple 構造、ai-companion daemon の参考

### CLAUDE.md / memory

- `~/dev/src/github.com/bash0C7/stackchan-picoruby/CLAUDE.md` — cold-boot init、BLE COEX、bring-up app、rake は subagent foreground 等
- memory: `project_ble_phase2_complete.md`, `project_stackchan_wire_format.md`, `feedback_mac_corebluetooth_gatt_cache_trap.md`, `feedback_ruby4_trap_mutex.md`, `project_ble_phase3_btstack_starve_finding.md`
