# Phase B Task 10: cold-boot crash bisect (2026-05-19, セッション 2 終了)

## サマリ

Phase B Task 10 を 2 セッション目で再開。USB replug + reset 物理ボタンを user 側で実施してもらい、device hardware は回復。Firmware full_rebuild ふくめ deploy chain (build_flash → wipe_storage → upload_appmrb → reset) 全部通った。**しかし application.rb cold-boot で `[application] PY32 REG_VERSION = 0x41` 直後に `Guru Meditation Error: LoadProhibited` 発生**。Phase A 時代に動いてた region で crash してるので、Phase B 変更 (require 追加 / build_config 変更 / picoruby-scservo 新 gem 追加) のどれかが間接破壊した疑い濃厚。

addr2line 解析: `mrb_vm_exec` (mruby bytecode interpreter) でnull pointer-relative load (EXCVADDR=0x00000008)。method 呼び出し対象がnilなのに lookup したパターン。

## 完了済 / 進行中

| Task | 状態 | Commit |
|---|---|---|
| 1-9 | DONE | 3cb2ed6 〜 dda8be3 + bcd14d0 (R2P2) |
| 10: rebuild + deploy chain | **partial** — flash/wipe/upload/reset 通る、cold-boot で crash |
| 10: cold-boot bisect | **in progress** — debug puts 投入済 (commit e96a048)、再 deploy で crash 位置確定が次の一手 |
| 11-16 | pending |

直近 commit (本セッション):
- `53dd264` fix(scservo,app): align with picoruby-uart on-device API (前セッション末)
- `e96a048` wip(app): add uart/scservo requires + cold-boot bisect puts (今セッション)

## crash の事実

boot capture log: `/tmp/stackchan-picoruby-debug/boot-after-require-fix.log`

```
[application] boot
[application] PY32 REG_VERSION = 0x41
Guru Meditation Error: Core  0 panic'ed (LoadProhibited). Exception was unhandled.
```

crash-analyze 結果: `/tmp/stackchan-picoruby-debug/crash-analyze-servo.log`
- PC → `mrb_vm_exec` (mruby VM bytecode 実行)
- EXCVADDR=0x00000008 → nil の method table 参照と一致
- 上位 frame: `execute_task / mrb_task_run / picoruby_esp32 / app_main / main_task / vPortTaskWrapper`

application.rb の該当 region (行番号は commit e96a048 ベース):

```ruby
412   puts sprintf("[application] PY32 REG_VERSION = 0x%02X", ver_bytes.bytes[0])  ← 最後の output
413 end
414
415 puts "[debug] before PY32IOExpander.new"            ← 出ない (crash はここより前 or ここ)
416 py32 = PY32IOExpander.new(i2c)
417 puts "[debug] after PY32IOExpander.new"
418 py32.set_direction(0, true)
419 py32.set_pull_mode(0, true)
420 py32.digital_write(0, true)
421 Machine.delay_ms(200)
422 puts "[debug] PY32 GPIO0 enabled"
   ...
438 puts "[debug] led.show + brightness ok"
439 StackchanApp::Face::Neutral.new.draw(display)
440 puts "[application] LCD + LED cold-boot done"
```

bisect puts は **2 度目の upload で device に乗ってない**。upload が picomodem FILE_ACK で stall するため、現在 device に焼かれてる app.mrb は **bisect puts 入る前のバージョン** (commit dda8be3 時代の application.rb)。

## 仮説 (検証順)

### 仮説 A: 新 gem 追加で gem_init.c regenerate 漏れ

CLAUDE.md L268-270:
> `build_config/xtensa-esp-picoruby.rb` に新 gem 行追加 → `rake r2p2:setup` 必須。`rake r2p2:build_flash` 単独では `gem_init.c` / `picogem_init.c` が再生成されず新 gem が含まれない

Task 9 (bcd14d0) で `picoruby-scservo` を build_config に追加した後、`r2p2:full_rebuild` (= build_flash chain) は走らせたが **`r2p2:setup` は走らせてない**。これが gem_init.c の不整合を引き起こした可能性。

検証: `cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/picoruby && grep -n SCServo build/gem_init.c picogem_init.c` で SCServo / scservo / picoruby_scservo 系シンボルがちゃんと出力されてるか確認。出てなければ仮説 A 確定。

