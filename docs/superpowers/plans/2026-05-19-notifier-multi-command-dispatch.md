# Notifier Multi-Command Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `pc/stackchan-notifier` from a notify-only Worker into a 3-kind BLE command bus (`:notify` / `:servo` / `:raw`) with per-kind latest-wins coalescing and a daemon-side face→motion table.

**Architecture:** Single `TupleSpace` pattern `[:cmd, Symbol, Hash]`. Worker takes one tuple, drains burst into a per-kind latest-wins list, dispatches each kind to a per-kind handler instance (`NotifyHandler` / `ServoHandler` / `RawHandler`). `NotifyHandler` looks up servo motion from `NotifyMotionTable` and skips it on `--silent`. Three CLI exes share a `CliBase` helper for DRb send + error handling.

**Tech Stack:** Ruby (MRI on Mac), Test::Unit, Rinda TupleSpace, DRb over Unix socket, `stackchan_ble_client` gem (already provides `Client#send`, `Client#raw_send`, `SendBuilder#face/led/head`).

**Spec:** `docs/superpowers/specs/2026-05-19-notifier-multi-command-dispatch-design.md`

**Common setup for every task:**
- cwd: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier`
- `bundle exec rake test` runs the whole suite via the existing Rakefile
- Single test file: `bundle exec rake test TEST=test/path/to/file_test.rb`
- Single test method: `bundle exec ruby -Itest test/path/to/file_test.rb -n test_name`

---

## Task 1: Extend test helper fakes for head + raw_send

**Files:**
- Modify: `pc/stackchan-notifier/test/helper.rb`

The existing `FakeBleClient` / `FakeSendBuilder` only support `face` and `led`. Servo handler needs `head`; raw handler needs `raw_send` on the Client itself.

- [ ] **Step 1: Add `head` method to FakeSendBuilder**

Edit `pc/stackchan-notifier/test/helper.rb`. Replace the `FakeSendBuilder` class (lines 68-79) with:

```ruby
class FakeSendBuilder
  attr_reader :commands
  def initialize
    @commands = []
  end
  def face(name)
    @commands << { kind: :face, name: name }
  end
  def led(form, value = nil, side: :both, mode: :solid)
    @commands << { kind: :led, form: form, value: value, side: side, mode: mode }
  end
  def head(yaw: nil, pitch: nil, time_ms: nil, velocity: nil)
    @commands << { kind: :head, yaw: yaw, pitch: pitch, time_ms: time_ms, velocity: velocity }
  end
end
```

- [ ] **Step 2: Add `raw_send` to FakeBleClient**

In the same file, inside `FakeBleClient` (after the `send` method, before `disconnect`), add:

```ruby
  def raw_send(frame)
    @sent << { kind: :raw_send, frame: frame }
    self
  end
```

The existing `@sent` array now mixes two shapes: `Array` of commands (from `send`) and `Hash` with `:kind => :raw_send` (from `raw_send`). Handler tests will know which they expect.

- [ ] **Step 3: Verify existing tests still pass**

Run: `bundle exec rake test 2>&1 | tail -5`
Expected: existing test count unchanged (no new tests yet), 0 failures, 0 errors. The fake changes are additive.

- [ ] **Step 4: Commit**

```bash
git add pc/stackchan-notifier/test/helper.rb
git commit -m "test(notifier): extend FakeSendBuilder/FakeBleClient with head + raw_send"
```

---

## Task 2: NotifyMotionTable

**Files:**
- Create: `pc/stackchan-notifier/lib/stackchan_notifier/notify_motion_table.rb`
- Create: `pc/stackchan-notifier/test/notify_motion_table_test.rb`

- [ ] **Step 1: Write the failing test**

Create `pc/stackchan-notifier/test/notify_motion_table_test.rb`:

```ruby
require "helper"
require "stackchan_notifier/notify_motion_table"

class NotifyMotionTableTest < Test::Unit::TestCase
  def test_lookup_neutral
    assert_equal({ yaw: 0, pitch: 450, time_ms: 300 },
                 StackchanNotifier::NotifyMotionTable.lookup(:neutral))
  end

  def test_lookup_joy
    assert_equal({ yaw: 0, pitch: 600, time_ms: 250 },
                 StackchanNotifier::NotifyMotionTable.lookup(:joy))
  end

  def test_lookup_smile
    assert_equal({ yaw: 0, pitch: 500, time_ms: 300 },
                 StackchanNotifier::NotifyMotionTable.lookup(:smile))
  end

  def test_lookup_surprised
    assert_equal({ yaw: 0, pitch: 750, time_ms: 120 },
                 StackchanNotifier::NotifyMotionTable.lookup(:surprised))
  end

  def test_lookup_sad
    assert_equal({ yaw: 0, pitch: 280, time_ms: 500 },
                 StackchanNotifier::NotifyMotionTable.lookup(:sad))
  end

  def test_lookup_angry
    assert_equal({ yaw: 150, pitch: 450, time_ms: 200 },
                 StackchanNotifier::NotifyMotionTable.lookup(:angry))
  end

  def test_lookup_unknown_face_returns_nil
    assert_nil StackchanNotifier::NotifyMotionTable.lookup(:bogus)
  end

  def test_motions_is_frozen
    assert_predicate StackchanNotifier::NotifyMotionTable::MOTIONS, :frozen?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/notify_motion_table_test.rb 2>&1 | tail -10`
Expected: `LoadError: cannot load such file -- stackchan_notifier/notify_motion_table` (the file doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `pc/stackchan-notifier/lib/stackchan_notifier/notify_motion_table.rb`:

```ruby
module StackchanNotifier
  module NotifyMotionTable
    # Maps face symbol to a single servo head pose. Sent alongside face/LED
    # when stackchan-notify is invoked without --silent.
    #
    # yaw: -1000..1000 (negative = StackChan's right, positive = its left)
    # pitch: 100..800 (100 = head down, 800 = head up, 450 = level)
    # time_ms: 0..2000 (interpolation duration; 0 = max speed)
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
      MOTIONS[face]
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/notify_motion_table_test.rb 2>&1 | tail -5`
Expected: `8 tests, 8 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/notify_motion_table.rb \
        pc/stackchan-notifier/test/notify_motion_table_test.rb
git commit -m "feat(notifier): add NotifyMotionTable lookup for face→motion mapping"
```

---

## Task 3: ServoHandler

**Files:**
- Create: `pc/stackchan-notifier/lib/stackchan_notifier/handlers/servo_handler.rb`
- Create: `pc/stackchan-notifier/test/handlers/servo_handler_test.rb`

- [ ] **Step 1: Write the failing test**

Create `pc/stackchan-notifier/test/handlers/servo_handler_test.rb`:

```ruby
require "helper"
require "stackchan_notifier/handlers/servo_handler"

class ServoHandlerTest < Test::Unit::TestCase
  def test_deliver_yaw_pitch_time
    client = FakeBleClient.new
    handler = StackchanNotifier::Handlers::ServoHandler.new
    handler.deliver(
      client: client,
      params: { yaw: -300, pitch: 500, time_ms: 2000, velocity: nil },
      ctx: {},
    )
    assert_equal 1, client.sent.size
    cmds = client.sent[0]
    assert_equal [{ kind: :head, yaw: -300, pitch: 500, time_ms: 2000, velocity: nil }], cmds
  end

  def test_deliver_yaw_only_with_velocity
    client = FakeBleClient.new
    handler = StackchanNotifier::Handlers::ServoHandler.new
    handler.deliver(
      client: client,
      params: { yaw: 100, pitch: nil, time_ms: nil, velocity: 50 },
      ctx: {},
    )
    assert_equal [{ kind: :head, yaw: 100, pitch: nil, time_ms: nil, velocity: 50 }], client.sent[0]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/handlers/servo_handler_test.rb 2>&1 | tail -10`
Expected: `LoadError: cannot load such file -- stackchan_notifier/handlers/servo_handler`.

- [ ] **Step 3: Write minimal implementation**

Create `pc/stackchan-notifier/lib/stackchan_notifier/handlers/servo_handler.rb`:

```ruby
module StackchanNotifier
  module Handlers
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
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/handlers/servo_handler_test.rb 2>&1 | tail -5`
Expected: `2 tests, 3 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/handlers/servo_handler.rb \
        pc/stackchan-notifier/test/handlers/servo_handler_test.rb
