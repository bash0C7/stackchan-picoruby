# stackchan-notifier iter2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address 5 issues found during real-hardware verification of the stackchan-notifier daemon (PR #2): side exclusivity bug, lost notifies during reconnect, no force-rescan signal, no auto-restore timer, and unintuitive `--hsb` UX. The tuple shape is rebuilt once (5 → 7 elements) so independent left/right LED control and a duration field land together; CLI accepts color preset names alongside hex.

**Architecture:** Notifier daemon stays a Ractor-owned `Rinda::TupleSpace` + BLE worker thread. Tuple shape changes from `[:notify, face, hsb, mode, side]` to `[:notify, face, left_color, left_mode, right_color, right_mode, duration_or_nil]`. Worker grows: (a) in-memory `@pending_retry` slot for single-shot retry on transport failure, (b) `FORCE_RECONNECT_SENTINEL` tuple handled in run-loop to support SIGHUP-triggered re-scan, (c) `@restore_thread` for cancel-on-new-tuple duration timer. CLI grows new `--left_led COLOR,MODE` / `--right_led COLOR,MODE` / `--duration N` flags plus a `PRESETS` table for color name resolution; old `--hsb` / `--mode` / `--side` are removed.

**Tech Stack:** Ruby 3.3+, Rinda::TupleSpace (LIFO take), DRb over Unix socket, test-unit, FakeBleClient injection seam.

---

## Scope

