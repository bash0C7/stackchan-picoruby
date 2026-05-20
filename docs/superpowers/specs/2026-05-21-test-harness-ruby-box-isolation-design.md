# Test Harness Ruby::Box Isolation Design

**Date:** 2026-05-21
**Builds on:** 既存 6 suite (root / `pc/stackchan-ble-client` / `mrbgems/picoruby-{stackchan-protocol, py32-io-expander, ili9342, stackchan-led}`)、各 suite は `bundle exec rake test` で同 process 内に全 test file を load
**Driver:** Claude Code (LLM coder) が修正→実行→修正ループで context を浪費している。global state を介した cross-file 影響を AI が毎回推論する必要があるのが主因。**構造的に「file A 編集時に file B を読まずに不変性を保証できる」状態にして、AI の cognitive load を物理的に削減する**。Ruby/CRuby 開発者の生産性 / runtime correctness は副次目的。

関連 memory: `feedback_structural_isolation_as_ai_cognitive_aid` (本 spec の評価基準を成文化)

## Section 1: 動機

### 現状の cross-file 汚染源 (棚卸し済)

| suite | test_helper LOC | 主要 global 汚染源 |
|---|---|---|
| `test/` (root) | 54 | `Object.const_set(:BLE, Class.new)`, `Object.const_set(:UART, Module.new)`, `module Machine`, `module ILI9342`, `RubyClassExtract.load_classes_from(APPLICATION_RB)` (tempfile 経由で application.rb 全 class を global に注入) |
| `mrbgems/picoruby-stackchan-protocol/test/` | 20 | `class ILI9342` (root は `module` で衝突)、`$LOAD_PATH` unshift、gem require |
| `mrbgems/picoruby-py32-io-expander/test/` | ~40 | `$LOADED_FEATURES << "i2c"`、test_helper 内に `FakeI2C` class 定義 |
| `mrbgems/picoruby-ili9342/test/` | ~25 | `$LOADED_FEATURES << "spi"/"gpio"`、`module Machine`、`class SPI/GPIO` (root と Machine 衝突) |
| `mrbgems/picoruby-stackchan-led/test/` | ~25 | test_helper 内に `FakePY32` class 定義 |
| `pc/stackchan-ble-client/test/` | 3 | bundler + test-unit + gem entry のみ (最薄) |

### Cross-suite vs Intra-suite

- **Cross-suite (suite を跨いだ汚染)**: 既に process 境界で隔離されてる。`bundle exec rake test` (root) と `cd mrbgems/X && rake test` は別 process。**今回の対象外**
- **Intra-suite (同 suite 内 test file 間)**: 同 process で global state を共有。test file 内で定義された Fake class / 修正された $globals / monkey-patch が他 test file から見える状態。**これが攻撃面**

### AI 視点での具体的痛点

1. `test/test_helper.rb` を編集すると、RubyClassExtract で extract される class 一覧が変わる → どの test に波及するか分からん
2. `test/foo_test.rb` で `class FakeWidget` を定義 (top-level) → `test/bar_test.rb` が同名で別実装の `FakeWidget` を必要としたとき、後勝ち / 競合検知不能
3. 1 suite 内の test 順序を test-unit が決定 (`test_files = FileList[...]`)、順序依存の bug が再現難
4. これらすべて「変えたら他に何が壊れるか」を AI が毎回推論する必要 → fix loop 浪費

### Success criterion

**「file A を編集したとき、AI が file B の中身を読まずに『file B は影響を受けない』と機械的に断言できる」** こと。Ruby/CRuby 慣習や runtime perf は副次。

## Section 2: Architecture

### Ruby::Box の選択理由

Ruby 4.0.3 で既に Ruby::Box が利用可能 (experimental flag)。`RUBY_BOX=1` 起動で:

- **constant / class 定義の isolation** (file A の `class FakeWidget` は file B から不可視)
- **monkey-patch isolation** (builtin class への変更が box 跨がへん)
- **global var isolation** (`$loaded_features`、その他 $globals が box ローカル)
- **top-level method isolation** (file top で `def foo; end` が file 跨がへん)

