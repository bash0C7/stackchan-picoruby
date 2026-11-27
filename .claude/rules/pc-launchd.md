---
paths:
  - "pc/**"
  - "apps/mac/**"
  - "lib/pc_lifecycle.rb"
  - "lib/launch_agent.rb"
  - "build_config/darwin-stackchan-pc.rb"
  - "Gemfile"
  - "Rakefile"
---

# Macアプリ・Sidecar・launchd制約

## Mac構成とSidecar

- `apps/mac/app.rb`は`App = StackChan.controller do |c| … end` 1つだけのDSLファイル（`c.action`がCLI verb、`c.hold`、`c.on_reply`）。
- `pc/stackchan-pico`はlaunchdとprocessの接着のみ: `boot_daemon.rb`がcontroller gemと`apps/mac/app.rb`をsourceで`load`して`App.serve`、`boot_cli.rb`が`cli.rb`と`calibration.rb`のみ`load`してCLI起動、`bin/stackchan`、`StackchanPico-Info.plist`（launchd plistは`lib/launch_agent.rb`生成）、`fake_ble.rb`（`BLE_FAKE=1`）、`drb_eintr_retry.rb`。
- AIとTTSは`pc/sidecar`に隔離しdRuby橋渡し。sidecarはdaemonと同じapp bundleのVMで別processとしてlaunchd起動し、`picoruby-foundation-model`（`build_config/darwin-stackchan-pc.rb`でbranch fetch、shaは`acceptance/lock.yml`の`darwin.repos`）の`FoundationModel::Session`で返事を作り、`say`の8kHz WAVをμ-law化する。
- `hal-task-darwin`はMac config（`build_config/darwin-stackchan-pc.rb`）にだけ入れる。

## Build・依存の罠

- **Swiftly PATH競合**: `pc:vm_build`はPATHの`swift`で`picoruby-ble` Swift packageをbuildする。`~/.swiftly/bin`がXcodeの`/usr/bin/swift`より先に来ると`unknown argument: '-target-arch-variant'`で落ちる。Xcodeの`swift`が先に来るPATHで流す。
- **worktree symlink制限**: `pc:vm_build`は`vendor/`がsymlinkのcheckoutからは通らない（相対path解決で`clang: error: no such file or directory: '../../…/src/version.c'`）。`vendor/`を実体で持つcheckoutから流す（`ios:*`/`watchos:*`/`r2p2:qemu_check`はsymlink越し可）。
- **Ruby 4.0 `drb`依存**: default gemに`drb`が無いためrootの`Gemfile`に`gem 'drb'`が必要。host testはverifier注入で本物DRb経路を通らないため、欠けてもtest緑のまま実機で`LoadError`になる。

## launchd（`rake pc:up` / `lib/pc_lifecycle.rb`）実測挙動

- **`bootout`+`bootstrap`必須**: `launchctl kickstart -k`は書き直したplistを読み直さない。設定変更時は必ず`bootout`+`bootstrap`する。
- **`bootout`非同期完了**: `bootout`はunload完了前に返り、port解放とservice登録消去は別シグナル。`launchctl print`が失敗する（不在）まで待ってから`bootstrap`する。
- **daemon portへのconnect確認禁止**: `wait_for_port`がconnectして即closeすると見捨てられた接続がdrb portに残り、sidecar priming中にブロックしている協調Task daemonが後から書き込んでSIGPIPE死する。`pc:up`は`lsof`でLISTENを見るだけにする。
- **Signalと`SO_NOSIGPIPE`**: PicoRuby VMはsignalをtrapできない（`Signal.list`に`PIPE`無し、`Signal.trap("TERM")`は`SystemStackError`、`INT`はblock未実行で130終了）。Ctrl-C後始末が要るscriptはzshの`trap`で包む（`tools/ambient_demo.zsh`）。`picoruby-socket`はlisten socketに`SO_NOSIGPIPE`を付けてaccepted socketへ継承させ（RST先着socketには後から`setsockopt`不可）、`picoruby-drb`がEPIPE clientだけを捨ててacceptを続ける。
- **CoreBluetooth TCCと署名**: TCC許可はappのdesignated requirementに付く。`codesign -s -`のad-hoc署名ではcdhashがrequirementになり、`pc:vm_build`→`pc:app_bundle`のたびに別app扱いされlaunchd daemonが許可ダイアログ待ちでscan 0件になる（Terminal実行はTerminalの許可で動くため切り分けにならない）。`pc:app_bundle`はrequirementを`identifier "com.bash0c7.stackchanpico"`に固定して署名する。`pc:vm_build`後は必ず`pc:app_bundle`を再実行する。このMacのApple Development証明書は失効している。
- **daemon固まり調査資料**: Obsidian vaultの`review/2026-10-01-daemon-freeze/`、`plans/2026-10-03-daemon-tick-thread.md`、`review/2026-10-10-pr11-closing-notes.md`。