Single subsystem (the notifier gem). No firmware-side changes. No `pc/stackchan-ble-client` changes (its abstraction is already correct as of the verification fixes pushed in PR #2's later commits).

## Out of scope

- Mac BT toggle reconnect test
- launchd plist install
- Heartbeat keepalive (deferred — try SIGHUP + device-side `peri.start` infinite-advertise first; revisit if those don't restore long-idle connections)
- Device-side `peri.start(60_000)` infinite-advertise (tracked as a separate firmware-side task)
- Backwards-compatibility shim for the old `--hsb` / `--mode` / `--side` CLI — README is updated atomically; hook config consumers re-write

## File Structure

```
pc/stackchan-notifier/
├── lib/stackchan_notifier/
│   ├── cli.rb        ← new flags, PRESETS, new tuple shape
│   ├── worker.rb     ← new tuple shape, 2-LED deliver, retry, restore, force-reconnect
│   └── daemon.rb     ← SIGHUP trap, force_reconnect wiring
├── test/
│   ├── cli_test.rb   ← new flag parsing tests, preset name resolution tests
│   ├── worker_test.rb ← new tuple shape, retry, restore, force-reconnect tests
│   ├── daemon_test.rb ← SIGHUP test
│   └── helper.rb     ← (no change — FakeBleClient/FakeSendBuilder already record any LED frame shape)
└── README.md         ← new CLI table, new hook examples, SIGHUP & restore docs
```

## Final tuple shape (used everywhere in tasks below)

```ruby
[
  :notify,                                  # 0: sentinel
  face,                                     # 1: Symbol — face name (e.g. :smile, :neutral)
  left_color,                               # 2: Integer — 24-bit hex (0x000000..0xFFFFFF)
  left_mode,                                # 3: Symbol — :solid / :blink / :breathing / :off
  right_color,                              # 4: Integer
  right_mode,                               # 5: Symbol
  duration_or_nil,                          # 6: Integer (seconds) or nil
]
```

`PRESETS = { red: 0xFF0000, green: 0x00FF00, blue: 0x0000FF, yellow: 0xFFFF00, white: 0xFFFFFF, gray: 0x808080 }.freeze`

`SHUTDOWN_TUPLE = [:notify, :__shutdown__, 0, :solid, 0, :solid, nil]`
`FORCE_RECONNECT_TUPLE = [:notify, :__force_reconnect__, 0, :solid, 0, :solid, nil]`
`RESTORE_TUPLE = [:notify, :neutral, 0, :solid, 0, :solid, nil]`

`TUPLE_PATTERN = [:notify, Symbol, Integer, Symbol, Integer, Symbol, nil]`
(Rinda matches `nil` as "any class," so the `duration_or_nil` slot matches whether the tuple carries an Integer or `nil`.)

---

## Task 1: Worker in-memory retry slot (transport failure recoverable in 1 try)

**Files:**
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb`
- Test:   `pc/stackchan-notifier/test/worker_test.rb`

This task does NOT change tuple shape. It uses the current 5-element shape, since Task 3 swaps it.

- [ ] **Step 1.1: Add failing test — first-failure tuple is re-delivered after reconnect**

In `pc/stackchan-notifier/test/worker_test.rb`, append a new test:

```ruby
def test_send_failure_retries_once_after_reconnect
  attempts = []
  @client.on_send { |_b| attempts << :tried; raise StackchanBleClient::ConnectionError, "transient" if attempts.size == 1 }
  worker = build_worker
  worker.start

  @ts.write([:notify, :smile, 0x00FF00, :solid, :both])

  wait_until { attempts.size == 2 }
  assert_equal 2, attempts.size, "tuple should be re-delivered after first failure"
  assert_equal 2, @client.connect_count, "worker should have reconnected once"

  worker.shutdown
end
```

- [ ] **Step 1.2: Run test, expect FAIL**

```
cd pc/stackchan-notifier && bundle exec rake test TEST=test/worker_test.rb TESTOPTS='-n test_send_failure_retries_once_after_reconnect'
```
Expected: FAIL (current worker drops on first failure)

- [ ] **Step 1.3: Implement retry slot in worker**

In `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb`, replace `run_loop`:

```ruby
def run_loop
  @pending_retry = nil
  until @shutdown
    ensure_connected
    break if @shutdown

    tuple, was_retry = next_tuple_to_deliver
    next if shutdown_sentinel?(tuple)
    break if @shutdown

    if deliver(tuple)
      @pending_retry = nil
    elsif was_retry
      log(:warn, "send failed twice; dropping #{tuple.inspect}")
      @pending_retry = nil
    else
      @pending_retry = tuple
    end
  end
  disconnect_quietly
end

private

def next_tuple_to_deliver
  if @pending_retry
    [@pending_retry, true]
  else
    initial = @ts.take(TUPLE_PATTERN)
    [drain_latest(initial), false]
  end
end
```

Replace the existing `deliver` so that it returns a boolean instead of relying on a rescue side-effect:

```ruby
def deliver(tuple)
  _, face, hsb, mode, side = tuple
  @client.send do |s|
    s.face(face)
    s.led(:hsb, hsb, side: side, mode: mode)
  end
  true
rescue StackchanBleClient::Error, IOError, SystemCallError => e
  log(:warn, "send failed: #{e.class}: #{e.message}; will reconnect")
  disconnect_quietly
  false
end
```

- [ ] **Step 1.4: Run test, expect PASS**

Expected: PASS

- [ ] **Step 1.5: Add failing test — second failure drops with warn log**

```ruby
def test_send_failure_drops_after_second_failure
  warnings = []
  @logger = build_capturing_logger(warnings)
  @client.on_send { |_b| raise StackchanBleClient::ConnectionError, "still broken" }
  worker = build_worker
  worker.start

  @ts.write([:notify, :smile, 0x00FF00, :solid, :both])

  wait_until { warnings.any? { |w| w.include?("send failed twice; dropping") } }
  assert(warnings.any? { |w| w.include?("send failed twice; dropping") }, "expected drop warning, got #{warnings.inspect}")

  worker.shutdown
end
```

If `build_capturing_logger` doesn't exist in helper.rb yet, add it:

```ruby
def build_capturing_logger(sink)
  logger = Logger.new(StringIO.new)
  logger.formatter = ->(_severity, _time, _progname, msg) { sink << msg; "" }
  logger
end
```

- [ ] **Step 1.6: Run test, expect PASS** (drop logic already in Step 1.3)

- [ ] **Step 1.7: Add failing test — newer tuple wins over pending retry**

```ruby
def test_newer_tuple_wins_over_pending_retry
  send_args = []
  @client.on_send do |b|
    send_args << b.commands.dup
    raise StackchanBleClient::ConnectionError, "fail once" if send_args.size == 1
  end
  worker = build_worker
  worker.start

  @ts.write([:notify, :smile,     0x00FF00, :solid, :both])  # will fail
  wait_until { send_args.size == 1 }                          # first attempt failed
  @ts.write([:notify, :surprised, 0xFF0000, :blink, :left])   # newer tuple arrives during reconnect window

  wait_until { send_args.size == 2 }
  # The second deliver should carry the NEWER tuple's payload, not the retry of the first.
  latest_led = send_args.last.find { |c| c[:kind] == :led }
  assert_equal 0xFF0000, latest_led[:value], "newer tuple should win over retry; got #{latest_led.inspect}"

  worker.shutdown
end
```

- [ ] **Step 1.8: Run test, expect FAIL**

(Current Step 1.3 logic uses the retry without checking for newer tuples.)

- [ ] **Step 1.9: Implement "newer wins over retry" check**

Replace `next_tuple_to_deliver` in worker.rb:

```ruby
def next_tuple_to_deliver
  if @pending_retry
    newer = try_take_newer
    if newer
      @pending_retry = nil
      [drain_latest(newer), false]
    else
      [@pending_retry, true]
    end
  else
    initial = @ts.take(TUPLE_PATTERN)
    [drain_latest(initial), false]
  end
end

def try_take_newer
  @ts.take_nonblocking(TUPLE_PATTERN)
rescue Rinda::RequestExpiredError
  nil
end
```

- [ ] **Step 1.10: Run test, expect PASS**

- [ ] **Step 1.11: Run full worker test file**

```
cd pc/stackchan-notifier && bundle exec rake test TEST=test/worker_test.rb
```
Expected: ALL PASS (3 new tests added + all existing pass)

- [ ] **Step 1.12: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/worker.rb \
        pc/stackchan-notifier/test/worker_test.rb \
        pc/stackchan-notifier/test/helper.rb
git commit -m "$(cat <<'EOF'
feat(notifier): retry once on transport failure, newer wins over pending retry

Previously a single Peripheral-not-connected during send permanently lost
the tuple, even after the worker successfully reconnected. Now the worker
holds the failed tuple in @pending_retry, re-attempts it after the next
ensure_connected, and drops it (with a warn log) if the retry also fails.
A newer tuple arriving during the reconnect window still wins per the
latest-wins design.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: SIGHUP force re-scan

**Files:**
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb`
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/daemon.rb`
- Test:   `pc/stackchan-notifier/test/worker_test.rb`
- Test:   `pc/stackchan-notifier/test/daemon_test.rb`

Mechanism: SIGHUP handler writes a `FORCE_RECONNECT_TUPLE` sentinel to the TupleSpace. Worker recognizes the sentinel in `run_loop`, calls `disconnect_quietly`, then loops back to `ensure_connected` which re-scans.

- [ ] **Step 2.1: Add failing test — worker handles force-reconnect sentinel**

In `pc/stackchan-notifier/test/worker_test.rb`:

```ruby
def test_force_reconnect_sentinel_triggers_rescan
  worker = build_worker
  worker.start
  wait_until { @client.connect_count == 1 }

  @ts.write([:notify, :__force_reconnect__, 0, :solid, :both])

  wait_until { @client.connect_count == 2 }
  assert_equal 2, @client.connect_count, "SIGHUP-equivalent tuple should trigger reconnect"
  assert_equal 1, @client.disconnect_count, "old connection should be torn down"

  worker.shutdown
end
```

- [ ] **Step 2.2: Run test, expect FAIL**

- [ ] **Step 2.3: Implement force-reconnect sentinel in worker.rb**

Add constants near `SHUTDOWN_SENTINEL`:

```ruby
FORCE_RECONNECT_SENTINEL = :__force_reconnect__
FORCE_RECONNECT_TUPLE    = [:notify, FORCE_RECONNECT_SENTINEL, 0, :solid, :both].freeze
```

(`:both` is correct for the 5-element tuple at this stage; Task 3 will resize this when tuple shape changes.)

Add predicate:

```ruby
def force_reconnect_sentinel?(tuple)
  tuple && tuple[1] == FORCE_RECONNECT_SENTINEL
end
```

Modify `run_loop`'s sentinel handling block (just after `tuple, was_retry = next_tuple_to_deliver`):

```ruby
next if shutdown_sentinel?(tuple)
if force_reconnect_sentinel?(tuple)
  log(:info, "force reconnect requested; tearing down current BLE connection")
  disconnect_quietly
  @pending_retry = nil
  next
end
```

Also add a public method so the daemon can trigger it:

```ruby
def force_reconnect
  @ts.write(FORCE_RECONNECT_TUPLE)
end
```

- [ ] **Step 2.4: Run worker test, expect PASS**

- [ ] **Step 2.5: Add failing test — daemon trap('HUP') triggers worker.force_reconnect**

In `pc/stackchan-notifier/test/daemon_test.rb`:

```ruby
def test_install_signal_handlers_traps_hup_to_force_reconnect
  @daemon.start
  called = 0
  @daemon.worker.define_singleton_method(:force_reconnect) { called += 1 }

  @daemon.install_signal_handlers
  Process.kill("HUP", Process.pid)
  sleep 0.1

  assert_equal 1, called, "SIGHUP should call worker.force_reconnect"
end
```

- [ ] **Step 2.6: Run test, expect FAIL**

- [ ] **Step 2.7: Implement SIGHUP trap in daemon.rb**

Modify `install_signal_handlers`:

```ruby
def install_signal_handlers
  %w[INT TERM].each { |sig| Signal.trap(sig) { stop } }
  Signal.trap("HUP") { @worker&.force_reconnect }
  self
end
```

- [ ] **Step 2.8: Run daemon test, expect PASS**

- [ ] **Step 2.9: Run full test suite**

```
cd pc/stackchan-notifier && bundle exec rake test
```
Expected: all PASS

- [ ] **Step 2.10: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/worker.rb \
        pc/stackchan-notifier/lib/stackchan_notifier/daemon.rb \
        pc/stackchan-notifier/test/worker_test.rb \
        pc/stackchan-notifier/test/daemon_test.rb
git commit -m "$(cat <<'EOF'
feat(notifier): SIGHUP triggers BLE force-reconnect

Adds a force-reconnect sentinel tuple that the worker recognises in its
run-loop and a SIGHUP trap in the daemon that posts the sentinel. Lets
the operator manually nudge the daemon to re-scan / re-connect when the
device returns from a silent disconnect, without restarting the daemon.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: New tuple shape v2 — independent left/right LEDs, duration, color presets, new CLI

**Files:**
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/cli.rb`
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb`
- Modify: `pc/stackchan-notifier/test/cli_test.rb`
- Modify: `pc/stackchan-notifier/test/worker_test.rb`
- Modify: `pc/stackchan-notifier/test/daemon_test.rb`

This task does the big atomic switch. Splitting the tuple shape into smaller commits would break tests in between. The intermediate state is genuinely broken; one commit, no in-between.

- [ ] **Step 3.1: Update worker.rb constants for new tuple shape**

Edit `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb`:

```ruby
TUPLE_PATTERN            = [:notify, Symbol, Integer, Symbol, Integer, Symbol, nil].freeze
SHUTDOWN_SENTINEL        = :__shutdown__
FORCE_RECONNECT_SENTINEL = :__force_reconnect__
DEFAULT_BACKOFF          = [1, 2, 4, 8, 30].freeze
SHUTDOWN_TUPLE           = [:notify, SHUTDOWN_SENTINEL,        0, :solid, 0, :solid, nil].freeze
FORCE_RECONNECT_TUPLE    = [:notify, FORCE_RECONNECT_SENTINEL, 0, :solid, 0, :solid, nil].freeze
RESTORE_TUPLE            = [:notify, :neutral,                 0, :solid, 0, :solid, nil].freeze
```

- [ ] **Step 3.2: Rewrite worker.rb `deliver` for new tuple shape (2 LED frames)**

```ruby
def deliver(tuple)
  cancel_pending_restore
  _, face, left_color, left_mode, right_color, right_mode, duration = tuple
  @client.send do |s|
    s.face(face)
    s.led(:hsb, left_color,  side: :left,  mode: left_mode)
    s.led(:hsb, right_color, side: :right, mode: right_mode)
  end
  schedule_restore(duration) if duration && duration > 0
  true
rescue StackchanBleClient::Error, IOError, SystemCallError => e
  log(:warn, "send failed: #{e.class}: #{e.message}; will reconnect")
  disconnect_quietly
  false
end
```

- [ ] **Step 3.3: Add restore helpers to worker.rb**

```ruby
def schedule_restore(seconds)
  @restore_thread = Thread.new(seconds) do |secs|
    sleep secs
    @ts.write(RESTORE_TUPLE)
  end
end

def cancel_pending_restore
  @restore_thread&.kill
  @restore_thread = nil
end
```

Add `cancel_pending_restore` to `shutdown`:

```ruby
def shutdown(timeout: 5.0)
  return self unless @thread
  cancel_pending_restore
  @shutdown = true
  @ts.write(SHUTDOWN_TUPLE)
  joined = @thread.join(timeout)
  log(:warn, "worker thread did not exit within #{timeout}s") unless joined
  @thread = nil
  self
end
```

Initialize `@restore_thread = nil` in `initialize`.

- [ ] **Step 3.4: Rewrite cli.rb — PRESETS, new flags, new tuple shape**

Replace contents of `pc/stackchan-notifier/lib/stackchan_notifier/cli.rb`:

```ruby
require "optparse"
require "drb/drb"
require "drb/unix"

require_relative "../stackchan_notifier"

module StackchanNotifier
  # Thin client invoked by Claude Code hooks. Reads args, writes one tuple to
  # the daemon's TupleSpace over DRb, exits. Never touches BLE directly.
  #
  # Exit codes:
  #   0 = success, OR daemon unavailable (intentional: hooks must never block
  #       Claude Code on missing infrastructure)
  #   2 = invalid CLI arguments (visible misconfiguration)
  class CLI
    FACES = %i[neutral smile joy surprised].freeze
    MODES = %i[solid blink breathing off].freeze
    PRESETS = {
      red:    0xFF0000,
      green:  0x00FF00,
      blue:   0x0000FF,
      yellow: 0xFFFF00,
      white:  0xFFFFFF,
      gray:   0x808080,
      black:  0x000000,
    }.freeze
    DEFAULT_LED = [0x000000, :solid].freeze   # unspecified side = visually off

    EXIT_OK      = 0
    EXIT_BAD_ARG = 2

    def self.run(argv, stdout: $stdout, stderr: $stderr, sender: method(:drb_send))
      new(stdout: stdout, stderr: stderr, sender: sender).run(argv)
    end

    def self.drb_send(socket, tuple)
      DRb.start_service
      DRbObject.new_with_uri("drbunix:#{socket}").write(tuple)
    end

    def initialize(stdout:, stderr:, sender:)
      @stdout = stdout
      @stderr = stderr
      @sender = sender
    end

    def run(argv)
      opts = parse(argv)
      tuple = [
        :notify,
        opts[:face],
        opts[:left][0],  opts[:left][1],
        opts[:right][0], opts[:right][1],
        opts[:duration],
      ]
      try_send(opts[:socket], tuple, quiet: opts[:quiet])
      EXIT_OK
    rescue OptionParser::ParseError, ArgumentError => e
      @stderr.puts "stackchan-notify: #{e.message}"
      EXIT_BAD_ARG
    end

    private

    def parse(argv)
      result = {
        face:     nil,
        left:     DEFAULT_LED,
        right:    DEFAULT_LED,
        duration: nil,
        socket:   ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:    false,
      }

      parser = OptionParser.new do |o|
        o.banner = "Usage: stackchan-notify --face NAME [--left_led COLOR,MODE] [--right_led COLOR,MODE] [--duration N] [--socket PATH] [--quiet]"
        o.on("--face NAME",          "one of: #{FACES.join(' / ')}")                                { |v| result[:face] = v.to_sym }
        o.on("--left_led SPEC",      "left LED, e.g. red,blink or 0xFF0000,blink",
                                     "default: 0x000000,solid (off)")                              { |v| result[:left]  = parse_led(v) }
        o.on("--right_led SPEC",     "right LED, same format as --left_led",
                                     "default: 0x000000,solid (off)")                              { |v| result[:right] = parse_led(v) }
        o.on("--duration N", Integer, "auto-restore to neutral + both LEDs off after N seconds")    { |v| result[:duration] = v }
        o.on("--socket PATH",        "DRb Unix socket (env: STACKCHAN_NOTIFIER_SOCKET,",
                                     "default: #{StackchanNotifier.default_socket_path})")         { |v| result[:socket] = v }
        o.on("--quiet",              "suppress 'daemon unavailable' stderr (CLI still exits 0)")   { result[:quiet] = true }
        o.on("-h", "--help",         "show this help and exit")                                    { @stdout.puts(o); print_extras; exit EXIT_OK }
      end
      parser.parse!(argv.dup)

      raise ArgumentError, "--face required (one of #{FACES.join(' / ')})" unless FACES.include?(result[:face])
      if result[:duration] && result[:duration] <= 0
        raise ArgumentError, "--duration must be a positive integer (got #{result[:duration]})"
      end
      result
    end

    def parse_led(spec)
      color_str, mode_str = spec.split(",", 2)
      raise ArgumentError, "--left_led / --right_led must be COLOR,MODE (got #{spec.inspect})" if color_str.nil? || mode_str.nil? || color_str.empty? || mode_str.empty?
      [parse_color(color_str), parse_mode(mode_str)]
    end

    def parse_color(str)
      return PRESETS[str.to_sym] if PRESETS.key?(str.to_sym)
      val = Integer(str, 16)
      raise ArgumentError, "color out of range (0x000000..0xFFFFFF): #{str}" if val < 0 || val > 0xFFFFFF
      val
    rescue ArgumentError => e
      raise if e.message.start_with?("color out of range")
      raise ArgumentError, "color must be a preset name (#{PRESETS.keys.join(' / ')}) or hex (0x000000..0xFFFFFF); got #{str.inspect}"
    end

    def parse_mode(str)
      sym = str.to_sym
      raise ArgumentError, "mode must be one of #{MODES.join(' / ')}; got #{str.inspect}" unless MODES.include?(sym)
      sym
    end

    def print_extras
      @stdout.puts
      @stdout.puts "Color presets:"
      PRESETS.each { |name, hex| @stdout.puts format("  %-7s = 0x%06X", name, hex) }
    end

    def try_send(socket, tuple, quiet:)
      @sender.call(socket, tuple)
    rescue DRb::DRbConnError, Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES => e
      return if quiet
      @stderr.puts "stackchan-notify: daemon unavailable (#{e.class}: #{e.message})"
    end
  end
end
```

- [ ] **Step 3.5: Rewrite worker_test.rb assertions for new tuple shape**

Every existing test in `test/worker_test.rb` that writes a tuple must use the new 7-element shape. Use a small helper at the top of the file:

```ruby
def notify_tuple(face: :smile, left: [0x00FF00, :solid], right: [0x00FF00, :solid], duration: nil)
  [:notify, face, left[0], left[1], right[0], right[1], duration]
end
```

Update every `@ts.write([...])` in worker_test.rb to use `notify_tuple(...)` with explicit fields.

Update the `FORCE_RECONNECT_TUPLE` test from Task 2's Step 2.1 to use the new 7-element shape:

```ruby
@ts.write([:notify, :__force_reconnect__, 0, :solid, 0, :solid, nil])
```

Update `deliver`-related assertions: `@client.sent.last` now contains a 3-element array of commands — `[{kind: :face, name: ...}, {kind: :led, side: :left, ...}, {kind: :led, side: :right, ...}]`. Adjust accordingly.

Add three new tests:

```ruby
def test_deliver_sends_face_plus_left_led_plus_right_led
  worker = build_worker
  worker.start
  @ts.write(notify_tuple(face: :joy, left: [0xFF0000, :blink], right: [0x000000, :solid]))
  wait_until { @client.sent.size == 1 }
  cmds = @client.sent.first
  assert_equal :joy, cmds[0][:name]
  assert_equal({kind: :led, form: :hsb, value: 0xFF0000, side: :left,  mode: :blink}, cmds[1])
  assert_equal({kind: :led, form: :hsb, value: 0x000000, side: :right, mode: :solid}, cmds[2])
  worker.shutdown
end

def test_deliver_with_duration_schedules_restore_to_neutral_off
  worker = build_worker(restore_clock: -> { 0.05 })   # see Step 3.6 — inject sleep override
  worker.start
  @ts.write(notify_tuple(face: :surprised, left: [0xFF0000, :blink], right: [0xFF0000, :blink], duration: 1))
  wait_until { @client.sent.size == 2 }
  restore_cmds = @client.sent.last
  assert_equal :neutral, restore_cmds[0][:name]
  assert_equal 0x000000, restore_cmds[1][:value]
  assert_equal 0x000000, restore_cmds[2][:value]
  worker.shutdown
end

def test_new_tuple_arriving_during_pending_restore_cancels_it
  worker = build_worker(restore_clock: -> { 5.0 })
  worker.start
  @ts.write(notify_tuple(face: :surprised, left: [0xFF0000, :blink], right: [0xFF0000, :blink], duration: 5))
  wait_until { @client.sent.size == 1 }
  @ts.write(notify_tuple(face: :smile, left: [0x00FF00, :solid], right: [0x00FF00, :solid]))
  wait_until { @client.sent.size == 2 }
  sleep 0.5   # well under the 5s restore timer
  # Restore must NOT have fired — sent.size stays 2, not 3
  assert_equal 2, @client.sent.size, "newer tuple should cancel pending restore; saw #{@client.sent.inspect}"
  worker.shutdown
end
```

- [ ] **Step 3.6: Add `restore_clock` injection seam to worker.rb**

Tests cannot block for the real `sleep`. Replace `schedule_restore` with an injectable sleep:

```ruby
def initialize(ts:, client_factory:, logger: nil, backoff: DEFAULT_BACKOFF, sleep_fn: ->(s) { sleep(s) }, restore_sleep_fn: ->(s) { sleep(s) })
  # ... existing
  @restore_sleep_fn = restore_sleep_fn
  @restore_thread   = nil
end

def schedule_restore(seconds)
  @restore_thread = Thread.new(seconds) do |secs|
    @restore_sleep_fn.call(secs)
    @ts.write(RESTORE_TUPLE)
  end
end
```

Update `build_worker` in worker_test.rb to accept `restore_clock:`:

```ruby
def build_worker(restore_clock: ->(_s) { sleep(0.01) })
  Worker.new(
    ts:               @ts,
    client_factory:   -> { @client },
    logger:           @logger,
    backoff:          [0],
    sleep_fn:         ->(_s) { },
    restore_sleep_fn: restore_clock,
  )
end
```

- [ ] **Step 3.7: Rewrite cli_test.rb for new flag set**

Replace existing cli tests with the new flag set. Cover:
- `--face smile --left_led red,blink` → tuple `[:notify, :smile, 0xFF0000, :blink, 0x000000, :solid, nil]`
- `--face smile --left_led 0xFF8800,solid --right_led green,breathing` → tuple `[:notify, :smile, 0xFF8800, :solid, 0x00FF00, :breathing, nil]`
- `--face smile --left_led red,blink --duration 5` → tuple `[:notify, :smile, 0xFF0000, :blink, 0x000000, :solid, 5]`
- `--face smile --duration 0` → exits 2 with "must be a positive integer"
- `--face smile --left_led red` → exits 2 with "must be COLOR,MODE"
- `--face smile --left_led purple,solid` → exits 2 with "must be a preset name ... or hex"
- `--face smile --left_led 0xFFFFFFF,solid` → exits 2 with "out of range" (note 7 hex digits)
- `--face smile --left_led red,wobble` → exits 2 with "mode must be one of"
- Missing `--face` → exits 2 with "--face required"
- `--quiet` suppresses daemon-unavailable stderr; exit still 0
- `STACKCHAN_NOTIFIER_SOCKET` env honored; `--socket` overrides env

```ruby
def test_parses_face_and_left_led_with_preset
  argv = %w[--face smile --left_led red,blink]
  sent = nil
  sender = ->(_sock, tuple) { sent = tuple }
  exit_code = StackchanNotifier::CLI.run(argv, stdout: StringIO.new, stderr: StringIO.new, sender: sender)
  assert_equal 0, exit_code
  assert_equal [:notify, :smile, 0xFF0000, :blink, 0x000000, :solid, nil], sent
end

def test_parses_independent_left_right_with_hex
  argv = %w[--face smile --left_led 0xFF8800,solid --right_led green,breathing]
  sent = nil
  StackchanNotifier::CLI.run(argv, stdout: StringIO.new, stderr: StringIO.new, sender: ->(_s, t) { sent = t })
  assert_equal [:notify, :smile, 0xFF8800, :solid, 0x00FF00, :breathing, nil], sent
end

def test_parses_duration
  argv = %w[--face smile --left_led red,blink --duration 5]
  sent = nil
  StackchanNotifier::CLI.run(argv, stdout: StringIO.new, stderr: StringIO.new, sender: ->(_s, t) { sent = t })
  assert_equal 5, sent[6]
end

def test_zero_duration_rejected
  stderr = StringIO.new
  code = StackchanNotifier::CLI.run(%w[--face smile --duration 0], stdout: StringIO.new, stderr: stderr, sender: ->(*) { })
  assert_equal 2, code
  assert_match(/--duration must be a positive integer/, stderr.string)
end

def test_left_led_without_comma_rejected
  stderr = StringIO.new
  code = StackchanNotifier::CLI.run(%w[--face smile --left_led red], stdout: StringIO.new, stderr: stderr, sender: ->(*) { })
  assert_equal 2, code
  assert_match(/must be COLOR,MODE/, stderr.string)
end

def test_unknown_color_preset_rejected
  stderr = StringIO.new
  code = StackchanNotifier::CLI.run(%w[--face smile --left_led purple,solid], stdout: StringIO.new, stderr: stderr, sender: ->(*) { })
  assert_equal 2, code
  assert_match(/preset name/, stderr.string)
end

def test_color_out_of_range_rejected
  stderr = StringIO.new
  code = StackchanNotifier::CLI.run(%w[--face smile --left_led 0xFFFFFFF,solid], stdout: StringIO.new, stderr: stderr, sender: ->(*) { })
  assert_equal 2, code
  assert_match(/out of range/, stderr.string)
end

def test_invalid_mode_rejected
  stderr = StringIO.new
  code = StackchanNotifier::CLI.run(%w[--face smile --left_led red,wobble], stdout: StringIO.new, stderr: stderr, sender: ->(*) { })
  assert_equal 2, code
  assert_match(/mode must be one of/, stderr.string)
end

def test_missing_face_rejected
  stderr = StringIO.new
  code = StackchanNotifier::CLI.run(%w[--left_led red,blink], stdout: StringIO.new, stderr: stderr, sender: ->(*) { })
  assert_equal 2, code
  assert_match(/--face required/, stderr.string)
end

def test_quiet_suppresses_daemon_unavailable_stderr
  stderr = StringIO.new
  sender = ->(*) { raise DRb::DRbConnError, "down" }
  code = StackchanNotifier::CLI.run(%w[--face smile --left_led red,blink --quiet], stdout: StringIO.new, stderr: stderr, sender: sender)
  assert_equal 0, code
  assert_equal "", stderr.string
end

def test_non_quiet_prints_daemon_unavailable_stderr
  stderr = StringIO.new
  sender = ->(*) { raise DRb::DRbConnError, "down" }
  code = StackchanNotifier::CLI.run(%w[--face smile --left_led red,blink], stdout: StringIO.new, stderr: stderr, sender: sender)
  assert_equal 0, code
  assert_match(/daemon unavailable/, stderr.string)
end

def test_socket_env_var_honored
  ENV["STACKCHAN_NOTIFIER_SOCKET"] = "/tmp/test-env-sock"
  captured = nil
  StackchanNotifier::CLI.run(%w[--face smile --left_led red,blink], stdout: StringIO.new, stderr: StringIO.new,
                              sender: ->(sock, _t) { captured = sock })
  assert_equal "/tmp/test-env-sock", captured
ensure
  ENV.delete("STACKCHAN_NOTIFIER_SOCKET")
end

def test_socket_flag_overrides_env
  ENV["STACKCHAN_NOTIFIER_SOCKET"] = "/tmp/test-env-sock"
  captured = nil
  StackchanNotifier::CLI.run(%w[--face smile --left_led red,blink --socket /tmp/explicit-sock],
                              stdout: StringIO.new, stderr: StringIO.new, sender: ->(sock, _t) { captured = sock })
  assert_equal "/tmp/explicit-sock", captured
ensure
  ENV.delete("STACKCHAN_NOTIFIER_SOCKET")
end
```

- [ ] **Step 3.8: Update daemon_test.rb `test_drb_round_trip_in_process_delivers_tuple_to_ble`**

The test currently writes a 5-element tuple. Update to 7-element with new assertions:

```ruby
def test_drb_round_trip_in_process_delivers_tuple_to_ble
  @daemon.start
  remote = DRbObject.new_with_uri(@daemon.drb_uri)
  remote.write([:notify, :smile, 0xFF8800, :blink, 0x00FF00, :solid, nil])

  wait_until { @client.sent.size == 1 }

  cmds = @client.sent.first
  assert_equal :smile, cmds[0][:name]
  assert_equal 0xFF8800, cmds[1][:value]
  assert_equal :blink,   cmds[1][:mode]
  assert_equal :left,    cmds[1][:side]
  assert_equal 0x00FF00, cmds[2][:value]
  assert_equal :solid,   cmds[2][:mode]
  assert_equal :right,   cmds[2][:side]
end
```

- [ ] **Step 3.9: Run full test suite**

```
cd pc/stackchan-notifier && bundle exec rake test
```
Expected: all PASS

- [ ] **Step 3.10: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/cli.rb \
        pc/stackchan-notifier/lib/stackchan_notifier/worker.rb \
        pc/stackchan-notifier/test/cli_test.rb \
        pc/stackchan-notifier/test/worker_test.rb \
        pc/stackchan-notifier/test/daemon_test.rb
git commit -m "$(cat <<'EOF'
feat(notifier): tuple v2 — independent left/right LEDs, duration timer, color presets

Tuple shape grows from 5 to 7 elements so:
  - left and right LEDs carry independent color+mode (kills the
    "previous --side stays lit" bug — unspecified side defaults to
    0x000000,solid = visually off)
  - an optional duration_or_nil schedules a cancel-on-new-tuple auto-
    restore to neutral + both LEDs off

CLI surface replaced atomically:
  - --hsb / --mode / --side removed
  - --left_led COLOR,MODE / --right_led COLOR,MODE added; COLOR accepts
    either a preset name (red / green / blue / yellow / white / gray /
    black) or a hex literal
  - --duration N (positive integer seconds) added
  - -h now lists preset names with their hex values

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: README rewrite

**Files:**
- Modify: `pc/stackchan-notifier/README.md`

The README's hook examples, CLI reference table, and architecture diagram caption must reflect the new flags + tuple shape + SIGHUP + duration timer.

- [ ] **Step 4.1: Update the "Configure Claude Code hooks" JSON block**

Replace the 4 hook commands with the new flag set, e.g.:

```jsonc
{
  "hooks": {
    "Notification": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face surprised --left_led red,blink --right_led red,blink --duration 10 --quiet"
      }]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face smile --left_led green,solid --right_led green,solid --quiet"
      }]
    }],
    "SubagentStop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face joy --left_led yellow,breathing --right_led yellow,breathing --quiet"
      }]
    }],
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face neutral --left_led blue,blink --right_led blue,blink --duration 3 --quiet"
      }]
    }]
  }
}
```

- [ ] **Step 4.2: Replace the "`stackchan-notify` reference" table**

```markdown
| Flag | Required | Domain |
|---|---|---|
| `--face NAME` | yes | `neutral` / `smile` / `joy` / `surprised` |
| `--left_led COLOR,MODE` | no, default `0x000000,solid` (off) | COLOR = preset name or hex; MODE = `solid` / `blink` / `breathing` / `off` |
| `--right_led COLOR,MODE` | no, default `0x000000,solid` (off) | same format as `--left_led` |
| `--duration N` | no, default no auto-restore | positive integer seconds; on expiry the worker writes a neutral + both-LEDs-off tuple |
| `--socket PATH` | no | overrides default and `STACKCHAN_NOTIFIER_SOCKET` env |
| `--quiet` | no | suppresses "daemon unavailable" stderr |