git commit -m "feat(notifier): add ServoHandler for :servo tuple dispatch"
```

---

## Task 4: RawHandler

**Files:**
- Create: `pc/stackchan-notifier/lib/stackchan_notifier/handlers/raw_handler.rb`
- Create: `pc/stackchan-notifier/test/handlers/raw_handler_test.rb`

- [ ] **Step 1: Write the failing test**

Create `pc/stackchan-notifier/test/handlers/raw_handler_test.rb`:

```ruby
require "helper"
require "stackchan_notifier/handlers/raw_handler"

class RawHandlerTest < Test::Unit::TestCase
  def test_deliver_appends_newline_if_missing
    client = FakeBleClient.new
    handler = StackchanNotifier::Handlers::RawHandler.new
    handler.deliver(
      client: client,
      params: { frame: "<F:2>" },
      ctx: {},
    )
    assert_equal [{ kind: :raw_send, frame: "<F:2>\n" }], client.sent
  end

  def test_deliver_preserves_trailing_newline
    client = FakeBleClient.new
    handler = StackchanNotifier::Handlers::RawHandler.new
    handler.deliver(
      client: client,
      params: { frame: "<L:1,R:0,G:255,B:0,S:B,M:s>\n" },
      ctx: {},
    )
    assert_equal [{ kind: :raw_send, frame: "<L:1,R:0,G:255,B:0,S:B,M:s>\n" }], client.sent
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/handlers/raw_handler_test.rb 2>&1 | tail -10`
Expected: `LoadError: cannot load such file -- stackchan_notifier/handlers/raw_handler`.

- [ ] **Step 3: Write minimal implementation**

Create `pc/stackchan-notifier/lib/stackchan_notifier/handlers/raw_handler.rb`:

```ruby
module StackchanNotifier
  module Handlers
    class RawHandler
      def deliver(client:, params:, ctx:)
        frame = params[:frame]
        frame = frame + "\n" unless frame.end_with?("\n")
        client.raw_send(frame)
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/handlers/raw_handler_test.rb 2>&1 | tail -5`
Expected: `2 tests, 2 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/handlers/raw_handler.rb \
        pc/stackchan-notifier/test/handlers/raw_handler_test.rb
git commit -m "feat(notifier): add RawHandler for :raw tuple dispatch"
```

---

## Task 5: NotifyHandler (face + LED + motion + silent + restore)

**Files:**
- Create: `pc/stackchan-notifier/lib/stackchan_notifier/handlers/notify_handler.rb`
- Create: `pc/stackchan-notifier/test/handlers/notify_handler_test.rb`

This is the biggest handler. It has 4 behaviors:
1. Sends face + LEDs always
2. Sends motion (looked up from NotifyMotionTable) when `silent: false`
3. Skips motion when `silent: true`
4. Schedules a restore tuple back into the TupleSpace after `duration` seconds, preserving the silent flag

- [ ] **Step 1: Write the failing tests (all 5 cases)**

Create `pc/stackchan-notifier/test/handlers/notify_handler_test.rb`:

```ruby
require "helper"
require "stackchan_notifier/handlers/notify_handler"
require "stackchan_notifier/notify_motion_table"

# Minimal stub for ts.write capture
class FakeTupleSpace
  attr_reader :written
  def initialize; @written = []; end
  def write(tuple); @written << tuple; end
end

class NotifyHandlerTest < Test::Unit::TestCase
  def setup
    @client  = FakeBleClient.new
    @ts      = FakeTupleSpace.new
    @sleeps  = []
    @sleep_fn = ->(s) { @sleeps << s }
    @ctx     = { ts: @ts, restore_sleep_fn: @sleep_fn }
    @handler = StackchanNotifier::Handlers::NotifyHandler.new
  end

  def test_face_led_motion_when_not_silent
    @handler.deliver(
      client: @client,
      params: {
        face: :joy,
        left: [0x00FFFF, :blink],
        right: [0x000000, :solid],
        duration: nil,
        silent: false,
      },
      ctx: @ctx,
    )
    assert_equal 1, @client.sent.size
    cmds = @client.sent[0]
    assert_equal({ kind: :face, name: :joy }, cmds[0])
    assert_equal({ kind: :led, form: :hsb, value: 0x00FFFF, side: :left,  mode: :blink }, cmds[1])
    assert_equal({ kind: :led, form: :hsb, value: 0x000000, side: :right, mode: :solid }, cmds[2])
    # joy motion: yaw 0, pitch 600, time_ms 250
    assert_equal({ kind: :head, yaw: 0, pitch: 600, time_ms: 250, velocity: nil }, cmds[3])
    assert_equal 4, cmds.size
  end

  def test_face_led_only_when_silent
    @handler.deliver(
      client: @client,
      params: {
        face: :joy,
        left: [0x00FFFF, :blink],
        right: [0x000000, :solid],
        duration: nil,
        silent: true,
      },
      ctx: @ctx,
    )
    cmds = @client.sent[0]
    assert_equal 3, cmds.size
    assert(cmds.none? { |c| c[:kind] == :head }, "expected no :head command when silent")
  end

  def test_unknown_face_skips_motion
    @handler.deliver(
      client: @client,
      params: {
        face: :bogus,
        left: [0x000000, :solid],
        right: [0x000000, :solid],
        duration: nil,
        silent: false,
      },
      ctx: @ctx,
    )
    cmds = @client.sent[0]
    # face is still attempted (the firmware decides), but no :head appended
    assert(cmds.none? { |c| c[:kind] == :head }, "expected no :head for unknown face")
  end

  def test_restore_tuple_written_after_duration_when_not_silent
    @handler.deliver(
      client: @client,
      params: {
        face: :joy,
        left: [0x00FFFF, :solid],
        right: [0x000000, :solid],
        duration: 2,
        silent: false,
      },
      ctx: @ctx,
    )
    # restore thread runs in background; wait for the write
    wait_until(timeout: 1.0) { !@ts.written.empty? }
    assert_equal 1, @ts.written.size
    restore = @ts.written[0]
    assert_equal :cmd, restore[0]
    assert_equal :notify, restore[1]
    assert_equal :neutral, restore[2][:face]
    assert_equal [0x000000, :solid], restore[2][:left]
    assert_equal [0x000000, :solid], restore[2][:right]
    assert_equal false, restore[2][:silent]   # silent preserved
    assert_nil restore[2][:duration]          # restore itself has no further restore
    assert_equal [2], @sleeps                 # restore_sleep_fn called with duration
  end

  def test_restore_preserves_silent_flag
    @handler.deliver(
      client: @client,
      params: {
        face: :joy,
        left: [0x000000, :solid],
        right: [0x000000, :solid],
        duration: 1,
        silent: true,
      },
      ctx: @ctx,
    )
    wait_until(timeout: 1.0) { !@ts.written.empty? }
    assert_equal true, @ts.written[0][2][:silent]
  end

  def test_second_deliver_cancels_pending_restore
    # First deliver schedules a restore that sleeps for 5 seconds — long enough
    # that the second deliver's cancel can race in before it fires.
    slow_sleep_holds = []
    slow_sleep_fn = ->(s) {
      slow_sleep_holds << s
      sleep s   # actual sleep so the kill can interrupt
    }
    ctx = { ts: @ts, restore_sleep_fn: slow_sleep_fn }

    @handler.deliver(
      client: @client,
      params: {
        face: :joy, left: [0,:solid], right: [0,:solid],
        duration: 5, silent: false,
      },
      ctx: ctx,
    )
    sleep 0.05   # let restore thread start sleeping

    @handler.deliver(
      client: @client,
      params: {
        face: :sad, left: [0,:solid], right: [0,:solid],
        duration: nil, silent: false,
      },
      ctx: ctx,
    )

    sleep 0.1
    # Original restore was killed before it could ts.write
    assert_empty @ts.written, "first restore should have been cancelled before writing"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rake test TEST=test/handlers/notify_handler_test.rb 2>&1 | tail -15`
Expected: `LoadError: cannot load such file -- stackchan_notifier/handlers/notify_handler`.

- [ ] **Step 3: Write the implementation**

Create `pc/stackchan-notifier/lib/stackchan_notifier/handlers/notify_handler.rb`:

```ruby
require_relative "../notify_motion_table"