これが Success criterion をほぼ満たす。代替 (subprocess) は OS-level isolation で最強やが、起動コスト線形 (file 数 × Ruby+bundler+test-unit 起動) が長期的に workflow を遅らせる。Ruby::Box は単 process で済む。

experimental warning / native ext 互換は受容コスト。失敗時の撤退路は Section 4 で確保。

### Runner 構成

```
project root/
├─ Rakefile
│   ├─ task :test                # 既存。Rake::TestTask。撤退路として温存、リネームなし
│   └─ task :test_isolated       # 新規。sh "RUBY_BOX=1 bundle exec ruby -Ilib lib/test_isolator/runner_main.rb test/**/*_test.rb"
│
├─ lib/test_isolator/
│   ├─ runner_main.rb            # entry。RUBY_BOX=1 で起動された Ruby が呼ぶ。引数=test file glob
│   ├─ box_runner.rb             # 1 file = 1 Ruby::Box.new、box.require(file) で load、Test::Unit::AutoRunner を box 内 explicit invoke、結果 hash 返却
│   └─ result_aggregator.rb      # 各 file の {file, status, test_count, assertion_count, failure_count} を集約、unified report (stdout)、最終 exit code 決定
│
├─ test/test_isolator/
│   ├─ box_runner_test.rb        # box_runner unit test (box 外 plain test)
│   ├─ result_aggregator_test.rb # aggregator unit test
│   └─ runner_main_integration_test.rb  # 2-file fixture を実際に box runner で実行する integration
│
└─ (bin/ wrapper は作らない — Rakefile から sh で直叩き)
```

各 suite (mrbgems / pc) の Rakefile にも同形の `:test_isolated` task を追加 (cd context 維持、各 suite の test glob を渡す)。

### 重要な技術判断

1. **`RUBY_BOX=1` は process start envvar 必須** → 既存 `rake test` を **そのまま走らせると box は無効** (off 状態で旧挙動)。これで「rake test = legacy fallback」が自動で成立、明示的な off 切り替え不要
2. **runner_main.rb 内で Ruby::Box.new を file ごとに作成** → 各 file が独自 namespace
3. **test-unit autorun は box 内で動かない可能性大** (Test::Unit::AutoRunner は process 終了時 hook で自動起動するが、box 内に閉じ込められると `at_exit` の効果が box ローカル) → box 内で `Test::Unit::AutoRunner.run` を**明示 invoke**、結果を controller (= runner_main) に返す pattern
4. **bundler / gem は root box で load** → native ext (`serialport`, `ruby-termios`, `uart`) は root box で 1 回 load されて全 box から共有可能。これは「外部 read-only client」として扱うので box の理念に反しない (native ext 自体が mutable global state を持つ場合は別途検討要)
5. **test_helper.rb の require は各 box 内で実行** → suite ごとの shim (`module Machine`, `class ILI9342` 等) は box ローカルに閉じる。これが本 spec の中核効用

## Section 3: File Migration Plan

各 suite を **薄→厚** で適用。各 suite = 1 commit。

| 順 | suite | 想定難度 | 1 commit 単位 | 期待 status |
|---|---|---|---|---|
| 1 | `pc/stackchan-ble-client/test/` | 低 (test_helper 3 行) | runner 3 ファイル新規追加 + ble-client `:test_isolated` task 追加 + `bundle exec rake test_isolated` green | full green |
| 2 | `mrbgems/picoruby-stackchan-led/test/` | 中 (FakePY32 が test_helper top-level) | suite Rakefile に task 追加 + green | full green |
| 3 | `mrbgems/picoruby-py32-io-expander/test/` | 中 (FakeI2C top-level + `$LOADED_FEATURES`) | 同上 | full green |
| 4 | `mrbgems/picoruby-ili9342/test/` | 中 (Machine module / SPI / GPIO empty class) | 同上 | full green |
| 5 | `mrbgems/picoruby-stackchan-protocol/test/` | 中 (ILI9342 class / fake_display 等) | 同上 | full green |
| 6 | `test/` (root) | 高 (RubyClassExtract で application.rb 全 class を tempfile 経由 `load`、Machine / ILI9342 / BLE / UART 等大量 shim) | 同上、必要なら RubyClassExtract 側を box-friendly に微修正 | full green |

