# CRuby は rake を動かす所だけにする

## 目的

この repo で CRuby が動くのを、`rake` の process (Rakefile と、Rakefile が process 内で読む `lib/`・`acceptance/`・`test/picotest/harness.rb`) と、その rake が自分の code を検査する `test-host/` だけにする。それ以外の Mac 側の仕事は PicoRuby の Mac VM (`vendor/R2P2-darwin/build/host/bin/picoruby`) で動かす。

## 洗い出し

### PicoRuby に移すもの

| 対象 | 今の起動 | CRuby に頼っとる所 |
|---|---|---|
| `pc/sidecar/{sidecar,service}.rb` | launchd が `RbConfig.ruby` + `pc/stackchan/Gemfile` で常駐させる。daemon が `druby://127.0.0.1:8788` で `respond` / `synthesize` を呼ぶ | rb-foundation-model-mac (`Session.new(instructions:)` を使い回す)、stdlib の DRb server、`Timeout` |
| `pc/stackchan/lib/stackchan/voice/{tts,wav,ulaw}.rb` と `pc/stackchan/{Gemfile,Rakefile,test}` | sidecar が `require` する。test は手で `cd pc/stackchan && rake test` | `Open3.capture3` で `say` → `afconvert`、`Tempfile`、`Struct`、test-unit |
| `tools/hooks/japanese_reply_guard.rb` | Claude Code の Stop hook が `ruby` で起動 | JSON、`\p{Hiragana}` 等の Regexp |
| `tools/latency_summary.rb` | `tools/latency_baseline.zsh` と `tools/face_profile.zsh` が `ruby` で起動。test は `test-host/latency_summary_test.rb` | stdlib だけ |
| `tools/ambient_demo.rb`、`tools/phrase_announcer.rb` | 手で `ruby` 起動し、`bin/stackchan` を `system` で呼ぶ。test は `test-host/ambient_demo_test.rb` | `system` |

### rake の process に入れるもの (CRuby のまま、別 process の `ruby` をやめる)

| 対象 | 今の起動 | 入れる先 |
|---|---|---|
| `tools/test_must_fail_on_revert.rb` | `tools/hooks/pre_push_guard.sh` が `ruby` で起動 | `lib/` に移して rake task にし、hook は `bundle exec rake` を呼ぶ |
| `tools/aot/kernels_build.rb` | `aot:esp32` が `sh "ruby", …`、`tools/aot_host_vm.sh` が `ruby` で起動 | `lib/` に移して `aot:esp32` / `aot:host` が process 内で呼ぶ |
| `tools/aot/syntax_check_mcu.sh` の `ruby -e` | 手で起動 | rake task にする |

### 消すもの

- root `Gemfile` の `uart`。使っていた `lib/deploy/shell_recovery.rb` は消えている (CRuby 側に `require "uart"` は無い。`apps/robot/app.rb` の `require 'uart'` は firmware の gem)。
- `pc/sidecar/`、`pc/stackchan/` (gem・Gemfile・Rakefile・test ごと)。

### CRuby に残るもの

- `Rakefile`、`lib/*`、`acceptance/*`、`test/picotest/harness.rb`、`build_config/*.rb` (picoruby の rake が評価する)。
- `test-host/*`：rake が動かす CRuby の code の test。`rake test:host` が起動する。
- rigor：`rake test` の中で rake 側の code を型検査する。
- suppify (bash0C7/suppify の tool) と picoruby・R2P2 の build の rake：rake が build の一段として起動する、別 repo の tool。
- CI の `ruby-full` + `bundle exec rake`。

## 確かめた事実

- Mac VM で動く：`IO.popen("cmd")` (文字列だけ。配列は `TypeError`)、`io.pid`、`File.open(path, "rb")` で binary を読む、`File.foreach`、`require "json"`、日本語の文字範囲の Regexp (`/[ぁ-んァ-ヶ一-龠]/`)。
- Mac VM に無い：`Process` (mruby-process は `vendor/R2P2-darwin/vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-process` にあり、`waitpid` と `Process::WNOHANG` を持つ)、`Struct`、`Tempfile`、`Open3`、`system`。picoruby-regexp は `\p{...}` を compile 時に `RegexpError` にする。
- `say -o x.wav --file-format=WAVE --data-format=LEI16@8000 <text>` が 8 kHz・mono・Int16 の WAV を直接出す (`afinfo` で確認)。`afconvert` は要らない。
- `bash0C7/picoruby-foundation-model` が Foundation Models を PicoRuby に出している。今の API は `FoundationModel.generate(prompt)` だけで、instructions・会話の続き・timeout が無く、Swift の側が `DispatchSemaphore` で応答を待つ間、VM 全体が止まる。Xcode の Swift は 6.4.2 で、gem が要る `@c` (6.3) を持つ。
- daemon は voice を `@engine.unlocked { v.respond(…) }` で呼び、待つ間もほかの Task (250 ms の tick、1 s の keepalive) が回る。今は DRb の socket 待ちがその隙間を作っている。

