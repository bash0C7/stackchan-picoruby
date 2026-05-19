# stackchan-notifier: multi-command dispatch (notify / servo / raw)

Date: 2026-05-19
Status: Spec — pending plan + implementation

## Motivation

The current `stackchan-notifier` Worker is hardcoded to a single tuple
shape `[:notify, face, lc, lm, rc, rm, dur]` and a single delivery path
(face + LED combo frame + optional restore). Phase B (servo) cannot be
plugged in without an architectural change.

The naive "add a :servo case to handle_tuple" plan in
`docs/superpowers/plans/2026-05-19-phase-b-servo.md` Task 13 assumes a
dispatch structure that does not exist. This spec replaces that task
with a deeper refactor that generalizes the notifier into a small
**multi-command BLE dispatch bus** while keeping the keep-alive
connection, burst coalescing, and reconnect/GATT-trap detection that
already work today.

The scope is deliberately broader than Task 13: notify, servo, AND raw
frame dispatch — plus a face→motion mapping so `stackchan-notify
--face joy` can drive the head as part of the notification, with a
`--silent` opt-out for quiet sessions.

## Goals

1. Single Rinda `TupleSpace` pattern that carries any future command
   kind without touching the Worker dispatch loop.
2. Three command kinds at launch: `:notify`, `:servo`, `:raw`. Adding
   a fourth kind = one handler class + one CLI exe.
3. Per-kind latest-wins burst coalescing (notify burst collapses
   independently of a parallel servo burst).
4. `stackchan-notify --face joy` defaults to face + LED + matched
   servo motion (looked up from a daemon-side `NotifyMotionTable`).
   `--silent` flag suppresses the servo part while keeping face / LED.
5. Existing reconnect / backoff / GATT-cache-trap detection in the
   Worker stay untouched.
6. Clean break on tuple shape (no backward compat with the 7-tuple).
   `stackchan-notify` CLI args stay non-breaking — only the wire
   tuple changes shape.

## Non-goals

- Multi-step gesture sequences (e.g. angry left-right shake as a
  sequence of servo writes with sleeps between). The `:angry` motion
  preset is a single pose for now. A future spec can extend handlers
  with a sequencer.
- Request-response over DRb (e.g. returning the device's
  `<Y_actual:..,P_actual:..>` detail frame to the hook caller). The
  `bin/servo-verify` script keeps doing direct `Client` calls for
  that path; the daemon stays fire-and-forget.
- Daemon supervisor / handler-thread restart on unexpected exception.
  An unhandled exception in `deliver` will still kill the Worker
  thread; the user can restart the daemon manually. Add a supervisor
  later if real bugs warrant it.
- YAML / runtime-customizable `NotifyMotionTable`. The table is a
  frozen Ruby constant. Per-user motion tuning is a future feature.

## Architecture

```
                      DRb (Unix socket)
  ┌──────────────────┐    │    ┌─────────────────────────────────────┐
  │ stackchan-notify │────┤    │     stackchan-notifier-daemon       │
  │  --face joy      │    │    │                                     │
  │  [--silent]      │    │    │  ┌───────────────────────────────┐  │
  └──────────────────┘    │    │  │ TupleSpace4Ractor             │  │
                          │    │  │ pattern: [:cmd, Symbol, Hash] │  │
  ┌──────────────────┐    │    │  └──────────────┬────────────────┘  │
  │ stackchan-servo  │────┤    │                 │ blocking take      │
  │  --yaw N         │    │    │  ┌──────────────▼────────────────┐  │
  └──────────────────┘    │    │  │ Worker (1 thread)             │  │
                          │    │  │  - drain_latest_per_kind      │  │
  ┌──────────────────┐    │    │  │  - HANDLERS[kind].deliver(..) │  │
  │ stackchan-raw    │────┘    │  └──────────────┬────────────────┘  │
  │  --frame '<F:2>' │         │                 │ via @client       │
  └──────────────────┘         │  ┌──────────────▼────────────────┐  │
                               │  │ StackchanBleClient (keep-alive)│  │
                               │  └──────────────┬────────────────┘  │
                               └─────────────────┼───────────────────┘
                                                 │ BLE NUS
                                                 ▼
                                            CoreS3 StackChan
```

### Tuple shape (single pattern)

```ruby
TUPLE_PATTERN = [:cmd, Symbol, Hash].freeze
```

Every command — including future kinds — uses this shape. The second
element is the kind, the third is a `Hash` of parameters whose schema
is owned by that kind's handler.

### Sentinels (internal use)

```ruby
SHUTDOWN_TUPLE        = [:cmd, :__shutdown__,        {}].freeze
FORCE_RECONNECT_TUPLE = [:cmd, :__force_reconnect__, {}].freeze
```