修復: `bundle exec rake r2p2:setup` (10〜20 分) → `bundle exec rake r2p2:full_rebuild SRC=...`。

### 仮説 B: 既存 gem の load order shift

picoruby-scservo を build_config に追加することで、既存の picoruby-py32-io-expander や picoruby-stackchan-led の load/init order が前後し、PY32IOExpander.new(i2c) が依存してる何か (i2c bus state? gem-internal constant?) が nil になる。

検証: build_config の `conf.gem` 順序を見て、scservo の行を **picoruby-uart 直後** などへ移動して再 build。crash 位置が変われば load order が原因と確定。

### 仮説 C: require 'uart' が i2c bus state を破壊

application.rb 13 行目で `require 'uart'` を追加。uart gem の load 時 init code が、後続の i2c.read を干渉する (例: I/O peripheral global state を触る)。

検証: `require 'uart'` / `require 'scservo'` を一旦コメントアウト → upload → boot。crash が消えれば require 追加が真因と確定。ただし servo 動かすには require 復活必須なので、別 fix が要る。

### 仮説 D: PY32IOExpander.new が Phase A 時代と挙動変わってる

picoruby-py32-io-expander 側に最近 commit が入ってるか? 別 repo (`../../bash0C7/picoruby-py32-io-expander/`) の git log -5 で確認。

## upload が FILE_ACK で stall する別問題

cold-boot crash とは別に、最後の wipe → upload で picomodem が `FILE_ACK got nil` / 途中 stall を起こした。

直近 log: `/tmp/stackchan-picoruby-debug/chain-upload.log`, `/tmp/stackchan-picoruby-debug/upload-bisect-retry.log`

cursor_replies=0 / dsr_replies=0 が出てるパターン (= device shell が ANSI [5n query に答えてへん) と、handshake 通過後の transfer mid-chunk stall パターンの両方を観測。

対処:
1. user 側 hardware reset 押下と同期して picomodem 起動 (window race を強制 align)
2. 旧 (動作確認済 commit dda8be3 時代の) application.rb に一旦戻して deploy chain を整えてから、bisect puts 入りに差し戻す

## 次セッションでの動作順 (推奨)

仮説 A の検証が最も投資対効果高い。順序:

1. **gem_init.c の現状確認**
   ```
   cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/picoruby/build
   grep -lr "SCServo\|scservo\|picoruby_scservo" .
   ```
2. **見つからなければ `bundle exec rake r2p2:setup`** (10〜20 分 subagent foreground)
3. **`bundle exec rake r2p2:full_rebuild SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb`**
4. boot capture → `[debug] before PY32IOExpander.new` 以降の puts がどこまで出るか観察
5. もし PY32IOExpander.new で crash したら仮説 A 棄却、PY32 gem 側を疑う
6. boot 通ったら debug puts を revert (commit e96a048 の puts 削除)、本筋の servo init が動くか確認

## R2P2-ESP32 firmware の現状

- 最新 build: 2026-05-19 11:22:54 (`App version: 0.2.15-16-gbcd14d0`)
- bcd14d0 は build_config に picoruby-scservo 追加した commit。**r2p2:setup は走らせてない**。

`../../bash0C7/R2P2-ESP32` 側で `git status` クリーン、commit bcd14d0 が HEAD。

## 関連 log / artifact

- `/tmp/stackchan-picoruby-debug/boot-after-require-fix.log` — crash 観測
- `/tmp/stackchan-picoruby-debug/crash-analyze-servo.log` — addr2line 解析
- `/tmp/stackchan-picoruby-debug/full-rebuild2.log` — 2 回目の full_rebuild (build/flash/wipe 成功、upload で FILE_ACK 取れずrace)
- `/tmp/stackchan-picoruby-debug/upload-bisect-retry.log` — bisect 用 upload stall
- `/tmp/stackchan-picoruby-debug/shell-state.log` — 35s capture で `[5n` 後 silent (post-wipe state)

## superseded

旧 handoff `docs/superpowers/handoff-2026-05-19-phase-b-task10-hardware-recovery.md` の hardware recovery 部分は完了 (USB replug + reset 物理ボタン → device 回復済)。本ハンドオフが新 task として superseded する。
