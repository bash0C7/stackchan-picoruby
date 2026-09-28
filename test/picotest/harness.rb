# CRuby orchestrator for the picotest suites (device / pc / gems), all on
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
# embeds them the same way.
DEVICE_GEMS = %w[stackchan-led si12t aw88298].map { |g| File.join(REPO_ROOT, "mrbgems", "picoruby-#{g}") }
DEVICE_GEM_MRBLIB = DEVICE_GEMS.flat_map { |g| Dir[File.join(g, "mrblib", "*.rb")].sort }
ROBOT_MRBLIB = Dir[File.join(REPO_ROOT, "mrbgems", "picoruby-stackchan-robot", "mrblib", "**", "*.rb")].sort
  .reject { |f| File.basename(f) == "peripheral.rb" }

  DEVICE_STUBS_RB     = File.join(REPO_ROOT, "test", "picotest", "stubs.rb")
  FACE_GOLDEN_HASH_RB = File.join(REPO_ROOT, "test", "face_golden_hash.rb")
  ROBOT_TABLES_RB     = File.join(REPO_ROOT, "test", "robot_tables.rb")
  DEVICE_FAKES        = %w[fake_display fake_led fake_py32 fake_uart fake_i2c fake_i2s fake_multicore].map { |f| File.join(REPO_ROOT, "test", "#{f}.rb") }
  PC_STUBS_RB         = File.join(REPO_ROOT, "test", "pc", "stubs.rb")
  PC_FAKE_RADIO_RB    = File.join(REPO_ROOT, "test", "pc", "fake_radio.rb")
  PC_DRB_PATCH_RB     = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "drb_eintr_retry.rb")
  PC_FAKE_BLE_RB      = File.join(REPO_ROOT, "pc", "stackchan-pico", "app", "fake_ble.rb")
  # picoruby-drb is not in the host VM: suites that need it load its mrblib as
  # source (Marshal is compiled in), then the drbble transport gem.
  # The AOT kernels' Ruby source stands in for the compiled kernels.
  AOT_KERNELS = Dir[File.join(REPO_ROOT, "aot", "kernels", "*.rb")].sort
  DRB_MRBLIB = %w[drb.rb drb_message.rb drb_object.rb].map { |f| File.join(PICORUBY_ROOT, "mrbgems", "picoruby-drb", "mrblib", f) }
  DRB_BLE_MRBLIB = Dir[File.join(REPO_ROOT, "mrbgems", "picoruby-drb-ble", "mrblib", "*.rb")].sort
  PROTOCOL_GEM_DIR = File.join(REPO_ROOT, "mrbgems", "picoruby-stackchan-protocol")
  PROTOCOL_MRBLIB = [File.join(PROTOCOL_GEM_DIR, "mrblib", "stackchan-protocol.rb"),
                      *Dir[File.join(PROTOCOL_GEM_DIR, "mrblib", "stackchan-protocol", "*.rb")].sort]
  CONTROLLER_GEM_DIR = File.join(REPO_ROOT, "mrbgems", "picoruby-stackchan-controller")
  CONTROLLER_MRBLIB = [File.join(CONTROLLER_GEM_DIR, "mrblib", "stackchan-controller.rb"),
                        *Dir[File.join(CONTROLLER_GEM_DIR, "mrblib", "stackchan-controller", "*.rb")].sort]
  ROBOT_APP_RB = File.join(REPO_ROOT, "apps", "robot", "app.rb")
  MAC_APP_RB = File.join(REPO_ROOT, "apps", "mac", "app.rb")
  EXTRACTED_ROBOT_APP_RB = "/tmp/_extracted_robot_app.rb"

  SUITES = {
    "device" => {
      dir: File.join(REPO_ROOT, "test", "device"),
      cruby: lambda {
        load DEVICE_STUBS_RB
        DEVICE_GEM_MRBLIB.each { |f| load f }
        PROTOCOL_MRBLIB.each { |f| require f }
        ROBOT_MRBLIB.each { |f| load f }
        require "face_golden_hash"
      },
      load_files: lambda {
        extract_robot_app(ROBOT_APP_RB, EXTRACTED_ROBOT_APP_RB)
        [DEVICE_STUBS_RB, *DEVICE_GEM_MRBLIB, *DRB_MRBLIB, *DRB_BLE_MRBLIB, *PROTOCOL_MRBLIB, *ROBOT_MRBLIB, FACE_GOLDEN_HASH_RB, ROBOT_TABLES_RB, *AOT_KERNELS, *DEVICE_FAKES, SCSERVO_RB, EXTRACTED_ROBOT_APP_RB]
      },
    },
    "pc" => {
      dir: File.join(REPO_ROOT, "test", "pc"),
      cruby: lambda {
        load PC_STUBS_RB
        PROTOCOL_MRBLIB.each { |f| require f }
        CONTROLLER_MRBLIB.each { |f| load f }
        load PC_DRB_PATCH_RB
        load PC_FAKE_RADIO_RB if File.exist?(PC_FAKE_RADIO_RB)
      },
      load_files: lambda {
        # Real picoruby-drb first: the stubs then replace the parts the daemon tests observe.
        files = [*DRB_MRBLIB, PC_STUBS_RB, *PROTOCOL_MRBLIB, *CONTROLLER_MRBLIB, PC_DRB_PATCH_RB, *DRB_BLE_MRBLIB]
        files << PC_FAKE_RADIO_RB if File.exist?(PC_FAKE_RADIO_RB)
        files << PC_FAKE_BLE_RB
        files << MAC_APP_RB
        files
      },
    },
}
  SUITES["aot"] = {
    dir: File.join(REPO_ROOT, "aot", "test"),
    cruby: lambda {},
    load_files: lambda { AOT_KERNELS },
  }
  SUITES["drb-ble"] = {
    dir: File.join(REPO_ROOT, "mrbgems", "picoruby-drb-ble", "test"),
    cruby: lambda {},
    load_files: lambda { [*DRB_MRBLIB, *DRB_BLE_MRBLIB] },
  }
  SUITES["stackchan-protocol"] = {
    dir: File.join(PROTOCOL_GEM_DIR, "test"),
    cruby: lambda { PROTOCOL_MRBLIB.each { |f| load f } },
    load_files: lambda { PROTOCOL_MRBLIB },
  }
  DEVICE_GEMS.each do |gem|
    mrblib = Dir[File.join(gem, "mrblib", "*.rb")].sort
    SUITES[File.basename(gem).sub("picoruby-", "")] = {
      dir: File.join(gem, "test"),
      cruby: lambda { load DEVICE_STUBS_RB; DEVICE_FAKES.each { |f| load f }; mrblib.each { |f| load f } },
      load_files: lambda { [DEVICE_STUBS_RB, *AOT_KERNELS, *DEVICE_FAKES, *mrblib] },
    }
  end
  SUITES.freeze

  module_function

  def extract_robot_app(src, out)
    require "prism"
    body = Prism.parse_file(src).value.statements.body
    kept = body.reject { |n| n.is_a?(Prism::CallNode) && n.name == :require && n.receiver.nil? }
    File.write(out, <<~RUBY)
      class StackChan::Robot
        def run
          self
        end
      end

      module RobotApp
        def self.robot
      #{kept.map(&:slice).join("\n")}
        end
      end
    RUBY
  end

  # Returns the total error count across the selected suites (0 = green).
  def run(filter: nil, suite: nil)
    require File.join(PICORUBY_ROOT, "mrbgems", "picoruby-picotest", "mrblib", "picotest.rb")
    $LOAD_PATH.unshift File.join(REPO_ROOT, "lib")
    $LOAD_PATH.unshift File.join(REPO_ROOT, "test")
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