**Color presets** (resolved case-sensitively against the bare name):

| Name | Hex |
|---|---|
| `red` | `0xFF0000` |
| `green` | `0x00FF00` |
| `blue` | `0x0000FF` |
| `yellow` | `0xFFFF00` |
| `white` | `0xFFFFFF` |
| `gray` | `0x808080` |
| `black` | `0x000000` |

Any 24-bit hex `0x000000..0xFFFFFF` is also accepted directly.
```

- [ ] **Step 4.3: Add a "Signals" subsection under "Run the daemon"**

```markdown
### Signals

| Signal | Effect |
|---|---|
| `INT`, `TERM` | graceful shutdown — worker stops, DRb stops, socket unlinks |
| `HUP` | force-reconnect — worker tears down the current BLE connection and re-scans on the next loop iteration; useful when the device just came back from a silent disconnect |
```

- [ ] **Step 4.4: Update the testing section's test count**

Look for the existing test count line and update it (the actual final count comes from the rake test output after Task 3).

- [ ] **Step 4.5: Commit**

```bash
git add pc/stackchan-notifier/README.md
git commit -m "$(cat <<'EOF'
docs(notifier): rewrite README for tuple-v2 CLI, SIGHUP, color presets, duration

Reflects the new --left_led / --right_led / --duration flags, the color
preset table, the SIGHUP signal, and updates the four hook examples to
exercise the new surface (including a --duration on the Notification
and PreToolUse hooks so spurious-trigger flashes auto-restore to a
quiet neutral face after a few seconds).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Push and update PR