## 形

sidecar の process をなくし、voice を daemon の VM の中の object にする。`Session` が voice に求めるのは `respond(prompt, ctx)` と `synthesize(text, gain, rate)` の 2 つのまま。

### picoruby-foundation-model (bash0C7/picoruby-foundation-model、StackChan を知らない一般の追加)

- `FoundationModel::Session.new(instructions: nil)`：Swift 側に `LanguageModelSession(model:instructions:)` を持ち、C には不透明な handle だけを渡す。会話は session に溜まる。
- `Session#respond(prompt, timeout_ms: nil)`：Swift の `Task` で生成を始めて直ちに返り、Ruby が `sleep_ms` を挟んで完了を問う。待つ間ほかの Task が走る。`timeout_ms` を過ぎたら生成を cancel して `FoundationModel::TimeoutError`、失敗は `FoundationModel::GenerationError`。
- `FoundationModel.generate(prompt)` はそのまま残す。
- example の binary で、instructions が効くこと、2 回目の問いが 1 回目を覚えていること、生成中に別 Task が回り続けること、timeout が効くことを確かめる。

### stackchan-picoruby

- 新しい gem `mrbgems/picoruby-stackchan-voice` (firmware と iOS / watchOS には入れない。Mac daemon が source で `load` する)：
  - `Wav` (RIFF を読み、8 kHz・mono・PCM16 を確かめる。`Struct` を使わない)、`Ulaw` (gain をかけて μ-law に)。
  - `Tts`：`say` を `IO.popen` の文字列 command で起こし、`Process.waitpid(pid, Process::WNOHANG)` を `sleep_ms` を挟んで問う。WAV は `STACKCHAN_LOGDIR` の下の一時 file に書かせ、読んだら消す。command の実行は注入できる形にする。
  - `Chat`：persona を instructions にした `FoundationModel::Session` を 1 つ持ち、ctx から状況の文を組み、`respond(…, timeout_ms:)` を呼ぶ。失敗と timeout は log に残して `nil`。
  - `Stub`：`STUB=1` の時の voice。返事と音声は sidecar の stub と同じ形。
  - test は picotest (`test/*_test.rb`) を新しい suite として `rake test` に足す。
- Mac VM の config (`build_config/darwin-stackchan-pc.rb`) に picoruby-foundation-model と mruby-process を足す。`acceptance/lock.yml` の `darwin` に picoruby-foundation-model の sha を足す。
- `Controller#serve` は `sidecar_uri:` の代わりに `voice:` を受け、`boot_daemon.rb` が voice を組んで渡す。`Daemon` の `sidecar_uri` と DRb の client を消す。
- `lib/launch_agent.rb` の `sidecar_job`、`lib/pc_lifecycle.rb` の sidecar の起動と 15 s の待ち、Rakefile の `STACKCHAN_SIDECAR_PORT` を消す。`STUB=1` は daemon の引数で渡す。
- tools：
  - `japanese_reply_guard` は PicoRuby の script と、Mac VM を起こす sh にする。code fence は Regexp でなく `String#index` で取り除く。VM が無ければ stderr に `rake pc:vm_build` を促す行を出して exit 1 (Claude を止めない)。
  - `latency_summary`、`ambient_demo`、`phrase_announcer` は Mac VM で走る script にする。`bin/stackchan` は `IO.popen` で呼ぶ。test は `test-host/` から picotest の suite に移す。
- doc：CLAUDE.md (PC glue の「AI と TTS は CRuby sidecar」、launchd の節の sidecar priming、テストの suite 一覧)、README、`pc/stackchan-pico/README.md`、HANDOFF.md。

## 順序

1. picoruby-foundation-model に `Session` と待たない `respond` を足し、example で確かめる。
2. `picoruby-stackchan-voice` を picotest と一緒に作る。
3. Mac VM の config を変えて `pc:vm_build`、daemon を voice に繋ぎ替え、sidecar と launchd の job を消す。
4. tools を移す。`Gemfile` から `uart` を消す。
5. doc を直す。

1 段ごとに commit する。

## 確かめ方

- `bundle exec rake test` (新しい suite を含む) と `bundle exec rake test:host`。
- `rake pc:vm_build` → `pc:app_bundle` → `pc:up`。`launchctl list` に sidecar の job が無く、CRuby の process が常駐していない。
- robot に対して `bin/stackchan chat こんにちは` と `bin/stackchan say …`：返事が返り、robot が話す (聞くのは owner)。chat の間も daemon log に keepalive の `touches` が 1 s ごとに出続ける。
- controller gem を変えるので、iOS / watchOS を Simulator で `status` まで流す (`/stackchan-apple-simulator`)。
- firmware は変わらないので焼かない。`acceptance:check` を 1 回通し、`verdict: pass` の report を残す。