`shutdown_sentinel?(tuple)` and `force_reconnect_sentinel?(tuple)` test
`tuple[1] == :__shutdown__` etc.

## Components

| Component | Responsibility | New / Modified |
|---|---|---|
| `lib/stackchan_notifier/worker.rb` | Single thread, drain-latest-per-kind, dispatch to handler | **Modified** |
| `lib/stackchan_notifier/handlers/notify_handler.rb` | face + LED + (motion via table unless silent) + restore scheduling | **New** |
| `lib/stackchan_notifier/handlers/servo_handler.rb` | servo head frame send (yaw/pitch/time/velocity) | **New** |
| `lib/stackchan_notifier/handlers/raw_handler.rb` | `raw_send` wire frame as-is | **New** |
| `lib/stackchan_notifier/notify_motion_table.rb` | `{face_symbol => {yaw:, pitch:, time_ms:}}` lookup | **New** |
| `lib/stackchan_notifier/cli.rb` | `stackchan-notify` — `--silent` flag added, tuple shape changed | **Modified** |
| `lib/stackchan_notifier/servo_cli.rb` | `stackchan-servo` CLI entry — writes `[:cmd, :servo, hash]` | **New** |
| `lib/stackchan_notifier/raw_cli.rb` | `stackchan-raw` CLI entry — writes `[:cmd, :raw, hash]` | **New** |
| `lib/stackchan_notifier/cli_base.rb` | shared DRb-send + socket option + quiet/exit-code helpers | **New** |
| `exe/stackchan-servo` | thin shim → `ServoCLI.run(ARGV)` | **New** |
| `exe/stackchan-raw` | thin shim → `RawCLI.run(ARGV)` | **New** |
| `lib/stackchan_notifier/daemon.rb` | socket / signal / shutdown unchanged | **Unchanged** |

### Handler interface (duck type)

```ruby
class XxxHandler
  # ctx is a Hash with at least { ts:, restore_sleep_fn: }.
  # Handlers that don't need restore scheduling simply ignore ctx.
  def deliver(client:, params:, ctx:)
    # body
  end
end
```

Handlers are instantiated once at Worker startup and reused for the
lifetime of the daemon (allowing them to hold mutable state — e.g.
`NotifyHandler` keeps `@restore_thread` for cancellation across
deliveries).

## Data flow

```
1. hook script:  stackchan-notify --face joy --left_led red,blink --duration 3
                                 │
                                 ▼ DRb#write
2. tuple:        [:cmd, :notify, {face: :joy, left: [0x00FFFF, :blink],
                                  right: [0x000000, :solid], duration: 3,
                                  silent: false}]
                                 │
                                 ▼ TupleSpace
3. Worker loop:  take([:cmd, Symbol, Hash])     # blocks
                 → tuple_in_hand
                 → drain_latest_per_kind        # collapse burst
                   = [[:notify, latest_notify_params]]   # ordered first-seen
                                 │
                                 ▼
4. For each (kind, params) in order:
   HANDLERS[kind].deliver(client: @client, params:, ctx: {ts: @ts, restore_sleep_fn:})
                                 │
                                 ▼
5. NotifyHandler.deliver:
   client.send do |s|
     s.face(:joy)
     s.led(:hsb, 0x00FFFF, side: :left,  mode: :blink)
     s.led(:hsb, 0x000000, side: :right, mode: :solid)
     unless params[:silent]
       motion = NotifyMotionTable.lookup(:joy)
       s.head(yaw: motion[:yaw], pitch: motion[:pitch], time_ms: motion[:time_ms]) if motion
     end
   end
   schedule_restore(ctx[:ts], params[:duration], silent: params[:silent]) if params[:duration]
```

### `drain_latest_per_kind` (new Worker private)

```ruby
def drain_latest_per_kind(initial)
  latest = {}   # kind => params
  order  = []   # first-occurrence order
  apply  = ->(t) {
    _, kind, params = t
    order << kind unless latest.key?(kind)
    latest[kind] = params    # newer params overwrite older — latest wins per kind
  }
  apply.call(initial)
  loop do
    extra = @ts.take_nonblocking(TUPLE_PATTERN)
    if shutdown_sentinel?(extra)
      @shutdown_during_drain = true
      break
    end
    @pending_force_reconnect = true if force_reconnect_sentinel?(extra)
    apply.call(extra)
  rescue Rinda::RequestExpiredError
    break
  end
  order.map { |k| [k, latest[k]] }
end
```

A burst of `[notify_a, notify_b, servo_x, notify_c]` produces
`[[:notify, c], [:servo, x]]` — notify is delivered first (first-seen)
with only its latest params, then servo with its latest params.

### Worker dispatch loop (shape change)

The `deliver(tuple)` private becomes `deliver_burst(per_kind_list)` and
calls each handler in order:

```ruby
def deliver_burst(per_kind_list)
  per_kind_list.each do |kind, params|
    handler = HANDLERS[kind]
    unless handler
      log(:warn, "no handler for kind=#{kind}; dropping params=#{params.inspect}")
      next
    end
    handler.deliver(client: @client, params: params, ctx: handler_ctx)
  end
  true
rescue StackchanBleClient::Error, IOError, SystemCallError => e
  log(:info, "send failed: #{e.class}: #{e.message}; will reconnect")
  disconnect_quietly
  false
end

HANDLERS = {
  notify: NotifyHandler.new,
  servo:  ServoHandler.new,
  raw:    RawHandler.new,
}.freeze
```

The existing `run_loop` retry slot semantics (retry whole burst once if
send fails, drop on second failure) carry over unchanged — the unit of
retry is the per-kind list.

## Per-kind handler details

### NotifyHandler

```ruby
class NotifyHandler
  def initialize
    @restore_thread = nil
  end

  def deliver(client:, params:, ctx:)
    cancel_pending_restore
    client.send do |s|
      s.face(params[:face])
      s.led(:hsb, params[:left][0],  side: :left,  mode: params[:left][1])
      s.led(:hsb, params[:right][0], side: :right, mode: params[:right][1])
      unless params[:silent]
        motion = NotifyMotionTable.lookup(params[:face])
        s.head(yaw: motion[:yaw], pitch: motion[:pitch], time_ms: motion[:time_ms]) if motion
      end
    end
    schedule_restore(ctx, params[:duration], silent: params[:silent]) if params[:duration]&.positive?
  end

  private

  def schedule_restore(ctx, seconds, silent:)
    @restore_thread = Thread.new(ctx[:ts], seconds, silent) do |ts, secs, sil|
      ctx[:restore_sleep_fn].call(secs)
      ts.write([:cmd, :notify, {
        face: :neutral,
        left:  [0x000000, :solid],
        right: [0x000000, :solid],
        duration: nil,
        silent: sil,
      }])
    end
  end

  def cancel_pending_restore
    @restore_thread&.kill
    @restore_thread = nil
  end
end
```

`silent: true` notify → restore tuple also `silent: true`. The head
stays where the previous non-silent notify left it (or wherever it
already was).

### ServoHandler

```ruby
class ServoHandler
  def deliver(client:, params:, ctx:)
    client.send do |s|
      s.head(
        yaw:      params[:yaw],
        pitch:    params[:pitch],
        time_ms:  params[:time_ms],
        velocity: params[:velocity],
      )
    end
  end
end
```

No restore — servo is sticky. `FrameCodec.encode_head` already raises
`ArgumentError` if both `yaw` and `pitch` are nil; that propagates as
an unrelated exception and kills the worker thread (operator bug,
not a runtime issue).

### RawHandler

```ruby
class RawHandler
  def deliver(client:, params:, ctx:)
    frame = params[:frame]
    frame = frame + "\n" unless frame.end_with?("\n")
    client.raw_send(frame)
  end
end
```

## NotifyMotionTable

`lib/stackchan_notifier/notify_motion_table.rb`:

```ruby
module StackchanNotifier
  module NotifyMotionTable
    MOTIONS = {
      neutral:   { yaw:    0, pitch: 450, time_ms: 300 },
      smile:     { yaw:    0, pitch: 500, time_ms: 300 },
      joy:       { yaw:    0, pitch: 600, time_ms: 250 },
      surprised: { yaw:    0, pitch: 750, time_ms: 120 },
      sad:       { yaw:    0, pitch: 280, time_ms: 500 },
      angry:     { yaw:  150, pitch: 450, time_ms: 200 },
    }.freeze

    module_function

    def lookup(face)
      MOTIONS[face]   # unknown face → nil = no motion sent
    end
  end
end
```

These numbers are initial defaults; HITL tuning is a follow-up task.
`angry` is a single pose (lean right) — a multi-step shake would
require the sequencer extension noted in non-goals.

## CLI surface

### `stackchan-notify` (modified)

```
Usage: stackchan-notify --face NAME [options]

  --face NAME              one of: neutral / smile / joy / surprised / sad / angry
  --left_led COLOR,MODE    LED for left hand (default: 0x000000,solid)
  --right_led COLOR,MODE   LED for right hand (default: 0x000000,solid)
  --duration N             auto-restore to neutral after N seconds
  --silent                 suppress servo motion (face + LED still sent)   [NEW]
  --socket PATH
  --quiet
```

Writes:
```ruby
[:cmd, :notify, {
  face: opts[:face],
  left: opts[:left],
  right: opts[:right],
  duration: opts[:duration],
  silent: opts[:silent],
}]
```

### `stackchan-servo` (new)