### Commit grain

- 1 suite = 1 commit (per-suite revert 可能)
- commit message テンプレ:
  ```
  feat(test-harness): isolate <suite> tests via Ruby::Box

  Each test file in <path>/test/ now loads into its own Ruby::Box,
  preventing cross-file constant / monkey-patch / $global pollution
  within this suite. Run with `bundle exec rake test_isolated` (suite-local).

  Legacy `rake test` continues to work for rollback (RUBY_BOX not set).

  Rollback: revert this commit to restore the shared-process test
  loading for <suite> only; other suites' box isolation remains.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```

### Per-suite verification (各 commit 直前に必須)

1. `bundle exec rake test` (legacy) で **当該 suite + 全 suite** が full green
2. `bundle exec rake test_isolated` で **当該 suite が full green** (新規導入分)
3. 各 suite の test count が legacy と isolated で **一致**

不一致 / 失敗時:
- 当該 suite の commit を作らへん
- 原因が「box 内で test-unit autorun が走らへん」等の runner 設計問題なら runner 側を修正 (runner 自体は別 commit 単位、commit 1 で landing 済)
- 原因が「suite 固有の shim が box と相性悪い」なら suite 固有対応を加え、それも commit に含める
- 解決不能なら **その suite だけ skip** して次の suite に進む (本 spec の Out of scope: 全 suite 強制適用は要求しない、6 suite のうち導入できたものだけ box 化、残りは legacy 維持)

### Branch + 単独 commit 1 (runner 導入) を最初に landing

suite 1 (ble-client) の commit には **runner 3 ファイル (`lib/test_isolator/*`) と root `Rakefile` への `:test_isolated` task 追加** を含める。これで suite 2 以降は「自 suite Rakefile に task 追加」だけで進める。

## Section 4: Rollback Design (3 層)

| 層 | trigger 例 | 手順 |
|---|---|---|
| **L1 / branch 全廃棄** | Box 自体が project に合わへん (例: 全 suite で test-unit autorun が動かん / bundler が箱壊し) と判明 | `git checkout main && git branch -D feat/test-harness-ruby-box-isolation`。main の `rake test` 旧挙動が temporal にそのまま生きてる |
| **L2 / suite 単独撤退** | suite N の box 化で詰む (例: root suite の RubyClassExtract が box と本質的に相性悪い) | `git revert <suite-N-commit>` — runner と他 suite の box 化は保持。suite N は legacy `rake test` で動き続ける |
| **L3 / runtime fallback** | 任意時点で box 経由が不安定、すぐ動かしたい | `bundle exec rake test` (envvar 設定なしで起動 → box 無効 → 旧挙動)。 user 操作だけで即 fallback |

各 L について **対応 commit に「rollback: …」セクションを必ず書く** こと。後日の self / 他者操作で取りうる手段を verify せず即決できる状態を保証。

## Section 5: YAGNI Scope

### 含める (Definition of Done)

- (a) `lib/test_isolator/runner_main.rb`、`box_runner.rb`、`result_aggregator.rb` (合計 200-400 LOC 目安、TDD で host test カバー — runner 自身の test は box 外 plain test で `test/test_isolator/` 配下に置く、再帰的 box 依存を避ける)
- (b) root `Rakefile` に `:test_isolated` task 追加 (`sh "RUBY_BOX=1 bundle exec ruby -Ilib lib/test_isolator/runner_main.rb #{test_glob}"`)
- (c) 6 suite (うち適用可能なもの) の各 Rakefile に `:test_isolated` task 追加
- (d) `bundle exec rake test_isolated` が **root および各 suite で full green** (box 内で legacy と同じ test count + assertion count)
- (e) 各 suite commit に rollback 手順を message として明記
- (f) 本 spec doc を `docs/superpowers/specs/2026-05-21-test-harness-ruby-box-isolation-design.md` として commit、README または CLAUDE.md から 1 行 cross-ref

### 含めない (Out of scope)

