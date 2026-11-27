# stackchan-picoruby

M5Stack CoreS3のStackChan AIデスクトップロボットをPicoRuby/R2P2-ESP32で動かす個人プロジェクト。機能・セットアップ・既知問題は`README.md`、現在地は`HANDOFF.md`を参照する。

## アーキテクチャ境界

- **StackChan固有の隔離**: StackChanを知るのはこのrepoだけ（`build_config/`・`mrbgems/`・`apps/`）。`picoruby`・`R2P2-ESP32`・`R2P2-darwin`・driver gem・`suppify`は横断層であり、platform契約（build_config受け口、`APP_DIR`等のenv、HAL/portのheader）にconformする形でだけ関わる。横断層の修正はStackChan非依存の一般修正として対象repoに出す。
- **核心**: BLE経由でサーボに絶対位置（normalized 0..100+方向key）を指定して期待通り動かすこと。Face/LED/blinkは装飾。
- **ランタイム境界**: CRubyで動くのは`Rakefile`・`lib/`・`acceptance/`・`test/picotest/harness.rb`・`suppify`・`test-host/`のみ。Mac常駐と手動script（`tools/*.rb`）はMac VM（`vendor/R2P2-darwin/build/host/bin/picoruby`）で動かす。
- **ホスト検証の原則**: BLE等のハードウェア実体は薄いadapterに隔離し、ロジックは素のclassに出してhostで回帰検出する。無いharnessやfakeは新設し、実機のみで確認する範囲をadapter数行に限定する。

## 主要コマンド

```sh
bundle exec rake test                        # rigor:check → picotest全suite (host VM)
SUITE=pc FILTER=central bundle exec rake test
bundle exec rake test:host                   # CRuby側テスト (test-host/)
bundle exec rake picotest:build              # picoruby更新後のhost VM再build
bundle exec rake r2p2:boards                 # CoreS3のUSB serial・port・lock確認 (port非open)
bundle exec rake r2p2:qemu_check             # 実機に触れずQEMUでboot・gem load・app評価を検証
```

## 実機・ビルド・シミュレータ運用

- 実機に載せるfirmwareは信頼のおける1種類のみ。比較・確認のために別firmwareを焼かない。実機で落ちたら実機で試し直さず、boot logを証拠にQEMU（`r2p2:qemu_check`）かhostで再現して直す。
- firmware・gem・app・BLE linkを変えるbranchは、`acceptance/lock.yml`にshaを書いて`/stackchan-device-acceptance`を通し、`acceptance/results/`が`verdict: pass`になるまでmergeしない。
- 実機・firmware・Simulator操作はSkill経由で行う（main contextからの直接`rake r2p2:*`実機操作、生`cat /dev/cu.usbmodem*`、`idf.py flash`直叩き、`build/repos`の`rm -rf`、未push pinの`git push`は`.claude/settings.json`のPreToolUse hookがブロックする）。

| 用途 | Skill | 起動 |
|---|---|---|
| app反映・反復検証・cold-recovery・wipe・reset・BLE/face smoke | `stackchan-device-app` | 自動/手動 |
| boot検証・serial capture・Guru Meditation解析・flash identity | `stackchan-device-diagnose` | 自動/手動 |
| iOS/watchOS VM build+Xcode MCP Simulator batch検証 | `stackchan-apple-simulator` | 自動/手動 |
| firmware setup / build-flash / full-rebuild / qemu-check | `/stackchan-device-firmware` | 手動のみ |
| merge前の実機acceptance一式（deploy / app / check / darwin） | `/stackchan-device-acceptance` | 手動のみ |
| `picoruby-ble` lineage切替・firmware `picoruby`のupstream rebase | `/stackchan-picoruby-ble-upgrade` | 手動のみ |

## ドキュメント・知識の配置

- **この`CLAUDE.md`**: 全セッション共通かつコードから読めない規約・境界のみ。
- **`.claude/rules/`**: 対象ディレクトリ編集時に自動ロードされる領域別の実測制約（PicoRuby VM差、CoreS3ハードウェア、BLEプロトコル、Apple apps、Mac/launchd、test harness、deploy/QEMU、hooks）。
- **`HANDOFF.md`**: 次セッションへの現在地引き継ぎのみ（上書き運用、恒久知識は書かない）。
- **Auto Memory（`MEMORY.md`）**: Claudeが自動管理するセッション横断のfeedback・嗜好インデックス（技術仕様は書かない）。
- **spec/plan**: repoの`docs/superpowers/{specs,plans}/`に置いてcommitする。実行済planと実装が先へ進んだspecはObsidian vaultの`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/ObsidianVault/02_dev_docs/stackchan-picoruby/{plans,specs}/`へ移してrepoから外す。
- **review・調査・計測証拠**: 上記vaultの`review/`に置く（PR #427関連は隣の`picoruby-ble-esp32-port/`）。記事・WIPメモはesa（team `ksbrb`、カテゴリ`ｽﾀｯｸﾁｬﾝ`）。未着手タスクはGitHub issue。

## repo固有のコード規約例外

- コメント禁止規律の例外はtoolchain指示（magic comment、suppifyの`#:`型注釈、rigor/steep指示）と`mrbgems/picoruby-stackchan-robot/mrblib/stackchan-robot/boot.rb`の`# REQUIRED FOR PY32 COLD-BOOT`マーカーのみ。
