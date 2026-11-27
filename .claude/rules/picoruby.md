---
paths:
  - "mrbgems/**"
  - "apps/**/*.rb"
  - "pc/**/*.rb"
  - "aot/**/*.rb"
  - "test/**/*.rb"
  - "tools/**/*.rb"
---

# PicoRuby規約と実測済みVM制約

## mrbgem構成と参照先

- コードとファイル配置は[picoruby/picoruby](https://github.com/picoruby/picoruby)のmrbgemsを手本にする。
- gemは`mrbgem.rake`+`mrblib/<gem>.rb`（+`mrblib/<gem>/*.rb`）+`test/*_test.rb`。例外は`stackchan-robot`（`test/device/`）と`stackchan-controller`（`test/pc/`）。
- `mrblib`内でsiblingを`require`しない（buildが全部bundleする）。cross-gemの`require 'ble'`等だけ書く。
- on-deviceの`require`名はgem名から`picoruby-`を落としたhyphen形（例: `require 'stackchan-protocol'`）。
- テストはpicotest（`Picotest::Test`サブクラス、`test/*_test.rb`）。CRubyのtest-unitはrake側コード（`test-host/`）のみ。
- 仕様不明時は`chiebukuro_query_ruby_knowledge`→無ければ`vendor/R2P2-ESP32/components/picoruby-esp32/picoruby`を読む。「禁止メソッド」を推測で決めない。
- 複数portを持つgem（`picoruby-ble`のrp2040とesp32等）の従portは`include/*.h`の契約にconformすることだけを行う。主portに無いログ・説明コメント・観測性の上乗せを置かない（既存分も消す）。契約自体の是非や主port・共有層への論評は範囲外。従portが既存契約を自分の中で守れていない箇所の是正は行う。

## 実測で確認済みのCRubyとの差

- **例外再送出**: `rescue`節の裸の`raise`は元例外を再送出しない。`rescue Foo => e`…`raise e`と書く。
- **FreeRTOS 8KB task stackとC-yieldネスト**: mruby VMを回すFreeRTOS taskのstackは8KB。Cからblockをyieldする構文（`Array.new(n) { }`、`String#dup`等）はVMを1段ネストして約3.1KB積む。描画・BLEの深い経路は`while`とC実装メソッドで書く。症状は`stack overflow in task picoruby_task`のboot loopで、hostでは再現しない。
- **例外によるstack消費**: 1回の`raise`+`rescue`でC stackを約1.8KB積む（起動後の空きは約2KB）。tickとBLEの経路で`raise`を流れの制御に使わない（`DRbBle::Responder#feed`は長さ付きメッセージを切り出し揃ってから読む）。
- **`String#[]=`の計算量**: 差し込み先の全長に比例する。大きなbufferに行ごとに差し込まない（hostでは見えにくい）。
- **`send`/`__send__`とC関数境界**: 相手が定義していないmethod（`method_missing`受け、`DRb::DRbObject`が典型）を`send`/`__send__`で呼ぶとC関数呼び出し経由になる。その内側の`sleep_ms`はtaskを切り替えず、`Task.pass`は`can't pass across C function boundary`をraiseする。MacのBLE通知はscheduler入口でしかevent queueに移らないためreplyが見えず3sでtimeoutする。
  - DRbのfrontを名前で呼ぶ時は`DRb.send_message`を使う（`Central#call_front`）。
  - 名前で呼ばれる側（iOS/watchOS bridgeが`App.__send__`で呼ぶcontroller、`DRbBle::Responder`が`send`で呼ぶrobotの`Remote`）はその名前を実methodとして定義する（`Controller#define_action`、`Remote#define_handler`）。robotではC関数呼び出しがVMをもう1段積む。
  - hostでは`Task.pass`するradio（`test/pc/passing_radio.rb`）と`Task.pass`するhandler（`test/device/drb_channel_test.rb`）で回帰検出する。
- **Mac VM（controllerコード）の制約**: Mutex/Threadは無い（timesliceの`Task`と`Task::Queue`）。drbはkwargs（Hash引数）もremote blockも運ばない（pollする）。`system`はbackgroundにもredirectにもできない（backendはlaunchd起動）。regexpに`|`選択が無い。`gsub`/`sub`はmultibyteを誤る（`each_char`を使う）。引数無し`module_function`は効かない。
- **`Task.new`の`self`**: `Task.new`のblockは`self`がトップレベルの`main`で走る。block内で使うreceiverやinstance変数は先にlocal変数へ取ってから渡す（`Daemon#start_tick` / `#stop`）。
