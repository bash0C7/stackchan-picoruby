# Claude Code plugins for stackchan-picoruby

このプロジェクトでの作業（PicoRuby ドライバ + host テスト、C mrbgem の ESP-IDF
component、BLE、ESP-IDF ビルド/flash）に対する Claude Code plugin の使いどころ。
plugin は user scope で導入済み（`~/.claude/plugins/`）。本リポジトリ固有の skill
群（`/stackchan-device-*`、`.claude/skills/`）が device 操作の主役で、plugin は
それを補完する。

## 活きている / 推奨

| plugin | 用途 | 状態 |
|---|---|---|
| `ruby-lsp` | `app/` `lib/` `pc/` `test/` の Ruby 補完・定義ジャンプ | 稼働中（`.ruby-lsp/` 生成済み） |
| `clangd-lsp` | C mrbgem port (`picoruby-ble/ports/esp32/*.c` 等) の補完・診断 | 利用可。`../../bash0C7/R2P2-ESP32/build/compile_commands.json` を clangd に渡せば BLE port / btstack の C を index できる |
| `superpowers` | spec / plan 駆動（`docs/superpowers/`） | 使用中 |
| `code-review` / `code-simplifier` | Ruby/C 差分レビュー・整理 | 随時 |
| `commit-commands` | commit 粒度の補助（1 invocation = 1 commit） | 随時 |
| `skill-creator` | `stackchan-device-*` skill の追加・改訂 | 随時 |
| `claude-md-management` | CLAUDE.md の肥大化・陳腐化チェック | 随時 |

## 欠けていて有用な候補

特に必須の欠落は無い。device 操作はプロジェクト固有 skill が網羅しており、
Ruby/C の LSP も揃っている。`clangd-lsp` は導入済みだが C 補完を活かすには
ビルド後に生成される `compile_commands.json` を参照させる一手間が要る点だけ
明示。新規 plugin の追加よりも既存の活用が現状の最適。