module StackchanNotifier
  module Handlers
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
            if motion
              s.head(
                yaw:      motion[:yaw],
                pitch:    motion[:pitch],
                time_ms:  motion[:time_ms],
                velocity: nil,
              )
            end
          end
        end
        if params[:duration] && params[:duration] > 0
          schedule_restore(ctx, params[:duration], silent: params[:silent])
        end
      end

      private

      def schedule_restore(ctx, seconds, silent:)
        ts        = ctx[:ts]
        sleep_fn  = ctx[:restore_sleep_fn]
        @restore_thread = Thread.new(ts, seconds, silent, sleep_fn) do |t, secs, sil, sf|
          sf.call(secs)
          t.write([:cmd, :notify, {
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
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rake test TEST=test/handlers/notify_handler_test.rb 2>&1 | tail -5`
Expected: `6 tests, X assertions, 0 failures, 0 errors`.

If the cancel-pending-restore test is flaky (timing-sensitive), tighten the `sleep 0.05` and `sleep 0.1` values or rerun once.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/handlers/notify_handler.rb \
        pc/stackchan-notifier/test/handlers/notify_handler_test.rb
git commit -m "feat(notifier): add NotifyHandler with face+LED+motion+silent+restore"
```

---

## Task 6: CliBase (shared DRb send helper)

**Files:**
- Create: `pc/stackchan-notifier/lib/stackchan_notifier/cli_base.rb`
- Create: `pc/stackchan-notifier/test/cli_base_test.rb`

- [ ] **Step 1: Write the failing test**

Create `pc/stackchan-notifier/test/cli_base_test.rb`:

```ruby
require "helper"
require "stackchan_notifier/cli_base"

class CliBaseTest < Test::Unit::TestCase
  def test_try_send_calls_sender_with_socket_and_tuple
    sent = nil
    sender = ->(socket, tuple) { sent = [socket, tuple] }
    stderr = StringIO.new
    StackchanNotifier::CliBase.try_send(
      sender: sender,
      socket: "/tmp/xx.sock",
      tuple:  [:cmd, :notify, { face: :joy }],
      stderr: stderr,
      quiet:  false,
      program_name: "stackchan-notify",
    )
    assert_equal ["/tmp/xx.sock", [:cmd, :notify, { face: :joy }]], sent
    assert_equal "", stderr.string
  end

  def test_try_send_swallows_daemon_unavailable_and_warns
    sender = ->(_s, _t) { raise Errno::ENOENT, "No such file" }
    stderr = StringIO.new
    StackchanNotifier::CliBase.try_send(
      sender: sender,
      socket: "/tmp/missing.sock",
      tuple:  [:cmd, :notify, {}],
      stderr: stderr,
      quiet:  false,
      program_name: "stackchan-notify",
    )
    assert_match(/stackchan-notify: daemon unavailable/, stderr.string)
    assert_match(/Errno::ENOENT/, stderr.string)
  end

  def test_try_send_quiet_suppresses_warn
    sender = ->(_s, _t) { raise Errno::ENOENT, "No such file" }
    stderr = StringIO.new
    StackchanNotifier::CliBase.try_send(
      sender: sender, socket: "/tmp/x.sock", tuple: [:cmd, :raw, {}],
      stderr: stderr, quiet: true, program_name: "stackchan-raw",
    )
    assert_equal "", stderr.string
  end

  def test_try_send_swallows_drb_conn_error
    sender = ->(_s, _t) { raise DRb::DRbConnError, "boom" }
    stderr = StringIO.new
    StackchanNotifier::CliBase.try_send(
      sender: sender, socket: "/tmp/x.sock", tuple: [:cmd, :raw, {}],
      stderr: stderr, quiet: false, program_name: "stackchan-raw",
    )
    assert_match(/DRb::DRbConnError/, stderr.string)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/cli_base_test.rb 2>&1 | tail -10`
Expected: `LoadError: cannot load such file -- stackchan_notifier/cli_base`.

- [ ] **Step 3: Write minimal implementation**

Create `pc/stackchan-notifier/lib/stackchan_notifier/cli_base.rb`:

```ruby
require "drb/drb"
require "drb/unix"

module StackchanNotifier
  module CliBase
    EXIT_OK      = 0
    EXIT_BAD_ARG = 2

    SWALLOWED_ERRORS = [
      DRb::DRbConnError,
      Errno::ENOENT,
      Errno::ECONNREFUSED,
      Errno::EACCES,
    ].freeze

    module_function

    def drb_send(socket, tuple)
      DRb.start_service
      DRbObject.new_with_uri("drbunix:#{socket}").write(tuple)
    end

    def try_send(sender:, socket:, tuple:, stderr:, quiet:, program_name:)
      sender.call(socket, tuple)
    rescue *SWALLOWED_ERRORS => e
      return if quiet
      stderr.puts "#{program_name}: daemon unavailable (#{e.class}: #{e.message})"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/cli_base_test.rb 2>&1 | tail -5`
Expected: `4 tests, 6 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/cli_base.rb \
        pc/stackchan-notifier/test/cli_base_test.rb
git commit -m "feat(notifier): add CliBase shared DRb send + error handling"
```

---

## Task 7: Refactor stackchan-notify CLI (new tuple shape + --silent + CliBase)

**Files:**
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/cli.rb`
- Modify: `pc/stackchan-notifier/test/cli_test.rb`

- [ ] **Step 1: Update tests to assert new tuple shape**

Open `pc/stackchan-notifier/test/cli_test.rb` and find every assertion that expects the old 7-tuple shape `[:notify, face, ...]`. They need to expect `[:cmd, :notify, hash]` instead.

Read the file first:
```bash
cat pc/stackchan-notifier/test/cli_test.rb
```

For each old-shape assertion like `assert_equal [:notify, :joy, ...], sent_tuple` rewrite to:
```ruby
assert_equal :cmd,    sent_tuple[0]
assert_equal :notify, sent_tuple[1]
params = sent_tuple[2]
assert_equal :joy, params[:face]
assert_equal [0x00FFFF, :blink], params[:left]
assert_equal [0x000000, :solid], params[:right]
assert_equal 3, params[:duration]
assert_equal false, params[:silent]   # default
```

Add a new test for the `--silent` flag:

```ruby
def test_silent_flag_sets_silent_true_in_tuple
  sent = []
  sender = ->(_socket, tuple) { sent << tuple }
  StackchanNotifier::CLI.run(
    %w[--face joy --silent],
    stdout: StringIO.new, stderr: StringIO.new, sender: sender,
  )
  assert_equal true, sent[0][2][:silent]
end

def test_default_silent_is_false
  sent = []
  sender = ->(_socket, tuple) { sent << tuple }
  StackchanNotifier::CLI.run(
    %w[--face joy],
    stdout: StringIO.new, stderr: StringIO.new, sender: sender,
  )
  assert_equal false, sent[0][2][:silent]
end
```

- [ ] **Step 2: Run modified tests to verify they fail**

Run: `bundle exec rake test TEST=test/cli_test.rb 2>&1 | tail -15`
Expected: most tests now FAIL because CLI is still writing the old 7-tuple shape. The new `--silent` tests will also fail (option not registered).

- [ ] **Step 3: Update CLI implementation**

Edit `pc/stackchan-notifier/lib/stackchan_notifier/cli.rb`. Change:

(a) The `run` method body — replace the `tuple = [:notify, opts[:face], ...]` block (lines 53-60) with:

```ruby
      tuple = [:cmd, :notify, {
        face:     opts[:face],
        left:     opts[:left],
        right:    opts[:right],
        duration: opts[:duration],
        silent:   opts[:silent],
      }]
      try_send(opts[:socket], tuple, quiet: opts[:quiet])
      EXIT_OK
```

(b) The `parse` method `result` hash — add `silent: false` to the defaults:

```ruby
      result = {
        face:     nil,
        left:     DEFAULT_LED,
        right:    DEFAULT_LED,
        duration: nil,
        silent:   false,                                       # new
        socket:   ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:    false,
      }
```

(c) The `parse` method `OptionParser.new` block — add the `--silent` option (after the existing `--socket` option):

```ruby
        o.on("--silent",               "suppress servo motion (face + LED still sent)")   { result[:silent] = true }
```

(d) Remove the `drb_send` class method and the `try_send` private method — replace them by delegating to `CliBase`:

At the top of `cli.rb`, after the `require_relative "../stackchan_notifier"` line, add:
```ruby
require_relative "cli_base"
```

Replace `self.run(argv, stdout: ..., sender: method(:drb_send))` (around line 36) with:
```ruby
    def self.run(argv, stdout: $stdout, stderr: $stderr, sender: CliBase.method(:drb_send))
      new(stdout: stdout, stderr: stderr, sender: sender).run(argv)
    end
```

Remove the `self.drb_send` method entirely (lines 40-43).

Replace the `try_send` private method (lines 132-137) with:
```ruby
    def try_send(socket, tuple, quiet:)
      CliBase.try_send(
        sender: @sender, socket: socket, tuple: tuple,
        stderr: @stderr, quiet: quiet, program_name: "stackchan-notify",
      )
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rake test TEST=test/cli_test.rb 2>&1 | tail -5`
Expected: 0 failures, 0 errors. (Existing test count + the 2 new `--silent` tests.)

If any pre-existing test was asserting `[:notify, ...]` shape and you missed it, fix the assertion in test/cli_test.rb and rerun.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/cli.rb \
        pc/stackchan-notifier/test/cli_test.rb
git commit -m "refactor(notifier): cli writes [:cmd,:notify,Hash] tuple + adds --silent"
```

---

## Task 8: stackchan-servo CLI

**Files:**
- Create: `pc/stackchan-notifier/lib/stackchan_notifier/servo_cli.rb`
- Create: `pc/stackchan-notifier/test/servo_cli_test.rb`
- Create: `pc/stackchan-notifier/exe/stackchan-servo`

- [ ] **Step 1: Write the failing test**

Create `pc/stackchan-notifier/test/servo_cli_test.rb`:

```ruby
require "helper"
require "stackchan_notifier/servo_cli"

class ServoCLITest < Test::Unit::TestCase
  def test_yaw_pitch_time_writes_expected_tuple
    sent = []
    sender = ->(_s, t) { sent << t }
    rc = StackchanNotifier::ServoCLI.run(
      %w[--yaw -300 --pitch 500 --time 2000],
      stdout: StringIO.new, stderr: StringIO.new, sender: sender,
    )
    assert_equal 0, rc
    assert_equal :cmd,   sent[0][0]
    assert_equal :servo, sent[0][1]
    assert_equal({ yaw: -300, pitch: 500, time_ms: 2000, velocity: nil }, sent[0][2])
  end

  def test_yaw_only_with_velocity
    sent = []
    sender = ->(_s, t) { sent << t }
    StackchanNotifier::ServoCLI.run(
      %w[--yaw 100 --velocity 50],
      stdout: StringIO.new, stderr: StringIO.new, sender: sender,
    )
    assert_equal({ yaw: 100, pitch: nil, time_ms: nil, velocity: 50 }, sent[0][2])
  end

  def test_missing_both_yaw_and_pitch_exits_bad_arg
    stderr = StringIO.new
    sent = []
    sender = ->(_s, t) { sent << t }
    rc = StackchanNotifier::ServoCLI.run(
      %w[--time 1000],
      stdout: StringIO.new, stderr: stderr, sender: sender,
    )
    assert_equal 2, rc
    assert_match(/yaw or --pitch/, stderr.string)
    assert_empty sent
  end

  def test_invalid_integer_exits_bad_arg
    stderr = StringIO.new
    rc = StackchanNotifier::ServoCLI.run(
      %w[--yaw foo],
      stdout: StringIO.new, stderr: stderr, sender: ->(*) {},
    )
    assert_equal 2, rc
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/servo_cli_test.rb 2>&1 | tail -10`
Expected: `LoadError: cannot load such file -- stackchan_notifier/servo_cli`.

- [ ] **Step 3: Write minimal implementation**

Create `pc/stackchan-notifier/lib/stackchan_notifier/servo_cli.rb`:

```ruby
require "optparse"

require_relative "../stackchan_notifier"
require_relative "cli_base"

module StackchanNotifier
  class ServoCLI
    def self.run(argv, stdout: $stdout, stderr: $stderr, sender: CliBase.method(:drb_send))
      new(stdout: stdout, stderr: stderr, sender: sender).run(argv)
    end

    def initialize(stdout:, stderr:, sender:)
      @stdout = stdout
      @stderr = stderr
      @sender = sender
    end

    def run(argv)
      opts = parse(argv)
      tuple = [:cmd, :servo, {
        yaw:      opts[:yaw],
        pitch:    opts[:pitch],
        time_ms:  opts[:time_ms],
        velocity: opts[:velocity],
      }]
      CliBase.try_send(
        sender: @sender, socket: opts[:socket], tuple: tuple,
        stderr: @stderr, quiet: opts[:quiet], program_name: "stackchan-servo",
      )
      CliBase::EXIT_OK
    rescue OptionParser::ParseError, ArgumentError => e
      @stderr.puts "stackchan-servo: #{e.message}"
      CliBase::EXIT_BAD_ARG
    end

    private

    def parse(argv)
      result = {
        yaw:      nil,
        pitch:    nil,
        time_ms:  nil,
        velocity: nil,
        socket:   ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:    false,
      }
      parser = OptionParser.new do |o|
        o.banner = "Usage: stackchan-servo [--yaw N] [--pitch N] [--time N] [--velocity N] [--socket PATH] [--quiet]"
        o.on("--yaw N",      Integer) { |v| result[:yaw]      = v }
        o.on("--pitch N",    Integer) { |v| result[:pitch]    = v }
        o.on("--time N",     Integer) { |v| result[:time_ms]  = v }
        o.on("--velocity N", Integer) { |v| result[:velocity] = v }
        o.on("--socket PATH")         { |v| result[:socket]   = v }
        o.on("--quiet")               {     result[:quiet]    = true }
        o.on("-h", "--help") { @stdout.puts(o); exit CliBase::EXIT_OK }
      end
      parser.parse!(argv.dup)
      if result[:yaw].nil? && result[:pitch].nil?
        raise ArgumentError, "at least one of --yaw or --pitch required"
      end
      result
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/servo_cli_test.rb 2>&1 | tail -5`
Expected: `4 tests, X assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Create the exe shim**

Create `pc/stackchan-notifier/exe/stackchan-servo`:

```ruby
#!/usr/bin/env ruby
require "bundler/setup"
require "stackchan_notifier/servo_cli"
exit StackchanNotifier::ServoCLI.run(ARGV.dup)
```

Make executable:
```bash
chmod +x pc/stackchan-notifier/exe/stackchan-servo
```

- [ ] **Step 6: Smoke test the exe (no daemon, expect daemon-unavailable warn)**

Run:
```bash
cd pc/stackchan-notifier && bundle exec exe/stackchan-servo --yaw 0 --pitch 450 --quiet 2>&1; echo "EXIT=$?"
```
Expected: `EXIT=0` (the `--quiet` suppresses the daemon-unavailable warn).

- [ ] **Step 7: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/servo_cli.rb \
        pc/stackchan-notifier/test/servo_cli_test.rb \
        pc/stackchan-notifier/exe/stackchan-servo
git commit -m "feat(notifier): add stackchan-servo CLI emitting [:cmd,:servo,Hash]"
```

---

## Task 9: stackchan-raw CLI

**Files:**
- Create: `pc/stackchan-notifier/lib/stackchan_notifier/raw_cli.rb`
- Create: `pc/stackchan-notifier/test/raw_cli_test.rb`
- Create: `pc/stackchan-notifier/exe/stackchan-raw`

- [ ] **Step 1: Write the failing test**

Create `pc/stackchan-notifier/test/raw_cli_test.rb`:

```ruby
require "helper"
require "stackchan_notifier/raw_cli"

class RawCLITest < Test::Unit::TestCase
  def test_frame_writes_expected_tuple
    sent = []
    sender = ->(_s, t) { sent << t }
    rc = StackchanNotifier::RawCLI.run(
      ["--frame", "<F:2>"],
      stdout: StringIO.new, stderr: StringIO.new, sender: sender,
    )
    assert_equal 0, rc
    assert_equal [:cmd, :raw, { frame: "<F:2>" }], sent[0]
  end

  def test_missing_frame_exits_bad_arg
    stderr = StringIO.new
    rc = StackchanNotifier::RawCLI.run(
      [], stdout: StringIO.new, stderr: stderr, sender: ->(*) {},
    )
    assert_equal 2, rc
    assert_match(/--frame/, stderr.string)
  end

  def test_empty_frame_exits_bad_arg
    stderr = StringIO.new
    rc = StackchanNotifier::RawCLI.run(
      ["--frame", ""], stdout: StringIO.new, stderr: stderr, sender: ->(*) {},
    )
    assert_equal 2, rc
    assert_match(/frame must not be empty/, stderr.string)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/raw_cli_test.rb 2>&1 | tail -10`
Expected: `LoadError: cannot load such file -- stackchan_notifier/raw_cli`.

- [ ] **Step 3: Write minimal implementation**

Create `pc/stackchan-notifier/lib/stackchan_notifier/raw_cli.rb`:

```ruby
require "optparse"

require_relative "../stackchan_notifier"
require_relative "cli_base"

module StackchanNotifier
  class RawCLI
    def self.run(argv, stdout: $stdout, stderr: $stderr, sender: CliBase.method(:drb_send))
      new(stdout: stdout, stderr: stderr, sender: sender).run(argv)
    end

    def initialize(stdout:, stderr:, sender:)
      @stdout = stdout
      @stderr = stderr
      @sender = sender
    end

    def run(argv)
      opts = parse(argv)
      tuple = [:cmd, :raw, { frame: opts[:frame] }]
      CliBase.try_send(
        sender: @sender, socket: opts[:socket], tuple: tuple,
        stderr: @stderr, quiet: opts[:quiet], program_name: "stackchan-raw",
      )
      CliBase::EXIT_OK
    rescue OptionParser::ParseError, ArgumentError => e
      @stderr.puts "stackchan-raw: #{e.message}"
      CliBase::EXIT_BAD_ARG
    end

    private

    def parse(argv)
      result = {
        frame:  nil,
        socket: ENV["STACKCHAN_NOTIFIER_SOCKET"] || StackchanNotifier.default_socket_path,
        quiet:  false,
      }
      parser = OptionParser.new do |o|
        o.banner = "Usage: stackchan-raw --frame STRING [--socket PATH] [--quiet]"
        o.on("--frame STRING") { |v| result[:frame]  = v }
        o.on("--socket PATH")  { |v| result[:socket] = v }
        o.on("--quiet")        {     result[:quiet]  = true }
        o.on("-h", "--help") { @stdout.puts(o); exit CliBase::EXIT_OK }
      end
      parser.parse!(argv.dup)
      raise ArgumentError, "--frame STRING required" if result[:frame].nil?
      raise ArgumentError, "--frame must not be empty" if result[:frame].empty?
      result
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/raw_cli_test.rb 2>&1 | tail -5`
Expected: `3 tests, X assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Create the exe shim**

Create `pc/stackchan-notifier/exe/stackchan-raw`:

```ruby
#!/usr/bin/env ruby
require "bundler/setup"
require "stackchan_notifier/raw_cli"
exit StackchanNotifier::RawCLI.run(ARGV.dup)
```

```bash
chmod +x pc/stackchan-notifier/exe/stackchan-raw
```

- [ ] **Step 6: Smoke test the exe**

Run:
```bash
cd pc/stackchan-notifier && bundle exec exe/stackchan-raw --frame '<F:2>' --quiet 2>&1; echo "EXIT=$?"
```
Expected: `EXIT=0`.

- [ ] **Step 7: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/raw_cli.rb \
        pc/stackchan-notifier/test/raw_cli_test.rb \
        pc/stackchan-notifier/exe/stackchan-raw
git commit -m "feat(notifier): add stackchan-raw CLI emitting [:cmd,:raw,Hash]"
```

---

## Task 10: Refactor Worker (TUPLE_PATTERN + drain_latest_per_kind + HANDLERS dispatch)

**Files:**
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb`
- Modify: `pc/stackchan-notifier/test/worker_test.rb`

This is the biggest single task. Worker test will be largely rewritten.

- [ ] **Step 1: Inspect current worker tests**

Read the full test file to understand existing coverage:
```bash
cat pc/stackchan-notifier/test/worker_test.rb
```

Tests assert against old 7-tuple shape and against the old `deliver(tuple)` private. They need to be rewritten to:
- Build `[:cmd, :notify, hash]` tuples
- Inject a fake handler registry (no real handlers needed for Worker tests)
- Assert handler invocation order on burst

- [ ] **Step 2: Rewrite the worker test file**

Replace `pc/stackchan-notifier/test/worker_test.rb` with:

```ruby
require "helper"
require "stackchan_notifier/tuple_space4ractor"
require "stackchan_notifier/worker"

# Records each (kind, params, ctx) deliver call; lets a test script raise on demand.
class RecordingHandler
  attr_reader :calls
  def initialize(kind)
    @kind  = kind
    @calls = []
    @raise = nil
  end
  def raise_on_next(error_class, message = "boom")
    @raise = [error_class, message]
  end
  def deliver(client:, params:, ctx:)
    @calls << { kind: @kind, params: params }
    if (r = @raise)
      @raise = nil
      raise r[0], r[1]
    end
  end
end

def make_handlers_with(notify: RecordingHandler.new(:notify),
                      servo:  RecordingHandler.new(:servo),
                      raw:    RecordingHandler.new(:raw))
  { notify: notify, servo: servo, raw: raw }
end

class WorkerSingleNotifyTest < Test::Unit::TestCase
  def setup
    @ts = StackchanNotifier::TupleSpace4Ractor.new
    @client = FakeBleClient.new
    @notify_h = RecordingHandler.new(:notify)
    @worker = StackchanNotifier::Worker.new(
      ts:             @ts,
      client_factory: -> { @client },
      handlers:       make_handlers_with(notify: @notify_h),
      logger:         build_capturing_logger([]),
    )
    @worker.start
  end

  def teardown
    @worker.shutdown(timeout: 2.0)
  end

  def test_notify_tuple_dispatched_to_notify_handler
    @ts.write([:cmd, :notify, { face: :joy, left: [0,:solid], right: [0,:solid], duration: nil, silent: false }])
    wait_until(timeout: 1.0) { !@notify_h.calls.empty? }
    assert_equal 1, @notify_h.calls.size
    assert_equal :joy, @notify_h.calls[0][:params][:face]
  end
end

class WorkerDrainPerKindTest < Test::Unit::TestCase
  def setup
    @ts = StackchanNotifier::TupleSpace4Ractor.new
    @client = FakeBleClient.new
    @notify_h = RecordingHandler.new(:notify)
    @servo_h  = RecordingHandler.new(:servo)
    @raw_h    = RecordingHandler.new(:raw)
    @worker = StackchanNotifier::Worker.new(
      ts:             @ts,
      client_factory: -> { @client },
      handlers:       { notify: @notify_h, servo: @servo_h, raw: @raw_h },
      logger:         build_capturing_logger([]),
    )
  end

  def teardown
    @worker.shutdown(timeout: 2.0) if @worker.thread
  end

  def test_burst_collapses_to_latest_per_kind_in_first_seen_order
    # Pre-load tuples BEFORE start so the take + drain sees them in one shot.
    @ts.write([:cmd, :notify, { face: :smile, left: [0,:solid], right: [0,:solid], duration: nil, silent: false }])
    @ts.write([:cmd, :servo,  { yaw: 100, pitch: nil, time_ms: nil, velocity: nil }])
    @ts.write([:cmd, :notify, { face: :joy,   left: [0,:solid], right: [0,:solid], duration: nil, silent: false }])
    @ts.write([:cmd, :servo,  { yaw: 200, pitch: nil, time_ms: nil, velocity: nil }])

    @worker.start
    wait_until(timeout: 1.0) { @notify_h.calls.size >= 1 && @servo_h.calls.size >= 1 }

    # latest-wins per kind: notify=:joy (last), servo=yaw 200 (last)
    assert_equal 1, @notify_h.calls.size
    assert_equal :joy, @notify_h.calls[0][:params][:face]
    assert_equal 1, @servo_h.calls.size
    assert_equal 200, @servo_h.calls[0][:params][:yaw]
  end

  def test_unknown_kind_is_logged_warn_and_skipped
    log_events = []
    @worker = StackchanNotifier::Worker.new(
      ts:             @ts,
      client_factory: -> { @client },
      handlers:       { notify: @notify_h },          # no :servo handler
      logger:         build_severity_capturing_logger(log_events),
    )
    @ts.write([:cmd, :servo, { yaw: 0 }])
    @worker.start

    wait_until(timeout: 1.0) { log_events.any? { |sev, _| sev == "WARN" } }
    warn_msg = log_events.find { |sev, _| sev == "WARN" }[1]
    assert_match(/no handler for kind=servo/, warn_msg)
    assert_empty @notify_h.calls
  end
end
```

- [ ] **Step 3: Run the rewritten tests to verify they fail**

Run: `bundle exec rake test TEST=test/worker_test.rb 2>&1 | tail -15`
Expected: failures because `Worker.new` does not yet accept a `handlers:` keyword, TUPLE_PATTERN is still old shape, drain still latest-tuple not latest-per-kind, etc.

- [ ] **Step 4: Rewrite the Worker implementation**

Replace the body of `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb` with:

```ruby
require "rinda/tuplespace"
require "stackchan_ble_client"

require_relative "tuple_space4ractor"
require_relative "handlers/notify_handler"
require_relative "handlers/servo_handler"
require_relative "handlers/raw_handler"

module StackchanNotifier
  class Worker
    TUPLE_PATTERN            = [:cmd, Symbol, Hash].freeze
    SHUTDOWN_SENTINEL        = :__shutdown__
    FORCE_RECONNECT_SENTINEL = :__force_reconnect__
    DEFAULT_BACKOFF          = [1, 2, 4, 8, 30].freeze
    SHUTDOWN_TUPLE           = [:cmd, SHUTDOWN_SENTINEL,        {}].freeze
    FORCE_RECONNECT_TUPLE    = [:cmd, FORCE_RECONNECT_SENTINEL, {}].freeze

    DEFAULT_HANDLERS = {
      notify: Handlers::NotifyHandler.new,
      servo:  Handlers::ServoHandler.new,
      raw:    Handlers::RawHandler.new,
    }.freeze

    GATT_CACHE_TRAP_THRESHOLD = 3
    GATT_CACHE_TRAP_PATTERN   = /discoverServices timed out/i

    def initialize(ts:, client_factory:, logger: nil, handlers: nil,
                   backoff: DEFAULT_BACKOFF, sleep_fn: ->(s) { sleep(s) },
                   restore_sleep_fn: ->(s) { sleep(s) })
      @ts               = ts
      @client_factory   = client_factory
      @logger           = logger
      @handlers         = handlers || DEFAULT_HANDLERS
      @backoff          = backoff
      @sleep_fn         = sleep_fn
      @restore_sleep_fn = restore_sleep_fn
      @shutdown               = false
      @client                 = nil
      @connect_attempt        = 0
      @thread                 = nil
      @gatt_cache_trap_count  = 0
      @gatt_cache_trap_logged = false
    end

    def start
      raise Error, "worker already started" if @thread
      @thread = Thread.new { run_loop }
      self
    end

    def shutdown(timeout: 5.0)
      return self unless @thread
      @shutdown = true
      @ts.write(SHUTDOWN_TUPLE)
      joined = @thread.join(timeout)
      log(:warn, "worker thread did not exit within #{timeout}s") unless joined
      @thread = nil
      self
    end

    def thread
      @thread
    end

    def force_reconnect
      @ts.write(FORCE_RECONNECT_TUPLE)
    end

    private

    def run_loop
      @pending_retry = nil
      @pending_force_reconnect = false
      until @shutdown
        ensure_connected
        break if @shutdown

        per_kind_list, was_retry = next_burst_to_deliver
        next if per_kind_list.nil? || per_kind_list.empty?
        if @pending_force_reconnect
          @pending_force_reconnect = false
          log(:info, "force reconnect requested; tearing down current BLE connection")
          disconnect_quietly
          @pending_retry = nil
          next
        end
        break if @shutdown

        if deliver_burst(per_kind_list)
          @pending_retry = nil
        elsif was_retry
          log(:warn, "send failed twice; dropping #{per_kind_list.inspect}")
          @pending_retry = nil
        else
          @pending_retry = per_kind_list
        end
      end
      disconnect_quietly
    end

    def ensure_connected
      while !@shutdown && @client.nil?
        begin
          fresh = @client_factory.call
          fresh.connect
          @client = fresh
          @connect_attempt        = 0
          @gatt_cache_trap_count  = 0
          @gatt_cache_trap_logged = false
          log(:info, "BLE connected")
        rescue StackchanBleClient::Error, IOError, SystemCallError => e
          @connect_attempt += 1
          track_gatt_cache_trap(e)
          delay = @backoff[[@connect_attempt - 1, @backoff.size - 1].min]
          log(:warn, "connect failed (attempt=#{@connect_attempt}): #{e.class}: #{e.message}; sleeping #{delay}s")
          maybe_log_gatt_cache_trap
          @sleep_fn.call(delay)
        end
      end
    end

    def track_gatt_cache_trap(error)
      if GATT_CACHE_TRAP_PATTERN.match?(error.message.to_s)
        @gatt_cache_trap_count += 1
      else
        @gatt_cache_trap_count  = 0
        @gatt_cache_trap_logged = false
      end
    end

    def maybe_log_gatt_cache_trap
      return if @gatt_cache_trap_logged
      return if @gatt_cache_trap_count < GATT_CACHE_TRAP_THRESHOLD
      log(:error,
          "BLE GATT discovery stuck (#{@gatt_cache_trap_count} consecutive `discoverServices` timeouts). " \
          "macOS CoreBluetooth has cached a stale GATT for this device and there is no programmatic " \
          "API to clear it — please power-cycle the StackChan (unplug/replug USB-C or hard-reset the " \
          "M5Stack). The daemon will keep retrying in the background; once the device reboots the next " \
          "scan should succeed.")
      @gatt_cache_trap_logged = true
    end

    def next_burst_to_deliver
      if @pending_retry
        # Peek if newer tuples have arrived; if so, drain them as fresh burst
        newer = try_take_newer
        if newer
          @pending_retry = nil
          [drain_latest_per_kind(newer), false]
        else
          [@pending_retry, true]
        end
      else
        initial = @ts.take(TUPLE_PATTERN)
        return [nil, false] if shutdown_sentinel?(initial)
        if force_reconnect_sentinel?(initial)
          @pending_force_reconnect = true
          return [[], false]
        end
        [drain_latest_per_kind(initial), false]
      end
    end

    def try_take_newer
      @ts.take_nonblocking(TUPLE_PATTERN)
    rescue Rinda::RequestExpiredError
      nil
    end

    # Collapse the queued burst into [[:kind, latest_params], ...] in first-
    # occurrence order. Sentinel tuples surfaced during the drain set
    # @shutdown_during_drain / @pending_force_reconnect flags.
    def drain_latest_per_kind(initial)
      latest = {}
      order  = []
      apply  = ->(t) {
        _, kind, params = t
        order << kind unless latest.key?(kind)
        latest[kind] = params
      }
      apply.call(initial)
      loop do
        extra = @ts.take_nonblocking(TUPLE_PATTERN)
        if shutdown_sentinel?(extra)
          @shutdown_during_drain = true
          break
        end
        if force_reconnect_sentinel?(extra)
          @pending_force_reconnect = true
          next
        end
        apply.call(extra)
      rescue Rinda::RequestExpiredError
        break
      end
      order.map { |k| [k, latest[k]] }
    end

    def deliver_burst(per_kind_list)
      per_kind_list.each do |kind, params|
        handler = @handlers[kind]
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

    def handler_ctx
      { ts: @ts, restore_sleep_fn: @restore_sleep_fn }
    end

    def shutdown_sentinel?(tuple)
      tuple && tuple[1] == SHUTDOWN_SENTINEL
    end

    def force_reconnect_sentinel?(tuple)
      tuple && tuple[1] == FORCE_RECONNECT_SENTINEL
    end

    def disconnect_quietly
      @client&.disconnect
    rescue StackchanBleClient::Error, IOError, SystemCallError => e
      log(:debug, "disconnect (best-effort) raised: #{e.class}: #{e.message}")
    ensure
      @client = nil
    end

    def log(level, msg)
      @logger&.public_send(level, "[stackchan-notifier:worker] #{msg}")
    end
  end
end
```

Key changes from old worker:
- `TUPLE_PATTERN` = `[:cmd, Symbol, Hash]`
- `SHUTDOWN_TUPLE` / `FORCE_RECONNECT_TUPLE` reshaped to `[:cmd, sentinel, {}]`
- Removed `RESTORE_TUPLE` constant (handlers build their own)
- Removed `@restore_thread` / `schedule_restore` / `cancel_pending_restore` (moved to NotifyHandler)
- New `handlers:` constructor kwarg with `DEFAULT_HANDLERS` registry
- `next_tuple_to_deliver` → `next_burst_to_deliver` returns `[per_kind_list, was_retry]`
- `deliver` → `deliver_burst(per_kind_list)` iterates and dispatches
- `drain_latest` → `drain_latest_per_kind` returns ordered `(kind, params)` list

- [ ] **Step 5: Run worker tests to verify they pass**

Run: `bundle exec rake test TEST=test/worker_test.rb 2>&1 | tail -10`
Expected: `3 tests, X assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Run the full suite — daemon_test.rb may still fail**

Run: `bundle exec rake test 2>&1 | tail -15`
Expected: handler tests / CLI tests / motion-table test / worker test all PASS. `daemon_test.rb` likely fails because it still asserts old tuple shape. That's Task 11.

- [ ] **Step 7: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/worker.rb \
        pc/stackchan-notifier/test/worker_test.rb
git commit -m "refactor(notifier): worker dispatches [:cmd,Kind,Hash] via handler registry"
```

---

## Task 11: Update daemon integration tests for 3 kinds

**Files:**
- Modify: `pc/stackchan-notifier/test/daemon_test.rb`

- [ ] **Step 1: Inspect current daemon tests**

Read:
```bash
cat pc/stackchan-notifier/test/daemon_test.rb
```

Identify any test that writes the old 7-tuple shape or asserts old `:notify` tuple structure.

- [ ] **Step 2: Rewrite affected assertions**

For every place that writes `[:notify, face, lc, lm, rc, rm, dur]`, change to:
```ruby
@ts.write([:cmd, :notify, {
  face: face, left: [lc, lm], right: [rc, rm],
  duration: dur, silent: false,
}])
```

For every place that asserts the BLE client received face/LED commands, the assertions on `client.sent[0]` (an Array of command Hashes) still hold — the SendBuilder DSL didn't change. But you'll also see a `:head` command appended when `silent: false` and the face is in `NotifyMotionTable`. Adjust assertions to allow the extra `:head` entry, OR send the test tuples with `silent: true` to keep assertions minimal.

Add at least one new test per new kind:

```ruby
def test_daemon_dispatches_servo_tuple
  # Setup pattern from existing daemon_test ...
  ts.write([:cmd, :servo, { yaw: 100, pitch: 450, time_ms: 200, velocity: nil }])
  wait_until(timeout: 2.0) { ble_client.sent.any? { |s| s.is_a?(Array) && s.any? { |c| c[:kind] == :head } } }
  head_cmd = ble_client.sent.flatten.find { |c| c[:kind] == :head }
  assert_equal 100, head_cmd[:yaw]
  assert_equal 450, head_cmd[:pitch]
end

def test_daemon_dispatches_raw_tuple
  ts.write([:cmd, :raw, { frame: "<F:2>" }])
  wait_until(timeout: 2.0) { ble_client.sent.any? { |s| s.is_a?(Hash) && s[:kind] == :raw_send } }
  raw = ble_client.sent.find { |s| s.is_a?(Hash) && s[:kind] == :raw_send }
  assert_equal "<F:2>\n", raw[:frame]
end
```

(The exact setup helper names depend on what daemon_test.rb already provides. Mirror its idiom.)

- [ ] **Step 3: Run daemon tests**

Run: `bundle exec rake test TEST=test/daemon_test.rb 2>&1 | tail -10`
Expected: 0 failures, 0 errors. If existing tests fail because of the new `:head` command appended by NotifyHandler default motion lookup, either:
- Use `silent: true` in the test tuple, OR
- Update assertions to allow the trailing `:head` entry

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: ALL tests PASS, 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-notifier/test/daemon_test.rb
git commit -m "test(notifier): cover daemon dispatch for :notify/:servo/:raw kinds"
```

---

## Task 12: Bump version + update gemspec exes + README

**Files:**
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/version.rb`
- Modify: `pc/stackchan-notifier/stackchan_notifier.gemspec`
- Modify: `pc/stackchan-notifier/README.md`

- [ ] **Step 1: Bump version to 2.0.0**

Read current version:
```bash
cat pc/stackchan-notifier/lib/stackchan_notifier/version.rb
```

Edit the file: change `VERSION = "1.x.x"` to:
```ruby
VERSION = "2.0.0"
```

- [ ] **Step 2: Ensure gemspec packages the new exes**

Read:
```bash
cat pc/stackchan-notifier/stackchan_notifier.gemspec
```

If the gemspec uses `executables = Dir["exe/*"].map { |f| File.basename(f) }` or similar, the new `stackchan-servo` / `stackchan-raw` are picked up automatically — verify by grep. Otherwise add them explicitly to the `executables` array.

If `files = ...` enumerates under `lib/`, the new files are picked up. Otherwise add `lib/stackchan_notifier/handlers/*.rb` etc explicitly.

- [ ] **Step 3: Add a migration note to README**

Open `pc/stackchan-notifier/README.md` and add at the top (under the title, before the existing intro) a v2.0 migration paragraph:

```markdown
> **v2.0 (2026-05-19):** The wire tuple shape changed from `[:notify, ...]`
> 7-element positional to `[:cmd, Symbol, Hash]`. `stackchan-notify` CLI args
> are unchanged. Two new CLIs joined: `stackchan-servo` (head motion) and
> `stackchan-raw` (arbitrary wire frame). `stackchan-notify --face NAME` now
> also drives the head via a daemon-side `NotifyMotionTable` lookup, unless
> `--silent` is passed. Old `stackchan-notify` 1.x clients are NOT
> wire-compatible with a 2.0 daemon — upgrade both together.
```

Also update the "Architecture" section if it lists the tuple shape, and add `stackchan-servo` / `stackchan-raw` to any usage examples.

- [ ] **Step 4: Run the full suite once more to confirm green**

Run: `bundle exec rake test 2>&1 | tail -5`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/version.rb \
        pc/stackchan-notifier/stackchan_notifier.gemspec \
        pc/stackchan-notifier/README.md
git commit -m "chore(notifier): bump to 2.0.0; document multi-command dispatch in README"
```

---

## Task 13: Close Phase B Task 13 stub in plan + memory entry

**Files:**
- Modify: `pc/stackchan-picoruby/docs/superpowers/plans/2026-05-19-phase-b-servo.md`
- Create / Update: memory entry

- [ ] **Step 1: Mark Phase B Task 13 as superseded**

Edit `docs/superpowers/plans/2026-05-19-phase-b-servo.md`. Find `## Task 13: stackchan-notifier servo hook` and replace its body with:

```markdown
## Task 13: stackchan-notifier servo hook — SUPERSEDED

This task's "10-line plug-in" plan assumed a `handle_tuple` case-dispatch
that did not exist in the notifier Worker. Replaced by the deeper
multi-command refactor in
`docs/superpowers/specs/2026-05-19-notifier-multi-command-dispatch-design.md`
and its plan
`docs/superpowers/plans/2026-05-19-notifier-multi-command-dispatch.md`.

Closed by the notifier 2.0 refactor commits (see those plan tasks 1–12).
Phase B servo dispatch from hooks is now available via
`stackchan-servo --yaw N --pitch M`.
```

- [ ] **Step 2: Add a memory entry capturing the lesson**

Use the auto-memory system to record this learning. Write to
`/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/feedback_plan_assumes_nonexistent_structure.md`:

```markdown
---
name: feedback-plan-assumes-nonexistent-structure
description: When a plan task says "add a case branch to handle_tuple", verify the case-dispatch structure exists before scoping the task. 2026-05-19 Phase B Task 13 lesson.
metadata:
  type: feedback
---

When a plan task instructs "add a `:servo` case to handle_tuple in
worker.rb" or similar, read the file first to confirm the case-dispatch
structure exists. If it doesn't (e.g. the worker actually destructures a
positional tuple with no case at all), stop and treat it as an
architectural-spec issue, NOT a 10-line patch.

**Why:** 2026-05-19 Phase B Task 13 plan was written by visualizing a
plausible-but-imaginary structure. Reality required a multi-command bus
refactor across ~10 files. Catching it during context-explore prevented
shipping a fake task and let us write a proper spec.

**How to apply:** During plan execution, before starting any task that
modifies an existing file, run `grep -n "case\|when " <file>` on the
target. If the structure the plan assumes is absent, surface that
finding immediately and escalate to spec rework. Cost of a 30-second
grep beats half a day of "add the case branch... wait, where is it?"
```

Then append a one-line index entry to
`/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/MEMORY.md`:

```markdown
- [Plan assumes nonexistent structure](feedback_plan_assumes_nonexistent_structure.md) — verify case-dispatch / scaffolding exists before treating "add a branch" as 10-line patch
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-05-19-phase-b-servo.md \
        /Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/feedback_plan_assumes_nonexistent_structure.md \
        /Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/MEMORY.md
git commit -m "docs(superpowers): supersede Phase B Task 13 with notifier 2.0 refactor"
```

Note: the memory directory is outside the project repo. If git complains about cross-repo paths, split into two commits — one for the project doc, one for the memory file in its own repo.

---

## Self-Review

**Spec coverage check (vs `docs/superpowers/specs/2026-05-19-notifier-multi-command-dispatch-design.md`):**

| Spec section | Plan task |
|---|---|
| Goals 1 (single tuple pattern) | Task 10 (Worker TUPLE_PATTERN = `[:cmd, Symbol, Hash]`) |
| Goals 2 (3 kinds at launch) | Tasks 3, 4, 5 (handlers) + Tasks 7, 8, 9 (CLIs) |
| Goals 3 (per-kind latest-wins) | Task 10 (drain_latest_per_kind) |
| Goals 4 (face→motion + --silent) | Tasks 2 (table) + 5 (NotifyHandler) + 7 (--silent CLI flag) |
| Goals 5 (reconnect/backoff/GATT untouched) | Task 10 (carries forward existing methods unchanged) |
| Goals 6 (clean break, CLI args unchanged) | Task 7 (CLI args + Task 10 (Worker shape) + Task 12 (version bump) |
| Architecture diagram | Task 10 + 7/8/9 components |
| Data flow example | Tasks 5, 10 |
| `drain_latest_per_kind` | Task 10 |
| Per-kind handler details | Tasks 3, 4, 5 |
| NotifyMotionTable | Task 2 |
| CLI surface (3 exes) | Tasks 7, 8, 9 |
| Shared CliBase | Task 6 |
| Restore semantics summary | Task 5 (test cases verify silent restore + duration trigger) |
| Error handling (unknown kind log warn) | Task 10 (test_unknown_kind_is_logged_warn_and_skipped) |
| Testing strategy (3 layers + 1 integration) | Tasks 2-5 (handler+table) + 6 (CliBase) + 7-9 (CLI) + 10 (Worker) + 11 (daemon integration) |
| Migration (version bump, README note) | Task 12 |

All spec sections covered.

**Placeholder scan:** searched for "TBD", "TODO", "implement later" — none found in the plan body. All step code blocks contain complete code; all commands have expected output.

**Type consistency check:**
- `[:cmd, Symbol, Hash]` tuple shape used consistently in all tasks (2-11)
- Handler interface `deliver(client:, params:, ctx:)` consistent across Tasks 3-5 and asserted in Task 10's RecordingHandler
- `NotifyMotionTable.lookup` signature consistent between Task 2 implementation and Task 5 NotifyHandler usage
- `CliBase.try_send` signature consistent between Task 6 implementation and Tasks 7, 8, 9 callers
- restore tuple shape `[:cmd, :notify, {face: :neutral, ..., silent: original_silent}]` consistent between spec, Task 5 NotifyHandler, and Task 5 tests

All consistent.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-19-notifier-multi-command-dispatch.md`.