- **並列実行** — Ractor / `xargs -P` での parallel box execution。性能要件で要求されてから別 spec
- **test 順序ランダム化** — box 内 / 跨ぎ両方とも本 spec の対象外
- **CI integration** — GitHub Actions / 任意 CI への `rake test_isolated` 連結。手動運用で問題出てから別 spec
- **出力フォーマット改善** — TAP / JSON / JUnit XML 等。stdout の human-readable text aggregate のみ
- **既存 `rake test` の deprecation 警告** — 撤退路温存のため警告は出さん
- **global state lint** — 「実は box 外で global 触ってる」を検出する静的解析。必要性が顕在化してから別 spec
- **全 suite 強制適用** — 6 suite すべての box 化が DoD 必須ではない。box 化困難な suite (例: root suite で RubyClassExtract が本質的非互換と判明したら) は legacy のままで本 spec は完了とする
- **mrbgem on-device test の box 化** — PicoRuby に Ruby::Box は無い、host test のみ対象
- **calibration plan の Tasks 15-17 implementation** — 本 branch では触らへん、test harness 着地後に `feat/servo-tuning-and-test-fix` に戻って続行

## Section 6: Definition of Done

| # | 項目 | 検証手段 |
|--:|---|---|
| 1 | `lib/test_isolator/{runner_main,box_runner,result_aggregator}.rb` 実装、box 外 plain test で各 unit が green | host test、`bundle exec ruby -Ilib -Itest test/test_isolator/*_test.rb` |
| 2 | root `Rakefile` に `:test_isolated` task 追加、`bundle exec rake test_isolated` が起動 | rake -T 出力 + 起動成功 |
| 3 | suite 1 (ble-client) `:test_isolated` 経由で **legacy と同 test count / 0 failure** | `bundle exec rake test_isolated` + 出力 diff |
| 4 | suite 2-5 (mrbgem 4 つ) 同 (各 suite 単独 commit) | 同 |
| 5 | suite 6 (root) 同。RubyClassExtract が box-compatible (tempfile load が box 内で完結) — または Section 5 Out-of-scope ルールに従い root suite だけ legacy 維持で本 spec 完了とする | 同、または legacy 維持判断の git log 記録 |
| 6 | 各 suite commit message に rollback 手順記載 | `git log --grep="Rollback:"` で全 suite 該当行 hit |
| 7 | 本 spec doc が commit、CLAUDE.md (root) または README から 1 行 cross-ref | grep |
| 8 | 撤退テスト: branch 上で `git revert <suite-N-commit>` → suite N legacy 復活 + 他 suite isolated 維持を verify | 1 suite で実演 (rollback して即戻す) |

DoD #5 (root suite) が達成不能な場合: その suite を **legacy のまま** 残し、その旨を spec 本体 (Out of scope) に書き加えて完了とする (本 spec の Section 5 で既に明記済)。

## Section 7: 関連 memory / spec

### 駆動 memory

- `feedback_structural_isolation_as_ai_cognitive_aid` — 本 spec の評価基準
- `feedback_main_as_orchestrator` — main session は判断、subagent に実装委譲 (本 plan 実行時の役割分担)
- `feedback_final_review_catches_what_per_task_misses` — 最後の全 suite review skip 禁止
- `feedback_subagent_no_code_workaround_during_verify` — verify subagent に production code 改変禁止 (各 commit 前 verify で必須)

### 関連 spec

- `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md` — 本作業中の plan、test harness 完了後に continuation (Tasks 15-17)
- `docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md` — calibration の根元 spec

## Section 8: 撤退手順詳細 (Quick Reference)

### branch 全廃棄

```bash
git checkout main
git branch -D feat/test-harness-ruby-box-isolation
# Tasks 15-17 続行する場合:
git checkout feat/servo-tuning-and-test-fix
```

### suite 単独 revert (例: root suite)

```bash
git revert <root-suite-commit-sha>
# 他 suite の box 化は残る、root suite だけ legacy
bundle exec rake test          # legacy root suite + 全 suite green を verify
bundle exec rake test_isolated # 残り isolated suite green を verify
```

### Runtime fallback (即時)

```bash
bundle exec rake test          # envvar RUBY_BOX 設定なし → box 無効 → 旧挙動
```
