# CRuby orchestrator for the PicoRuby-native test suites. All three run on the
# same host picoruby VM (R2P2-ESP32's own picoruby, MRUBY_CONFIG=picoruby-test):
#   device — app/application.rb classes (prism-extracted, `< BLE` excluded) + test/device
#   pc     — pc/stackchan-pico/app/ble_client.rb classes (prism-extracted; BLE is stubbed) + test/pc
#   shared — mrbgems/picoruby-stackchan-shared mrblib + its own test dir
# Each suite lists (a) what the CRuby side must load so Picotest::Runner can
# ENUMERATE test classes, and (b) the files embedded into every generated VM
# script (Runner's load_files), in load order.

module PicotestHarness
  REPO_ROOT     = File.expand_path("../..", __dir__) # test/picotest -> repo root
  # Must be the vendored R2P2-ESP32's own picoruby (same VM the device firmware
  # runs), not an independent upstream checkout — an unrelated checkout's
  # host-VM quirks silently diverge from device behavior and break the suite.
  PICORUBY_ROOT = ENV["PICORUBY_ROOT"] || File.join(REPO_ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32", "picoruby")
  PICORUBY_VM   = File.join(PICORUBY_ROOT, "build", "host", "bin", "picoruby")
  # picoruby-scservo is fetched by R2P2-ESP32's build_config as a build-time
  # mrbgem (from GitHub), not vendored here as a repo tree, so it has to be
  # located rather than required. Preference order: explicit override, the
  # author's sibling clone layout, the copy the firmware build already fetched.
  SCSERVO_SIBLING  = File.expand_path("../picoruby-scservo/mrblib/scservo.rb", REPO_ROOT)
  SCSERVO_VENDORED = File.join(REPO_ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32",
                                "picoruby", "build", "repos", "esp32-picoruby", "picoruby-scservo",
                                "mrblib", "scservo.rb")
  SCSERVO_RB = ENV["SCSERVO_RB"] || [SCSERVO_SIBLING, SCSERVO_VENDORED].find { |path| File.exist?(path) }
  unless SCSERVO_RB && File.exist?(SCSERVO_RB)
    # Report the path that actually failed: an override pointing nowhere is the
    # case worth naming, and listing the fallbacks instead hides it.
    searched = ENV["SCSERVO_RB"] ? [ENV["SCSERVO_RB"]] : [SCSERVO_SIBLING, SCSERVO_VENDORED]
    abort("scservo.rb not found; searched:\n  " + searched.join("\n  ") +
          "\nSet SCSERVO_RB to point at picoruby-scservo's mrblib/scservo.rb.")
  end

  APPLICATION_RB      = File.join(REPO_ROOT, "app", "application.rb")
  BLE_CLIENT_RB       = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "ble_client.rb")
  CLI_APP_RB          = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "cli_app.rb")
  DEVICE_STUBS_RB     = File.join(REPO_ROOT, "test", "picotest", "stubs.rb")
  FACE_GOLDEN_HASH_RB = File.join(REPO_ROOT, "test", "face_golden_hash.rb")
  DEVICE_FAKES        = %w[fake_display fake_led fake_py32 fake_uart fake_i2c fake_i2s].map { |f| File.join(REPO_ROOT, "test", "#{f}.rb") }
  PC_STUBS_RB         = File.join(REPO_ROOT, "test", "pc", "stubs.rb")
  PC_FAKE_RADIO_RB    = File.join(REPO_ROOT, "test", "pc", "fake_radio.rb")
  # Loadable anywhere: its DRb and TCPSocket patches are guarded on those
  # constants, which the host VM does not have, leaving the SocketReadRetry
  # policy the suite exercises.
  PC_DRB_PATCH_RB     = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "drb_eintr_retry.rb")
  # Same order as the boot_daemon*.rb load lists: namespace root first.
  SHARED_MRBLIB = %w[
    stackchan.rb
    stackchan/ble/errors.rb
    stackchan/ble/face_table.rb
    stackchan/ble/led_color_table.rb
    stackchan/ble/hsb_to_rgb.rb
    stackchan/ble/frame_codec.rb
    stackchan/ble/send_builder.rb
    stackchan/ai/frame_text.rb
  ].map { |f| File.join(REPO_ROOT, "mrbgems", "picoruby-stackchan-shared", "mrblib", f) }
  EXTRACTED_APP_RB = "/tmp/_extracted_application.rb"
  EXTRACTED_PC_RB  = "/tmp/_extracted_ble_client.rb"
  EXTRACTED_CLI_RB = "/tmp/_extracted_cli_app.rb"

  SUITES = {
    "device" => {
      dir: File.join(REPO_ROOT, "test", "device"),
      cruby: lambda {
        load DEVICE_STUBS_RB
        RubyClassExtract.load_classes_from(APPLICATION_RB, exclude_superclasses: %w[BLE])
        require "face_golden_hash"
      },
      load_files: lambda {
        RubyClassExtract.extract_to_file(APPLICATION_RB, EXTRACTED_APP_RB, exclude_superclasses: %w[BLE])
        [DEVICE_STUBS_RB, EXTRACTED_APP_RB, FACE_GOLDEN_HASH_RB, *DEVICE_FAKES, SCSERVO_RB]
      },
    },
    "pc" => {
      dir: File.join(REPO_ROOT, "test", "pc"),
      cruby: lambda {
        load PC_STUBS_RB
        SHARED_MRBLIB.each { |f| require f }
        RubyClassExtract.load_classes_from(BLE_CLIENT_RB)
        RubyClassExtract.load_classes_from(CLI_APP_RB)
        load PC_DRB_PATCH_RB
        load PC_FAKE_RADIO_RB if File.exist?(PC_FAKE_RADIO_RB)
      },
      load_files: lambda {
        RubyClassExtract.extract_to_file(BLE_CLIENT_RB, EXTRACTED_PC_RB)
        RubyClassExtract.extract_to_file(CLI_APP_RB, EXTRACTED_CLI_RB)
        files = [PC_STUBS_RB, *SHARED_MRBLIB, EXTRACTED_PC_RB, EXTRACTED_CLI_RB, PC_DRB_PATCH_RB]
        files << PC_FAKE_RADIO_RB if File.exist?(PC_FAKE_RADIO_RB)
        files
      },
    },
    "shared" => {
      dir: File.join(REPO_ROOT, "mrbgems", "picoruby-stackchan-shared", "test"),
      cruby: lambda { SHARED_MRBLIB.each { |f| require f } },
      load_files: lambda { SHARED_MRBLIB },
    },
  }.freeze

  module_function

  # Returns the total error count across the selected suites (0 = green).
  def run(filter: nil, suite: nil)
    require File.join(PICORUBY_ROOT, "mrbgems", "picoruby-picotest", "mrblib", "picotest.rb")
    $LOAD_PATH.unshift File.join(REPO_ROOT, "lib")
    $LOAD_PATH.unshift File.join(REPO_ROOT, "test")
    require "ruby_class_extract"
    # PICOTEST_VM: run the suites on another picoruby (e.g. vendor/R2P2-darwin/build/host/bin/picoruby
    # to re-check the pc suite on the Mac lineage). Default: the R2P2-ESP32 host VM.
    ENV["RUBY"] = ENV["PICOTEST_VM"] || PICORUBY_VM
    # picotest runs each test class from a generated /tmp driver script, so
    # __FILE__ inside a test resolves to /tmp rather than to the file on disk.
    # A test that needs a repo-relative fixture (spec/golden) reads this; the
    # spawned VM inherits the environment.
    ENV["STACKCHAN_REPO_ROOT"] = REPO_ROOT

    names = suite ? [suite] : SUITES.keys
    errors = 0
    names.each do |name|
      s = SUITES.fetch(name) { abort "unknown SUITE=#{name} (expected one of #{SUITES.keys.join(' / ')})" }
      puts "== picotest suite: #{name} =="
      s[:cruby].call
      errors += Picotest::Runner.new(
        s[:dir],
        filter: filter,
        require_name: nil,
        load_path: nil,
        load_files: s[:load_files].call,
      ).run
    end
    errors
  end
end
