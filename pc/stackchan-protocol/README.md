# stackchan-protocol (PC side)

Host-side Ruby gem for talking to a StackChan running `picoruby-stackchan-protocol`. Sends 1-byte commands over USB-serial; receives `'?'` (one byte) on device error.

## Install

```sh
cd pc/stackchan-protocol
bundle install --path vendor/bundle
```

## CLI

```sh
bundle exec stackchan-control --port /dev/cu.usbmodem1101 neutral
bundle exec stackchan-control --port /dev/cu.usbmodem1101 smile
bundle exec stackchan-control --port /dev/cu.usbmodem1101 joy
bundle exec stackchan-control --port /dev/cu.usbmodem1101 raw 9   # forces '?' path
```

`--port` 省略時は env `STACKCHAN_PORT` を見る。

Exit codes:
- 0: success (ack timeout 内に `'?'` が来なかった)
- 1: device error (`'?'` が来た)
- 2: usage error (port 未指定、未知 face、引数不足)

## Library

```ruby
require "stackchan_protocol"

client = StackchanProtocol::Client.new(port: "/dev/cu.usbmodem1101")
client.open do |serial|
  client.drain(serial, timeout: 1.0)   # absorb boot log
  client.set_face(serial, :smile)
rescue StackchanProtocol::DeviceError => e
  warn "device: #{e.message}"
end
```

## Tests

```sh
bundle exec rake test
```

FakeUart で UART クラスを差し替えるので実機不要。実機検証は `docs/STACKCHAN_PROTOCOL_VERIFICATION.md`。

## 設計

`docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md`