```
Usage: stackchan-servo [--yaw N] [--pitch N] [--time N] [--velocity N] [--socket PATH] [--quiet]
  At least one of --yaw or --pitch required.
  --time and --velocity are mutually exclusive (--time wins, matching ble-client FrameCodec).
```

Writes:
```ruby
[:cmd, :servo, {yaw:, pitch:, time_ms:, velocity:}]
```

### `stackchan-raw` (new)

```
Usage: stackchan-raw --frame '<F:2>' [--socket PATH] [--quiet]
  --frame STRING           wire frame to send as-is (handler appends \n if missing)
```

Writes:
```ruby
[:cmd, :raw, {frame: opts[:frame]}]
```

### Shared CliBase

`lib/stackchan_notifier/cli_base.rb` extracts:
- `--socket PATH` / `--quiet` parsing
- DRb send with `Errno::ENOENT` / `DRb::DRbConnError` swallow
- exit codes (0 on success or daemon-unavailable, 2 on bad arg)
- DRb client startup glue

So the three CLI classes only own their own arg parsing + tuple
construction.

## Restore semantics summary

| kind | restore | notes |
|---|---|---|
| `:notify` | `params[:duration]` seconds after deliver | RESTORE_TUPLE = `[:cmd, :notify, {face: :neutral, left: BLACK, right: BLACK, duration: nil, silent: original_silent}]`. Silent original → silent restore (head stays put). |
| `:servo` | none | sticky position; restore is the caller's responsibility |
| `:raw` | none | sticky; raw is explicit byte intent |

## Error handling

| Case | Behavior |
|---|---|
| Worker takes unknown kind | `log(:warn, ...)` and drop (no exception → don't kill the worker thread) |
| `deliver` raises `StackchanBleClient::Error` / `IOError` / `SystemCallError` | log(:info), disconnect_quietly, return false → run_loop retries once |
| `deliver` raises any other exception | re-raise — worker thread dies, daemon needs manual restart (acceptable for now) |
| `NotifyMotionTable.lookup(unknown_face)` | nil → motion skipped, face + LED still sent (same path as `--silent`) |
| `stackchan-raw --frame ''` | CLI exit 2 with stderr message; never reaches handler |
| Concurrent notify + servo + raw burst | One handler dispatch per kind, sequential BLE writes |

## Testing strategy

3-layer unit + 1 integration. TDD: RED → GREEN → REFACTOR per handler,
no CLI shim added before its handler is GREEN.

| Layer | Target | Form | Location |
|---|---|---|---|
| Handler unit | NotifyHandler / ServoHandler / RawHandler | Mock Client + arg recording → assert expected SendBuilder DSL calls | `test/handlers/{notify,servo,raw}_handler_test.rb` (new) |
| NotifyMotionTable | `.lookup` return values | Pure hash test, 6 faces + unknown = nil | `test/notify_motion_table_test.rb` (new) |
| Worker dispatch | `drain_latest_per_kind` + handler invocation order | Mock TS + mock handler registry; verify "burst → 1 per kind + first-seen order" + "per-kind latest-wins" | `test/worker_test.rb` (large rewrite) |
| CLI unit | NotifyCLI / ServoCLI / RawCLI | Mock sender — assert tuple shape, `--silent` propagation, exit 2 on bad args | `test/cli_test.rb` (modified) + `test/servo_cli_test.rb` / `test/raw_cli_test.rb` (new) |
| Daemon integration | daemon start → write 3 kind tuples → handler-driven BLE call observed | Mock `client_factory`, follow existing `daemon_test.rb` pattern | `test/daemon_test.rb` (extended) |

## Migration

Clean break:
- Existing 7-tuple shape is removed. Old `stackchan-notify` CLI args
  still work — only the wire tuple shape changes.
- CLI and daemon must be deployed together. An old CLI writing a
  7-tuple into a new daemon would leave the tuple unmatched in the
  TupleSpace forever (no handler).
- Bump `lib/stackchan_notifier/version.rb` to `2.0.0`.
- README gets one paragraph: "v2.0: tuple shape changed to `[:cmd,
  Symbol, Hash]`; CLI args unchanged; daemon owns face→motion mapping
  via `NotifyMotionTable`."

No DRb-level version negotiation (YAGNI; single user).

## Out of scope (future specs)

- Multi-step gesture sequences (NotifyMotionTable entries as arrays of
  poses with inter-pose sleeps) → sequencer extension to handlers
- Request-response over DRb (returning device detail frames to hook
  callers) → bidirectional protocol on the BLE worker
- YAML-configurable NotifyMotionTable → per-user customization
- Daemon supervisor (restart worker thread on unexpected exception) →
  needed only if real bugs warrant
- HITL tuning of NotifyMotionTable numbers → separate Phase B+ task
