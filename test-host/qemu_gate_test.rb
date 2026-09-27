require 'test/unit'
require 'tempfile'
require 'open3'
require 'qemu_gate'
require 'ruby_class_extract'

class QemuGateTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def test_pins_cover_the_four_platforms_with_url_and_sha256
    expected = {
      "x86_64-linux" => "588bfaccd0f929650655d10a580f020c6ba9c131712d8fa519280081b8d126eb",
      "aarch64-linux" => "317f6e0fd1dba0886d8110709823d909593ef29438822a14f81ebe19d72ce7cd",
      "x86_64-darwin" => "00b9dbc2124cf7633cb86f264fbc524226ad4001bce68bbdba43c9bdc4eb026e",
      "arm64-darwin" => "aa92e337461d482f5d9f31cd8efc0bd67b3de8fcfcfb567289cb43a59c184651",
    }
    expected.each do |platform, sha256|
      pin = QemuGate::PINS.fetch(platform)
      assert_equal sha256, pin.fetch(:sha256)
      assert pin.fetch(:url).start_with?("https://github.com/espressif/qemu/releases/download/")
      assert pin.fetch(:url).end_with?(".tar.xz")
    end
  end

  def test_pin_url_carries_the_release_platform_slug
    assert_equal(
      "https://github.com/espressif/qemu/releases/download/esp-develop-9.2.2-20250817/" \
      "qemu-xtensa-softmmu-esp_develop_9.2.2_20250817-x86_64-linux-gnu.tar.xz",
      QemuGate::PINS.fetch("x86_64-linux").fetch(:url)
    )
    assert_equal(
      "https://github.com/espressif/qemu/releases/download/esp-develop-9.2.2-20250817/" \
      "qemu-xtensa-softmmu-esp_develop_9.2.2_20250817-aarch64-apple-darwin.tar.xz",
      QemuGate::PINS.fetch("arm64-darwin").fetch(:url)
    )
  end

  def test_platform_detects_x86_64_linux
    assert_equal "x86_64-linux", QemuGate.platform(host_os: "linux-gnu", host_cpu: "x86_64")
  end

  def test_platform_detects_aarch64_linux
    assert_equal "aarch64-linux", QemuGate.platform(host_os: "linux-gnu", host_cpu: "aarch64")
  end

  def test_platform_detects_x86_64_darwin
    assert_equal "x86_64-darwin", QemuGate.platform(host_os: "darwin23", host_cpu: "x86_64")
  end

  def test_platform_detects_arm64_darwin
    assert_equal "arm64-darwin", QemuGate.platform(host_os: "darwin23", host_cpu: "arm64")
  end

  def test_platform_raises_naming_the_platform_when_unknown
    error = assert_raise(RuntimeError) { QemuGate.platform(host_os: "freebsd14", host_cpu: "riscv64") }
    assert_match "freebsd14", error.message
    assert_match "riscv64", error.message
  end

  def test_efuse_image_is_1024_bytes_binary
    image = QemuGate.efuse_image
    assert_equal 1024, image.bytesize
    assert_equal Encoding::ASCII_8BIT, image.encoding
  end

  def test_efuse_image_sets_byte_37_and_64_rest_zero
    image = QemuGate.efuse_image
    bytes = image.bytes
    assert_equal 0x0c, bytes[37]
    assert_equal 0x01, bytes[64]
    (bytes.each_index.to_a - [37, 64]).each do |i|
      assert_equal 0, bytes[i], "byte #{i} should be zero"
    end
  end

  def test_argv_builds_the_exact_qemu_invocation
    argv = QemuGate.argv(qemu: "/build/qemu/bin/qemu-system-xtensa", flash: "/tmp/flash.bin",
                          efuse: "/tmp/efuse.bin", log: "/tmp/qemu-42.log")
    assert_equal(
      [
        "/build/qemu/bin/qemu-system-xtensa",
        "-M", "esp32s3",
        "-m", "8M",
        "-drive", "file=/tmp/flash.bin,if=mtd,format=raw",
        "-drive", "file=/tmp/efuse.bin,if=none,format=raw,id=efuse",
        "-global", "driver=nvram.esp32s3.efuse,property=drive,value=efuse",
        "-global", "driver=timer.esp32s3.timg,property=wdt_disable,value=true",
        "-display", "none",
        "-serial", "file:/tmp/qemu-42.log",
        "-monitor", "none",
      ],
      argv
    )
  end

  def test_sdkconfig_defaults_replaces_only_usb_console
    list = "sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3;sdkconfigs/bt_nimble"
    result = QemuGate.sdkconfig_defaults(list, "build_config/qemu_console.sdkconfig")
    assert_equal "sdkconfig.defaults;build_config/qemu_console.sdkconfig;sdkconfigs/cores3;sdkconfigs/bt_nimble", result
  end

  def test_qemu_console_sdkconfig_has_the_two_lines_and_nothing_else
    path = File.join(ROOT, "build_config", "qemu_console.sdkconfig")
    lines = File.read(path).lines.map(&:chomp).reject(&:empty?)
    assert_equal %w[CONFIG_ESP_CONSOLE_UART_DEFAULT=y CONFIG_ESP_CONSOLE_SECONDARY_NONE=y], lines
  end


  def test_probe_source_orders_requires_gems_classes_wire_marker
    application = Tempfile.new(['fixture_app', '.rb'])
    application.write(<<~RUBY)
      require 'spi'
      require 'gpio'
      require 'stackchan-protocol'

      class BLE
      end

      class Excluded < BLE
        def ping; end
      end

      class Widget
        def ping = :pong
      end
    RUBY
    application.close

    gem_source = Tempfile.new(['fixture_gem', '.rb'])
    gem_source.write("class GemHelper\n  def go; :ok; end\nend\n")
    gem_source.close

    source = QemuGate.probe_source(application: application.path, gem_sources: [gem_source.path])

    require_idx = source.index("require 'spi'")
    require2_idx = source.index("require 'gpio'")
    require3_idx = source.index("require 'stackchan-protocol'")
    gem_idx = source.index("class GemHelper")
    class_idx = source.index("class Widget")
    wire_idx = source.index("FrameParser")
    marker_idx = source.index('puts "QEMU_PROBE_OK"')

    [require_idx, require2_idx, require3_idx, gem_idx, class_idx, wire_idx, marker_idx].each do |idx|
      assert idx, "expected all sections present in:\n#{source}"
    end
    assert require_idx < require2_idx
    assert require2_idx < require3_idx
    assert require3_idx < gem_idx
    assert gem_idx < class_idx
    assert class_idx < wire_idx
    assert wire_idx < marker_idx

    refute source.include?("class Excluded"), "BLE-derived class body must be excluded"
  ensure
    application.unlink
    gem_source.unlink
  end

  def test_probe_source_only_pulls_top_level_literal_requires
    application = Tempfile.new(['fixture_app', '.rb'])
    application.write(<<~RUBY)
      require 'top_level'
      SOME_NAME = 'dynamic'
      require SOME_NAME

      class Widget
        require 'nested_not_top_level'
        def ping = :pong
      end
    RUBY
    application.close

    source = QemuGate.probe_source(application: application.path, gem_sources: [])
    requires_section = source.lines.take_while { |l| !l.include?("class Widget") }.join

    assert source.include?("require 'top_level'")
    refute source.include?("require SOME_NAME")
    refute requires_section.include?("nested_not_top_level"), "only literal top-level requires belong in the requires section"
  ensure
    application.unlink
  end

  def test_probe_wire_round_trip_raises_unless_frame_parser_returns_expected_array
    source = QemuGate.probe_source(application: fixture_with_no_requires, gem_sources: [])
    assert_match(/raise .* unless StackchanProtocol::FrameParser\.new\.feed\("<F:1>\\n"\) == \[\{"F"=>"1"\}\]/, source)
  end

  def test_probe_source_compiles_for_a_small_fixture
    mrbc = mrbc_path
    omit "host picotest VM's mrbc not built (run `bundle exec rake picotest:build`)" unless mrbc

    source = QemuGate.probe_source(application: fixture_with_no_requires, gem_sources: [])
    with_tempfile(source) do |src_path, mrb_path|
      _out, err, status = Open3.capture3(mrbc, '-o', mrb_path, src_path)
      assert status.success?, "mrbc failed:\n#{err}"
    end
  end

  def test_probe_source_compiles_for_the_real_application
    mrbc = mrbc_path
    omit "host picotest VM's mrbc not built (run `bundle exec rake picotest:build`)" unless mrbc

    application = File.join(ROOT, 'app', 'application.rb')
    gem_sources = %w[stackchan-led si12t aw88298 drb-ble].flat_map do |g|
      Dir[File.join(ROOT, 'mrbgems', "picoruby-#{g}", 'mrblib', '*.rb')].sort
    end

    source = QemuGate.probe_source(application: application, gem_sources: gem_sources)
    with_tempfile(source) do |src_path, mrb_path|
      _out, err, status = Open3.capture3(mrbc, '-o', mrb_path, src_path)
      assert status.success?, "mrbc failed on the real application:\n#{err}"
    end
  end


  def test_verdict_passes_when_marker_line_is_present
    log = <<~LOG
      Loading app.mrb
      PROBE parse_touch=2
      QEMU_PROBE_OK
      Starting shell...
    LOG
    verdict = QemuGate.verdict(log)
    assert verdict.pass
  end

  def test_verdict_fails_with_no_marker_line_naming_the_reason
    log = <<~LOG
      Loading app.mrb
      Starting shell...
    LOG
    verdict = QemuGate.verdict(log)
    refute verdict.pass
    assert_match "no marker", verdict.message
  end

  def test_verdict_fails_on_error_class_line_after_loading_app_mrb
    log = <<~LOG
      Not found: /etc/network/wifi.yml does not exist
      Loading app.mrb
      uninitialized constant Regexp (NameError)
    LOG
    verdict = QemuGate.verdict(log)
    refute verdict.pass
    assert_match "NameError", verdict.message
  end

  def test_verdict_fails_on_a_gem_load_error_during_vm_boot_before_loading_app_mrb
    log = <<~LOG
      I (568) main_task: Returned from app_main()
      (unknown):0: uninitialized constant Regexp (NameError)
      Initializing FLASH disk as the root volume...
      Loading app.mrb
      QEMU_PROBE_OK
    LOG
    verdict = QemuGate.verdict(log)
    refute verdict.pass
    assert_match "uninitialized constant Regexp", verdict.message
  end

  def test_verdict_fails_on_guru_meditation_anywhere
    log = <<~LOG
      Guru Meditation Error: Core 0 panic'ed (LoadProhibited)
      Loading app.mrb
      QEMU_PROBE_OK
    LOG
    verdict = QemuGate.verdict(log)
    refute verdict.pass
    assert_match "Guru Meditation", verdict.message
  end

  def test_verdict_fails_on_marker_plus_a_later_panic
    log = <<~LOG
      Loading app.mrb
      QEMU_PROBE_OK
      Guru Meditation Error: Core 0 panic'ed
      Rebooting...
    LOG
    verdict = QemuGate.verdict(log)
    refute verdict.pass
  end

  def test_verdict_fails_on_abort_pattern
    log = "Loading app.mrb\nabort() was called at PC 0x40\n"
    verdict = QemuGate.verdict(log)
    refute verdict.pass
    assert_match "abort()", verdict.message
  end

  def test_verdict_fails_on_assert_failed_pattern
    log = "Loading app.mrb\nassert failed: foo.c:12\n"
    verdict = QemuGate.verdict(log)
    refute verdict.pass
  end

  def test_verdict_fails_on_empty_log
    verdict = QemuGate.verdict("")
    refute verdict.pass
    assert_match "no marker", verdict.message
  end

  def test_verdict_fails_on_mrubyc_symbol_overflow_after_loading_app_mrb
    log = <<~LOG
      Loading app.mrb
      Error: Overflow MAX_SYMBOLS_COUNT
      Exception(vm_id=20): in `extern': Overflow MAX_SYMBOLS_COUNT (Exception)
      \tin `require'
    LOG
    verdict = QemuGate.verdict(log)
    refute verdict.pass
    assert_match "MAX_SYMBOLS_COUNT", verdict.message
  end

  def test_verdict_passes_the_measured_clean_boot_log_shape
    log = <<~LOG
      I (568) main_task: Returned from app_main()
      Initializing FLASH disk as the root volume...
      Not found: /etc/machine-id, Writing 12 bytes
      Available
      File /etc/network/wifi.yml does not exist
      Loading app.mrb
      QEMU_PROBE_OK
    LOG
    verdict = QemuGate.verdict(log)
    assert verdict.pass
  end

  def test_verdict_fails_on_real_neg_log_excerpt
    log = <<~LOG
      File /etc/network/wifi.yml does not exist
      Loading app.mrb
      uninitialized constant Regexp (NameError)
    LOG
    verdict = QemuGate.verdict(log)
    refute verdict.pass
  end

  def test_verdict_passes_on_real_pos_log_excerpt_shaped_marker
    log = <<~LOG
      File /etc/network/wifi.yml does not exist
      Loading app.mrb
      PROBE parse_touch=2
      QEMU_PROBE_OK
      Starting shell...
    LOG
    verdict = QemuGate.verdict(log)
    assert verdict.pass
  end

  def test_verdict_fails_on_any_error_class_line_including_ones_outside_a_fixed_list
    %w[KeyError IndexError ZeroDivisionError StopIteration::FooError].each do |klass|
      verdict = QemuGate.verdict("(unknown):0: boom (#{klass})\nLoading app.mrb\nQEMU_PROBE_OK\n")
      refute verdict.pass, klass
    end
  end

  def test_verdict_does_not_treat_idf_log_lines_as_errors
    log = "E (123) spi_flash: detected chip: issi\nW (857) eFuse: calibration efuse version does not match, set default version to 0\nLoading app.mrb\nQEMU_PROBE_OK\n"
    assert QemuGate.verdict(log).pass
  end

  def test_verdict_is_decided_on_pass_and_on_failure_but_not_while_waiting
    assert QemuGate.verdict("Loading app.mrb\nQEMU_PROBE_OK\n").decided
    assert QemuGate.verdict("Guru Meditation Error\n").decided
    refute QemuGate.verdict("Initializing FLASH disk as the root volume...\n").decided
  end

  def test_flash_console_ok_requires_the_usb_serial_jtag_console_define
    assert QemuGate.flash_console_ok?("#define CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG 1\n")
    refute QemuGate.flash_console_ok?("#define CONFIG_ESP_CONSOLE_UART_DEFAULT 1\n#define CONFIG_ESP_CONSOLE_UART 1\n")
  end

  private

  def fixture_with_no_requires
    file = Tempfile.new(['fixture_app_norequire', '.rb'])
    file.write("class Widget\n  def ping = :pong\nend\n")
    file.close
    at_exit { File.unlink(file.path) if File.exist?(file.path) }
    file.path
  end

  def mrbc_path
    path = File.join(ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32", "picoruby",
                      "build", "host-picotest", "bin", "mrbc")
    File.executable?(path) ? path : nil
  end

  def with_tempfile(source)
    src = Tempfile.new(['probe', '.rb'])
    src.write(source)
    src.close
    mrb = Tempfile.new(['probe', '.mrb'])
    mrb.close
    yield src.path, mrb.path
  ensure
    src.unlink
    mrb.unlink
  end
end
