# CRuby は rake を動かす所だけにする

## 目的

この repo で CRuby が動くのを、`rake` の process (Rakefile と、Rakefile が process 内で読む `lib/`・`acceptance/`・`test/picotest/harness.rb`・suppify) と、その rake が自分の code を検査する `test-host/` だけにする。Mac 側で常駐する仕事と手で起こす script は、PicoRuby の Mac VM で動かす。

## 洗い出し

### PicoRuby に移すもの

| 対象 | 今の起動 | CRuby に頼っとる所 |
|---|---|---|
| `pc/sidecar/{sidecar,service}.rb` | launchd が `RbConfig.ruby` + `pc/stackchan/Gemfile` で常駐させる。daemon が `druby://127.0.0.1:8788` で `respond` / `synthesize` を呼ぶ | rb-foundation-model-mac (`Session.new(instructions:)` を使い回す)、stdlib の DRb server、`Timeout` |
| `pc/stackchan/lib/stackchan/voice/{tts,wav,ulaw}.rb` と `pc/stackchan/{Gemfile,Rakefile,test}` | sidecar が `require` する。test は手で `cd pc/stackchan && rake test` | `Open3.capture3` で `say` → `afconvert`、`Tempfile`、`Struct`、test-unit |
| `tools/latency_summary.rb` | `tools/latency_baseline.zsh` と `tools/face_profile.zsh` が `ruby` で起動。test は `test-host/latency_summary_test.rb` | stdlib だけ |
| `tools/ambient_demo.rb`、`tools/phrase_announcer.rb` | 手で `ruby` 起動し、`bin/stackchan` を `system` で呼ぶ。test は `test-host/ambient_demo_test.rb` | `system` |

### rake の process に入れるもの

| 対象 | 今の起動 | 入れる先 |
|---|---|---|
| `tools/test_must_fail_on_revert.rb` | `tools/hooks/pre_push_guard.sh` が `ruby` で起動 | `lib/` に移して rake task にし、hook は `bundle exec rake` を呼ぶ |
| `tools/aot/kernels_build.rb` と、それが `ruby suppify.rb` で起こす suppify | `aot:esp32` が `sh "ruby", …`、`tools/aot_host_vm.sh` が `ruby` で起動 | `lib/` に移して `aot:esp32` / `aot:host` が process 内で呼ぶ。suppify は `build/aot/suppify/lib` を `require` して `Suppify::CLI.run` を呼ぶ (suppify の実行時の依存は無く、process を起こすのは spinel の binary だけ) |
| `tools/aot/syntax_check_mcu.sh` の `ruby -e` | 手で起動 | rake task にする |

### 消すもの

- Claude Code の Stop hook (`tools/hooks/japanese_reply_guard.rb` と `.claude/settings.json` の `Stop`)：返事の言語は利用者の設定が決めていて、StackChan の仕事ではない。
- root `Gemfile` の `uart`：使っていた `lib/deploy/shell_recovery.rb` は消えている (`apps/robot/app.rb` の `require 'uart'` は firmware の gem)。
- `pc/stackchan/` (gem・Gemfile・Rakefile・test ごと)。

### CRuby に残るもの

- `Rakefile`、`lib/*`、`acceptance/*`、`test/picotest/harness.rb`、`build_config/*.rb` (picoruby の rake が評価する)、process 内の suppify。
- `test-host/*`：rake が動かす CRuby の code の test。`rake test:host` と revert guard が起動する。
- rigor：`rake test` の中で rake 側の code を型検査する。
- spinel の `make`：build の途中で `ruby tools/gen_respond_to_tables.rb` が `lib/spinel_rt_responds_generated.h` を作る。spinel には手を入れない。
- picoruby・R2P2 の build (`rake -C …`)、CI の `ruby-full` + `bundle exec rake`。
- `tools/check_deps_pushed.sh` (push guard の pin 検査) は shell で、CRuby を使わない。

## 確かめた事実

- Mac VM で動く：`IO.popen("cmd")` (文字列だけ。配列は `TypeError`)、`io.pid`、`File.open(path, "rb")` で binary を読む、`File.foreach`、`require "json"`、日本語の文字範囲の Regexp。picoruby-drb の server は `DRb.start_service(uri, front)` と `DRb.thread.join` (daemon が同じ形で動いている)。
- Mac VM に無い：`Process`、`Struct`、`Tempfile`、`Open3`、`system`。
- `say -o x.wav --file-format=WAVE --data-format=LEI16@8000 <text>` が 8 kHz・mono・Int16 の WAV を直接出す (`afinfo` で確認)。`afconvert` は要らない。
- `bash0C7/picoruby-foundation-model` が Foundation Models を PicoRuby に出している。今の API は `FoundationModel.generate(prompt)` だけで、instructions・会話の続き・timeout が無い。Swift の側は `DispatchSemaphore` で応答を待つ。Xcode の Swift は 6.4.2 で、gem が要る `@c` (6.3) を持つ。
- Mac VM の heap は `picoruby-bin-picoruby` の `HEAP_SIZE` で 6.4 MB 固定。

