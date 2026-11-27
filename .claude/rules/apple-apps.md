---
paths:
  - "apps/ios/**"
  - "apps/watchos/**"
  - "build_config/darwin-stackchan-ios*"
  - "build_config/darwin-stackchan-watchos*"
  - "mrbgems/picoruby-stackchan-controller/**"
---

# iOS・watchOSアプリとDarwin VM制約

## Ruby↔Swift Bridge契約

- `apps/ios/app.rb`・`apps/watchos/app.rb`は`App = StackChan.controller do |c| … end` 1つだけのDSLファイル。
- bridgeは`App.__send__(method, String)`を呼んでstdoutを返すだけ。controllerは最初のcallでplatform centralに自己wireし、全action（built-in含む）を実methodとして定義する（`Controller#define_action`）。`method_missing`受けにすると`__send__`がC関数呼び出しになりBLE通知が届かない。
- `actions`は引数付き呼び出しで`name<TAB>label`を1行ずつ出す。Swift（`Sources/`）はその行から1 action 1ボタンを生成する（`connect`はtoolbar、`stop`は非表示）。iOSはtext fieldの内容を引数に渡し、SpeakはAVSpeechのμ-law hexをbuilt-in `speak_audio`へ渡す。
- bridgeは1sごとに`tick`を呼ぶ。
- `-StackchanBatch "<verb args>;…"`起動時はVM open後に各行を順に呼び、出力各行を`[batch] <line>`、末尾に`[batch] end`を出してexit 0。`vm_call`は呼び出し中にprocess全体のstdout/stderrを取り込むため、batch行はVMの直列queue上で書く（別thread出力は実行中callか`tick`に混ざる）。

## VM Build・Gem一覧・Toolchain

- VM configは`build_config/darwin-stackchan-{ios,watchos}-{sim,device}.rb`（repo内gemはpath指定）。`rake ios:*`/`watchos:*`が`vendor/R2P2-darwin`の`<platform>:app:*`を`APP_DIR`等のenvで呼び、`project.yml`は`${R2P2_DARWIN}`を参照する。
- **`hal-task-darwin`はiOS/watchOS configに入れない**（`bridge/task_hal_ios.c`と二重定義になる）。
- **gembox無し個別列挙の落とし穴**: iOS/watchOS VMはgemboxを使わずgemを1つずつ並べるため、言語拡張gem（`mruby-hash-ext`/`mruby-numeric-ext`/`mruby-method`等）をhost test VMの組に揃える。欠けるとpc suiteは緑なのにVM内で`NoMethodError`になる（`Hash#fetch`、`Integer#odd?`、`method(:name)`）。controllerを変えたら`stackchan-apple-simulator`で`status`まで流す。
- **Swiftly PATH競合**: `ios:*`/`watchos:*`の`lib`はPATHの`swift`で`picoruby-ble` Swift packageをbuildする。`~/.swiftly/bin`がXcodeの`/usr/bin/swift`より先に来ると`unknown argument: '-target-arch-variant'`で落ちる。Xcodeの`swift`が先に来るPATHで流す。
- `<platform>:lib`と`<platform>:device:lib`は同じ`Vendor/lib/libmruby.a`を書く。device build後にSimulator buildする前は必ず`<platform>:lib`を再実行する（別arch archiveでも`BUILD SUCCEEDED`になり起動時dyldで落ちる）。
- Simulator検証は`stackchan-apple-simulator`を使う（`rake ios:run`/`ios:all`は`open -a Simulator`で止まる）。実機（iPhone/Apple Watch）検証と`devicectl`制約は`.claude/skills/stackchan-device-acceptance/references/apple-device.md`を参照する。
