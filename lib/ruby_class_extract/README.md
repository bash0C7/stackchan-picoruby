# ruby_class_extract

## Why this exists

PicoRuby (R2P2-ESP32) and other on-device Ruby runtimes ship `require`able
gems that are not available in host CRuby (e.g. `spi`, `gpio`, `ble`,
`ili9342`). A production script that does `require 'ble'` at the top cannot
be `load`ed by a CRuby test process. Yet the script also defines pure-Ruby
classes (DSLs, dispatchers, geometry) whose behavior we want to assert in
fast host tests.

## How it works

1. `Prism.parse(File.read(path))` produces an AST.
2. We walk the AST collecting `ClassNode` and `ModuleNode` definitions.
3. Classes whose superclass name appears in `exclude_superclasses:` are
   skipped (they reference on-device-only APIs).
4. The collected nodes are emitted as Ruby source into a Tempfile.
5. `Kernel#load` evaluates the tempfile. Tempfile lifecycle is managed by
   Ruby's `Tempfile` finalizer.

## Why this is black magic

The production script and the test target are the *same file*. We parse the
production source, re-synthesize a subset of it as a synthetic Ruby script,
and load that subset into the test process. This is not standard testing
practice; normal patterns either share library code via `require` or run
end-to-end on the real runtime. We use this technique because the script
is a single deployable artifact (`/home/app.mrb` for autostart) that mixes
hardware bootstrap with pure-Ruby class definitions.

## Usage

```ruby
require 'ruby_class_extract'

RubyClassExtract.load_classes_from(
  'app/application.rb',
  exclude_superclasses: %w[BLE],
)
display = FakeDisplay.new
StackchanApp::Face::Sad.new.draw(display)
```