- [ ] **Step 5.1: Push branch**

```bash
git push origin feature/claude-code-notification-bridge
```

- [ ] **Step 5.2: Post follow-up PR comment**

Post a comment on PR #2 summarizing the iter2 batch:

```
gh pr comment 2 --body "$(cat <<'EOF'
## iter2: tuple v2 + retry + SIGHUP + duration + color presets

Four feature commits following the verification fixes. All addressed via the design plan at \`docs/superpowers/plans/2026-05-17-stackchan-notifier-iter2.md\`.

- **retry**: single-shot in-memory retry on transport failure; newer arriving tuple still wins over a pending retry; second failure drops with a warn log.
- **SIGHUP**: posts a force-reconnect sentinel into the TupleSpace so the worker re-scans on the next iteration — manual recovery hook for silent disconnects.
- **tuple v2**: shape grows from 5 to 7 elements (independent left/right LEDs + duration). Unspecified side defaults to \`0x000000,solid\` so the "previous --side stays lit" bug is gone at the design level.
- **CLI**: \`--left_led COLOR,MODE\` / \`--right_led COLOR,MODE\` / \`--duration N\` replace \`--hsb\` / \`--mode\` / \`--side\`. COLOR accepts both preset names (red / green / blue / yellow / white / gray / black) and hex.
- **README**: rewritten for the new CLI + SIGHUP + duration; hook examples updated.

Tests: \`bundle exec rake test\` from \`pc/stackchan-notifier\` — all green.
EOF
)"
```

