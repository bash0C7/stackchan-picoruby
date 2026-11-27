---
paths:
  - "test/**"
  - "test-host/**"
  - "spec/**"
  - "Rakefile"
  - ".rigor*"
  - ".github/**"
---

# テストHarness・型検査・CI規約

## picotest Suite注入の仕組み

- **device suite（`test/device/`）**: `test/picotest/harness.rb`がfakes（`test/fake_*.rb`）+stub（`test/picotest/stubs.rb`）+robot gemのmrblib（`peripheral.rb`除く）+scservo source+`apps/robot/app.rb`をhost VMに注入する。appはCRuby側でprismがtop-level `require`を落とし、`RobotApp.robot`に包み、`StackChan::Robot#run`をself返却stubに差し替えて読ませる（`test/device/app_test.rb`がfakeにwireして検証）。`picoruby-drb`はmrblibをsource注入、AOT kernelは`aot/kernels`のRuby、`multicore`は`test/fake_multicore.rb`を注入。
- **pc suite（`test/pc/`）**: `mrbgems/picoruby-stackchan-controller`のmrblibと`apps/mac/app.rb`をそのままsource注入。`apps/ios/app.rb`/`apps/watchos/app.rb`は各testが`App`定数名だけ変えて`load`。`test/pc/stubs.rb`+`FakeRadio`（切断・拒否模擬）/`FakeRobotRadio`+時計注入で回す。`PICOTEST_VM=`で別VM指定可。
- **CRuby runnerとhost VMの二重読み込み**: picotest runnerはCRubyでtest fileを`load`して`Picotest::Test`サブクラスを列挙し、classごとにhost VM scriptを生成するため、test fileとstubはCRubyでも読める形を保つ。host VMは実物の`Task`を持ち`DRb`を持たないため、harnessが`picoruby-drb` mrblibをsource注入し、`Task` stubは`unless Object.const_defined?(:Task)`で囲んでhost VM実物を残す。
- **sidecar / tools suite**: `pc/sidecar/service.rb`、`tools/latency_summary.rb`、`tools/ambient_demo.rb`をsource注入（Foundation Models/`say`/`bin/stackchan`はfake差替）。picotestは注入sourceを1本のscriptに埋め込むため`__FILE__ == $0`が真になる。`tools/*.rb`は第1引数（repo root）がある時だけ本体を走らせる。

## Golden・依存VM・Rigor・CI

- **face geometry golden**: `spec/golden/face_<name>.dump`。意図した変更時のみ`rake face:register_golden FACE=<name>`で更新。
- **`picoruby-scservo`**: firmware buildがfetchする。build前は`SCSERVO_RB=`でcloneを指す。
- **host VM build分離**: host VMは`vendor/R2P2-ESP32/components/picoruby-esp32/picoruby/build/host-picotest`に建ち、R2P2-ESP32自身の`build/host`と分離している。全suiteが`uninitialized constant Picotest`になったらbuild名衝突を疑う。
- **rigor型解析**: `rake test`が先に`rigor:check`を走らせ、`rigor.baseline.json`に無いdiagnosticが1つでもあれば失敗する。`rake vendor:setup`済みが前提（初回に`vendor/rigor-tool`へgemset展開）。詳細は`docs/rigor.md`。
- **CI**: `deps.yml`はpushごと、`firmware.yml`は週次+手動。`firmware.yml`対象を変えたら`gh workflow run firmware.yml`で起動する。
