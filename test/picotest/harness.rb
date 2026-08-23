# CRuby orchestrator for the PicoRuby-native device test suite.
# Extracts application.rb's class bodies (prism, in CRuby) into a file, then
# drives Picotest::Runner to load that file + stubs + fakes + scservo onto the
# host picoruby VM and run test/device/*_test.rb there.

module PicotestHarness
  REPO_ROOT     = File.expand_path("../..", __dir__) # test/picotest -> repo root
  # Must be the vendored R2P2-ESP32's own picoruby (same VM the device firmware
  # runs), not an independent upstream checkout — an unrelated checkout's
  # host-VM quirks silently diverge from device behavior and break the suite.
  PICORUBY_ROOT = ENV["PICORUBY_ROOT"] || File.join(REPO_ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32", "picoruby")
  APPLICATION_RB = File.join(REPO_ROOT, "app", "application.rb")
  # No vendored source of truth for this one (picoruby-scservo is fetched by
  # R2P2-ESP32's build_config as a build-time mrbgem, not vendored as a repo
  # tree) — override with ENV on any machine other than the original author's.
  SCSERVO_RB     = ENV["SCSERVO_RB"] || "/Users/bash/dev/src/github.com/bash0C7/picoruby-scservo/mrblib/scservo.rb"
  TEST_DIR       = File.join(REPO_ROOT, "test", "device")
  STUBS_RB       = File.join(REPO_ROOT, "test", "picotest", "stubs.rb")
  FACE_GOLDEN_HASH_RB = File.join(REPO_ROOT, "test", "face_golden_hash.rb")
  EXTRACTED_RB   = File.join("/tmp", "_extracted_application.rb")

  module_function

  def run(filter: nil)
    require File.join(PICORUBY_ROOT, "mrbgems", "picoruby-picotest", "mrblib", "picotest.rb")
    $LOAD_PATH.unshift File.join(REPO_ROOT, "lib")
    $LOAD_PATH.unshift File.join(REPO_ROOT, "test")
    require "ruby_class_extract"

    # CRuby side: stubs + app classes must be defined so Runner can ENUMERATE
    # test classes (face_golden_test.rb's class body references Face::* via
    # FACE_CASES at load time).
    load STUBS_RB
    RubyClassExtract.load_classes_from(APPLICATION_RB, exclude_superclasses: %w[BLE])
    require "face_golden_hash"

    # Target VM side: emit the extracted class bodies as a loadable file.
    RubyClassExtract.extract_to_file(APPLICATION_RB, EXTRACTED_RB, exclude_superclasses: %w[BLE])

    ENV["RUBY"] = File.join(PICORUBY_ROOT, "build", "host", "bin", "picoruby")
    Picotest::Runner.new(
      TEST_DIR,
      filter: filter,
      require_name: nil,
      load_path: nil,
      load_files: [
        STUBS_RB,
        EXTRACTED_RB,
        FACE_GOLDEN_HASH_RB,
        File.join(REPO_ROOT, "test", "fake_display.rb"),
        File.join(REPO_ROOT, "test", "fake_led.rb"),
        File.join(REPO_ROOT, "test", "fake_py32.rb"),
        File.join(REPO_ROOT, "test", "fake_uart.rb"),
        File.join(REPO_ROOT, "test", "fake_i2c.rb"),
        File.join(REPO_ROOT, "test", "fake_i2s.rb"),
        SCSERVO_RB,
      ],
    ).run
  end
end