---

## Self-Review

**Spec coverage** — every issue raised in chat is mapped to a task:

| Issue from chat | Task |
|---|---|
| `--side` exclusivity bug | Task 3 (side becomes implicit — unspecified = 0x000000,solid) |
| Duration support | Task 3 (CLI `--duration` + worker `schedule_restore` / `cancel_pending_restore`) |
| `--hsb` unintuitive; show typical colors | Task 3 (PRESETS, `-h` lists them, README has table) |
| Notify lost during reconnect | Task 1 (single-shot `@pending_retry`) |
| Long-idle disconnect | Task 2 (SIGHUP for manual force re-scan; heartbeat deferred per "Out of scope") |
| Left/right independent specs | Task 3 (tuple shape v2) |
| Daemon scan timing / SIGHUP | Task 2 (SIGHUP trap → worker.force_reconnect → TupleSpace sentinel → ensure_connected) |

**Placeholder scan** — none. Every code step is concrete code; every test step is concrete test code; every commit step is a concrete `git commit` command.

**Type consistency** — `notify_tuple(...)` helper in worker_test.rb has the same 7-element layout used everywhere else; `cmds[0]`, `cmds[1]`, `cmds[2]` in assertions match the `s.face / s.led(:left) / s.led(:right)` order in worker.deliver; `parse_led` returns `[Integer, Symbol]` matched by `opts[:left][0], opts[:left][1]` indexing in CLI#run; `restore_sleep_fn` initializer parameter matches `build_worker(restore_clock:)` test helper.

**Cross-task interaction** — Task 2's `FORCE_RECONNECT_TUPLE` is defined with the 5-element shape and re-declared in Task 3 with the 7-element shape. The intermediate state (after Task 2, before Task 3) has it 5-element, consistent with the tuple shape at that point. This is intentional and called out in Step 2.3.
