# CRuby orchestrator for the picotest suites (device / pc / shared), all on
# R2P2-ESP32's own host picoruby VM. Each suite lists what CRuby loads to
# enumerate test classes and what is embedded into the VM script, in order.

module PicotestHarness
  REPO_ROOT     = File.expand_path("../..", __dir__) # test/picotest -> repo root
  # The vendored R2P2-ESP32's picoruby: the same VM the device runs.
  PICORUBY_ROOT = ENV["PICORUBY_ROOT"] || File.join(REPO_ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32", "picoruby")
  PICORUBY_VM   = File.join(PICORUBY_ROOT, "build", "host-picotest", "bin", "picoruby")
  # picoruby-scservo is fetched at firmware-build time; locate it.
  SCSERVO_SIBLING  = File.expand_path("../picoruby-scservo/mrblib/scservo.rb", REPO_ROOT)
  SCSERVO_VENDORED = File.join(REPO_ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32",
                                "picoruby", "build", "repos", "esp32-picoruby", "picoruby-scservo",
                                "mrblib", "scservo.rb")
  SCSERVO_RB = ENV["SCSERVO_RB"] || [SCSERVO_SIBLING, SCSERVO_VENDORED].find { |path| File.exist?(path) }
  unless SCSERVO_RB && File.exist?(SCSERVO_RB)
    searched = ENV["SCSERVO_RB"] ? [ENV["SCSERVO_RB"]] : [SCSERVO_SIBLING, SCSERVO_VENDORED]
    abort("scservo.rb not found; searched:\n  " + searched.join("\n  ") +
          "\nSet SCSERVO_RB to point at picoruby-scservo's mrblib/scservo.rb.")
  end

# Pure-Ruby driver gems are bundled into app.mrb by the Rakefile; the device suite
# embeds them the same way. picoruby-aw88298 is a C gem compiled into the host VM
# (build_config/picoruby-test.rb) and reached with `require`, as on the device.
DEVICE_GEMS = %w[stackchan-led si12t].map { |g| File.join(REPO_ROOT, "mrbgems", "picoruby-#{g}") }
C_GEMS = %w[aw88298]
DEVICE_GEM_MRBLIB = DEVICE_GEMS.flat_map { |g| Dir[File.join(g, "mrblib", "*.rb")].sort }

  APPLICATION_RB      = File.join(REPO_ROOT, "app", "application.rb")
  BLE_CLIENT_RB       = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "ble_client.rb")
  CLI_APP_RB          = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "cli_app.rb")
  DAEMON_APP_RB       = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "daemon_app.rb")
  DEVICE_STUBS_RB     = File.join(REPO_ROOT, "test", "picotest", "stubs.rb")
  FACE_GOLDEN_HASH_RB = File.join(REPO_ROOT, "test", "face_golden_hash.rb")
  DEVICE_FAKES        = %w[fake_display fake_led fake_py32 fake_uart fake_i2c fake_i2s].map { |f| File.join(REPO_ROOT, "test", "#{f}.rb") }
  PC_STUBS_RB         = File.join(REPO_ROOT, "test", "pc", "stubs.rb")
  PC_FAKE_RADIO_RB    = File.join(REPO_ROOT, "test", "pc", "fake_radio.rb")
  PC_DRB_PATCH_RB     = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "drb_eintr_retry.rb")
  SHARED_MRBLIB = %w[
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
  EXTRACTED_DAEMON_RB = "/tmp/_extracted_daemon_app.rb"

  SUITES = {
    "device" => {
      dir: File.join(REPO_ROOT, "test", "device"),
      require_name: "aw88298",
      cruby: lambda {
        load DEVICE_STUBS_RB
        DEVICE_GEM_MRBLIB.each { |f| load f }
        RubyClassExtract.load_classes_from(APPLICATION_RB, exclude_superclasses: %w[BLE])
        require "face_golden_hash"
      },
      load_files: lambda {
        RubyClassExtract.extract_to_file(APPLICATION_RB, EXTRACTED_APP_RB, exclude_superclasses: %w[BLE])
        [DEVICE_STUBS_RB, *DEVICE_GEM_MRBLIB, EXTRACTED_APP_RB, FACE_GOLDEN_HASH_RB, *DEVICE_FAKES, SCSERVO_RB]
      },
    },
    "pc" => {
      dir: File.join(REPO_ROOT, "test", "pc"),
      cruby: lambda {
        load PC_STUBS_RB
        SHARED_MRBLIB.each { |f| require f }
        RubyClassExtract.load_classes_from(BLE_CLIENT_RB)
        RubyClassExtract.load_classes_from(CLI_APP_RB)
        RubyClassExtract.load_classes_from(DAEMON_APP_RB)
        load PC_DRB_PATCH_RB
        load PC_FAKE_RADIO_RB if File.exist?(PC_FAKE_RADIO_RB)
      },
      load_files: lambda {
        RubyClassExtract.extract_to_file(BLE_CLIENT_RB, EXTRACTED_PC_RB)
        RubyClassExtract.extract_to_file(CLI_APP_RB, EXTRACTED_CLI_RB)
        RubyClassExtract.extract_to_file(DAEMON_APP_RB, EXTRACTED_DAEMON_RB)
        files = [PC_STUBS_RB, *SHARED_MRBLIB, EXTRACTED_PC_RB, EXTRACTED_CLI_RB, EXTRACTED_DAEMON_RB, PC_DRB_PATCH_RB]
        files << PC_FAKE_RADIO_RB if File.exist?(PC_FAKE_RADIO_RB)
        files
      },
    },
    "shared" => {
      dir: File.join(REPO_ROOT, "mrbgems", "picoruby-stackchan-shared", "test"),
      cruby: lambda { SHARED_MRBLIB.each { |f| require f } },
      load_files: lambda { SHARED_MRBLIB },
    },
}
  DEVICE_GEMS.each do |gem|
    mrblib = Dir[File.join(gem, "mrblib", "*.rb")].sort
    SUITES[File.basename(gem).sub("picoruby-", "")] = {
      dir: File.join(gem, "test"),
      cruby: lambda { load DEVICE_STUBS_RB; DEVICE_FAKES.each { |f| load f }; mrblib.each { |f| load f } },
      load_files: lambda { [DEVICE_STUBS_RB, *DEVICE_FAKES, *mrblib] },
    }
  end
  C_GEMS.each do |name|
    SUITES[name] = {
      dir: File.join(REPO_ROOT, "mrbgems", "picoruby-#{name}", "test"),
      require_name: name,
      cruby: lambda { load DEVICE_STUBS_RB; DEVICE_FAKES.each { |f| load f } },
      load_files: lambda { [DEVICE_STUBS_RB, *DEVICE_FAKES] },
    }
  end
  SUITES.freeze

  module_function

  # Returns the total error count across the selected suites (0 = green).
  def run(filter: nil, suite: nil)
    require File.join(PICORUBY_ROOT, "mrbgems", "picoruby-picotest", "mrblib", "picotest.rb")
    $LOAD_PATH.unshift File.join(REPO_ROOT, "lib")
    $LOAD_PATH.unshift File.join(REPO_ROOT, "test")
    require "ruby_class_extract"
    # PICOTEST_VM= runs the suites on another picoruby.
    ENV["RUBY"] = ENV["PICOTEST_VM"] || PICORUBY_VM
    # Tests run from a generated /tmp script, so repo-relative fixtures use this.
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
        require_name: s[:require_name],
        load_path: nil,
        load_files: s[:load_files].call,
      ).run
    end
    errors
  end
end