## 形

sidecar は別 process のまま、中身を PicoRuby にする。daemon・controller gem・iOS / watchOS は変えない。daemon から見える `respond(prompt, ctx)` と `synthesize(text, gain, rate)`、DRb の port、`STUB=1` の振る舞いは今のまま。生成や `say` が sidecar の VM を止めても、daemon の VM は止まらない。

### picoruby-foundation-model (bash0C7/picoruby-foundation-model、StackChan を知らない一般の追加)

- `FoundationModel::Session.new(instructions: nil)`：Swift 側に `LanguageModelSession(model:instructions:)` を持ち、C には不透明な handle だけを渡す。会話は session に溜まる。
- `Session#respond(prompt, timeout_ms: nil)`：今の `generate` と同じく semaphore で待つ。`DispatchSemaphore.wait(timeout:)` が切れたら生成の `Task` を cancel して `FoundationModel::TimeoutError`、生成の失敗は `FoundationModel::GenerationError`。
- `FoundationModel.generate(prompt)` はそのまま残す。
- example の binary で、instructions が効くこと、2 回目の問いが 1 回目を覚えていること、timeout が効くことを確かめる。

### stackchan-picoruby

- `build_config/darwin-stackchan-pc.rb` に picoruby-foundation-model を足す。daemon と sidecar は同じ Mac VM を使う。`acceptance/lock.yml` の `darwin` に picoruby-foundation-model の sha を足す。
- `pc/sidecar/` を PicoRuby の source にする。`sidecar.rb` が `service.rb` と voice の source を `load` し、`DRb.start_service` → `DRb.thread.join`。
  - `Service`：persona を instructions にした `FoundationModel::Session` を 1 つ持ち、ctx から状況の文を組んで `respond(…, timeout_ms:)` を呼ぶ。失敗と timeout は stderr に残して `nil`。`STUB=1` の返事と音声は今と同じ形。
  - `Tts`：`say` を `IO.popen` の文字列 command で起こし、終わるまで読む。終了 status は command の末尾に足した `echo exit:$?` から取る。WAV は `STACKCHAN_LOGDIR` の下の一時 file に書かせ、読んだら消す。
  - `Wav` (RIFF を読み、8 kHz・mono・PCM16 を確かめる。`Struct` を使わない) と `Ulaw` (gain をかけて μ-law に)。
  - test は picotest の新しい suite `sidecar` として `rake test` に足す。Foundation Models と `say` は注入した fake で置き換える。
- `lib/launch_agent.rb` の `sidecar_job` は `ruby:`・`BUNDLE_GEMFILE`・`RUBYOPT` をやめて Mac VM で `pc/sidecar/sidecar.rb` を起こす。`lib/pc_lifecycle.rb` と Rakefile から `RbConfig.ruby` の受け渡しを消す。
- tools：`latency_summary`、`ambient_demo`、`phrase_announcer` は Mac VM で走る script にし、`bin/stackchan` は `IO.popen` で呼ぶ。test は `test-host/` から picotest の suite `tools` に移す。zsh の呼び出しを Mac VM に替える。
- revert guard：`lib/` に移した本体を rake task `guard:revert` から呼ぶ。`pre_push_guard.sh` は `bundle exec rake guard:revert` を呼ぶ。`test-host/test_must_fail_on_revert_test.rb` は移した本体を見る。
- AOT：`kernels_build` を `lib/` に移し、suppify を process 内で呼ぶ。`tools/aot_host_vm.sh` は rake task を呼ぶ。`syntax_check_mcu.sh` の `ruby -e` を rake task にする。
- doc：CLAUDE.md (PC glue の「AI と TTS は CRuby sidecar」、テストの suite 一覧)、README、`pc/stackchan-pico/README.md`、`aot/README.md`、HANDOFF.md。

## 順序

1. picoruby-foundation-model に `Session` と timeout を足し、example で確かめる。
2. sidecar を PicoRuby にし、picotest の suite を足す。Mac VM の config と launchd の job を替える。`pc/stackchan/` を消す。
3. tools を移す。Stop hook と `Gemfile` の `uart` を消す。
4. revert guard と AOT の script を rake の process に入れる。
5. doc を直す。

1 段ごとに commit する。

## 確かめ方

- `bundle exec rake test` (新しい suite を含む) と `bundle exec rake test:host`。
- `rake pc:vm_build` → `pc:app_bundle` → `pc:up`。sidecar の job が Mac VM で走り、CRuby の process が常駐していない (`launchctl print` の program と `ps`)。
- robot に対して `bin/stackchan chat こんにちは` と `bin/stackchan say …`：返事が返り、robot が話す (聞くのは owner)。`STUB=1` の `pc:up` でも stub の返事が返る。
- `aot:esp32` が今と同じ kernel を出す (生成物の digest を変更前と比べる)。firmware は変わらないので焼かない。
- revert guard は実際の `git push` で動かす。
- `acceptance:check` を 1 回通し、`verdict: pass` の report を残す。
