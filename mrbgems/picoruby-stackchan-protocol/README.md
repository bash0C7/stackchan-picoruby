# picoruby-stackchan-protocol

StackChan ⇔ PC の USB-serial 1-byte プロトコル ディスパッチャと、neutral / smile / joy 3 表情の手続き的顔描画を提供する PicoRuby mrbgem。

## API

### `StackchanProtocol::Dispatcher`

```ruby
display = ILI9342.new(...)
StackchanProtocol::Dispatcher.new(display: display).run
```

- `STDIN.read(1)` でブロッキング読込
- `'0'` neutral / `'1'` smile / `'2'` joy → 描画
- 上記以外（boot ノイズ `\r\n` 含む）と内部例外 → `STDOUT.write('?')`
- `nil` (EOF) で `run` から return（host テスト用）

### `StackchanProtocol::Face`

`Face::Neutral` / `Face::Smile` / `Face::Joy` — 各クラスに `DELTA_Y` 定数、`#draw(display)` で `fill(BLACK) → 両目 → 口` を順次描画。

## 依存

- `picoruby-ili9342`
- `picoruby-spi` / `picoruby-gpio`（examples/app.rb のみ）

## ホストテスト

```sh
bundle install --path vendor/bundle
bundle exec rake test
```

`test/fake_display.rb` と `test/fake_stdio.rb` で display / stdin / stdout を差し替え。実機検証は `docs/STACKCHAN_PROTOCOL_VERIFICATION.md`。

## 設計

`docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md`
