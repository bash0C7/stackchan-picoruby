require "bundler/setup" if File.exist?(File.expand_path("Gemfile", __dir__))
require_relative "lib/deploy/picomodem"
require_relative "lib/deploy/shell_recovery"

# Vendored build trees, fetched by `rake vendor:setup` (git clone --branch REF
# REPO vendor/NAME) instead of assumed present as hand-placed sibling
# directories. ENV-overridable so a fork/branch swap doesn't need editing
# this file — mirrors the R2P2-darwin/R2P2-macOS `PICORUBY_REPO`/`PICORUBY_REF`
# convention.
R2P2_ESP32_REPO = ENV["R2P2_ESP32_REPO"] || "https://github.com/bash0C7/R2P2-ESP32.git"
R2P2_ESP32_REF  = ENV["R2P2_ESP32_REF"]  || "stackchan-integration"
R2P2_ROOT       = File.expand_path("vendor/R2P2-ESP32", __dir__)

R2P2_DARWIN_REPO = ENV["R2P2_DARWIN_REPO"] || "https://github.com/bash0C7/R2P2-darwin.git"
R2P2_DARWIN_REF  = ENV["R2P2_DARWIN_REF"]  || "main"
R2P2_DARWIN_ROOT = File.expand_path("vendor/R2P2-darwin", __dir__)

namespace :vendor do
  desc "Fetch both vendored build trees (R2P2-ESP32, R2P2-darwin)"
  task setup: ["vendor:r2p2_esp32:setup", "vendor:r2p2_darwin:setup"]

  namespace :r2p2_esp32 do
    desc "Clone R2P2_ESP32_REPO@R2P2_ESP32_REF into vendor/R2P2-ESP32 (skip if present)"
    task :setup do
      unless Dir.exist?(R2P2_ROOT)
        sh "git clone --recursive --branch #{R2P2_ESP32_REF} #{R2P2_ESP32_REPO} #{R2P2_ROOT}"
      end
    end

    desc "Re-fetch R2P2_ESP32_REF into the existing vendor/R2P2-ESP32 (no re-clone)"
    task :refresh do
      raise "vendor/R2P2-ESP32 absent; run `rake vendor:r2p2_esp32:setup` first" unless Dir.exist?(R2P2_ROOT)
      sh "git -C #{R2P2_ROOT} fetch #{R2P2_ESP32_REPO} #{R2P2_ESP32_REF}"
      sh "git -C #{R2P2_ROOT} checkout -B #{R2P2_ESP32_REF} FETCH_HEAD"
      sh "git -C #{R2P2_ROOT} submodule update --init --recursive"
    end
  end

  namespace :r2p2_darwin do
    desc "Clone R2P2_DARWIN_REPO@R2P2_DARWIN_REF into vendor/R2P2-darwin (skip if present)"
    task :setup do
      unless Dir.exist?(R2P2_DARWIN_ROOT)
        sh "git clone --branch #{R2P2_DARWIN_REF} #{R2P2_DARWIN_REPO} #{R2P2_DARWIN_ROOT}"
      end
    end

    desc "Re-fetch R2P2_DARWIN_REF into the existing vendor/R2P2-darwin (no re-clone)"
    task :refresh do
      raise "vendor/R2P2-darwin absent; run `rake vendor:r2p2_darwin:setup` first" unless Dir.exist?(R2P2_DARWIN_ROOT)
      sh "git -C #{R2P2_DARWIN_ROOT} fetch #{R2P2_DARWIN_REPO} #{R2P2_DARWIN_REF}"
      sh "git -C #{R2P2_DARWIN_ROOT} checkout -B #{R2P2_DARWIN_REF} FETCH_HEAD"
    end
  end
end

# Host picotest VM (test/device/*_test.rb) reuses R2P2-ESP32's own picoruby
# submodule rather than fetching a third independent picoruby tree — this is
# the same picoruby build the device firmware actually runs, so host-VM
# quirks (string/idiom differences from CRuby) match device behavior instead
# of an unrelated upstream checkout's.
PICORUBY_ROOT = ENV["PICORUBY_ROOT"] || File.join(R2P2_ROOT, "components", "picoruby-esp32", "picoruby")
PICORUBY_VM   = File.join(PICORUBY_ROOT, "build", "host", "bin", "picoruby")

desc "Run the PicoRuby-native device test suite (alias of picotest:run)"
task :test => "picotest:run"

namespace :test do
  desc "Run CRuby-only host tests (RubyClassExtract extractor)"
  task :host do
    sh "bundle exec ruby -Ilib -Itest-host test-host/ruby_class_extract_test.rb"
  end
end

# Load the application's Face classes + FakeDisplay into THIS CRuby process,
# without test_helper (so the golden tasks survive the picotest migration).
def load_face_context
  $LOAD_PATH.unshift(File.expand_path('lib', __dir__))
  $LOAD_PATH.unshift(File.expand_path('test', __dir__))
  load File.expand_path('test/picotest/stubs.rb', __dir__)
  require 'ruby_class_extract'
  RubyClassExtract.load_classes_from(File.expand_path('app/application.rb', __dir__), exclude_superclasses: %w[BLE])
  require 'fake_display'
  require 'face_golden_hash'
end

namespace :face do
  desc "Compute canonical draw-call dump of StackchanApp::Face::<NAME> and write " \
       "spec/golden/face_<NAME>.dump. " \
       "Usage: bundle exec rake face:register_golden FACE=neutral|smile|joy|surprised|sad|angry|closed"
  task :register_golden do
    name = ENV.fetch('FACE') { abort 'FACE=<name> required' }
    load_face_context
    klass = FaceGoldenHash::FACE_CASES.fetch(name.to_sym) do
      abort "unknown FACE=#{name}; one of: #{FaceGoldenHash::FACE_CASES.keys.join(' / ')}"
    end
    out = File.expand_path("spec/golden/face_#{name}.dump", __dir__)
    File.write(out, FaceGoldenHash.compute_dump(klass))
    puts "[face:register_golden] wrote #{out}"
  end

  desc "Register goldens for ALL faces (.dump). Usage: bundle exec rake face:register_all_goldens"
  task :register_all_goldens do
    load_face_context
    FaceGoldenHash::FACE_CASES.each do |name, klass|
      out = File.expand_path("spec/golden/face_#{name}.dump", __dir__)
      File.write(out, FaceGoldenHash.compute_dump(klass))
      puts "[register_all] #{out}"
    end
  end
end

namespace :picotest do
  desc "Force-build the host picoruby test VM (MRUBY_CONFIG=picoruby-test). Run after a picoruby update."
  task :build do
    abort "picoruby tree not found: #{PICORUBY_ROOT}\n  set PICORUBY_ROOT, or clone picoruby/picoruby there." unless File.directory?(PICORUBY_ROOT)
    Dir.chdir(PICORUBY_ROOT) { sh "MRUBY_CONFIG=picoruby-test rake all" }
  end

  # Prerequisite for :run — builds the VM only when the binary is missing, so
  # `rake test` is self-bootstrapping on a fresh checkout. `picotest:build`
  # stays the explicit force-rebuild path after a picoruby update.
  task :ensure_vm do
    Rake::Task["picotest:build"].invoke unless File.executable?(PICORUBY_VM)
  end

  desc "Run the PicoRuby-native device suite (test/device/*_test.rb) on the host picoruby VM. FILTER=<substr> to scope."
  task :run => :ensure_vm do
    $LOAD_PATH.unshift File.expand_path("test", __dir__)
    require "picotest/harness"
    exit PicotestHarness.run(filter: ENV["FILTER"])
  end
end

ESP_IDF_EXPORT = File.expand_path('~/esp/esp-idf/export.sh')
ESP_PYTHON = File.expand_path('~/.espressif/python_env/idf5.4_py3.14_env/bin/python')

SDKCONFIG_DEFAULTS_CORES3 = 'sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3;sdkconfigs/bt_nimble'
PICORUBY_BUILD_DIR = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/build/esp32-picoruby"
LONGRUN_DIR = File.expand_path('tmp/longrun', __dir__)
SERIAL_LOG_DEFAULT = "#{LONGRUN_DIR}/serial.log"

def detect_espport
  candidates = Dir.glob('/dev/cu.usbmodem*').sort
  case candidates.size
  when 0
    abort 'ESPPORT not set and no /dev/cu.usbmodem* device found. Plug the CoreS3 in or set ESPPORT=...'
  when 1
    candidates.first
  else
    warn "multiple /dev/cu.usbmodem* devices found, using #{candidates.first} (override with ESPPORT=...): #{candidates.inspect}"
    candidates.first
  end
end

def espport
  ENV.fetch('ESPPORT') { detect_espport }
end

def in_r2p2(*args)
  abort "vendor/R2P2-ESP32 not found — run `rake vendor:r2p2_esp32:setup` first" unless Dir.exist?(R2P2_ROOT)
  cmd = args.join(' ')
  sh %Q{bash -c '. #{ESP_IDF_EXPORT} && cd #{R2P2_ROOT} && #{cmd}'}
end

def upload_mrb_via_picomodem(src:, dst:, port:)
  picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/mrbc"
  abort "mrbc not found at #{picorbc} — run `rake r2p2:setup` first" unless File.executable?(picorbc)
  build_dir = File.expand_path('tmp/build', __dir__)
  mkdir_p build_dir
  base = File.basename(src, File.extname(src))
  mrb_path = File.join(build_dir, "#{base}.mrb")
  rm_f mrb_path
  sh picorbc, '-o', mrb_path, src
  abort "mrbc produced no output at #{mrb_path}" unless File.exist?(mrb_path)
  puts "[upload_mrb] compiled #{src} -> #{mrb_path} (#{File.size(mrb_path)} bytes)"
  Deploy::Picomodem.upload(src: mrb_path, dst: dst, port: port)
end

# idf.py never re-applies SDKCONFIG_DEFAULTS to an already-existing sdkconfig,
# so edits to any fragment listed in SDKCONFIG_DEFAULTS_CORES3 are silently
# ignored on the next build. Detect that case by mtime and nuke sdkconfig so
# the next build regenerates it from the fragments. (2026-05-15 finding —
# CONFIG_SW_COEXIST_ENABLE override was being dropped this way.)
def ensure_sdkconfig_fresh
  sdkconfig = "#{R2P2_ROOT}/sdkconfig"
  unless File.exist?(sdkconfig)
    puts "[r2p2] sdkconfig missing — will be generated from defaults"
    return
  end
  cfg_mtime = File.mtime(sdkconfig)
  stale = SDKCONFIG_DEFAULTS_CORES3.split(';').filter_map do |rel|
    path = File.join(R2P2_ROOT, rel)
    File.exist?(path) && File.mtime(path) > cfg_mtime ? rel : nil
  end
  return if stale.empty?
  puts "[r2p2] sdkconfig fragment(s) newer than sdkconfig: #{stale.inspect} — regenerating"
  rm sdkconfig
end

# Abort if `idf_monitor.py` is already attached to the serial port. macOS
# allows multiple readers on /dev/cu.usbmodem*, but USB CDC bytes are
# delivered to whichever reader claims them first → uploader's FILE_ACK
# disappears into monitor's stdin, esptool's chip-detect handshake races
# against monitor's auto-reset suppression, and humans see "FILE_ACK got
# nil" with no obvious cause. Detect via `ps` (python ... idf_monitor.py)
# and tell the human to detach (Ctrl+]). Guarded tasks: every r2p2:* that
# opens or writes to the serial port.
def ensure_no_concurrent_monitor
  ps_out = `ps -axo pid=,command= 2>/dev/null`
  hits = ps_out.lines.select { |l| l =~ %r{python[^\s]*\s.*idf_monitor\.py} }
  return if hits.empty?
  pids = hits.map { |l| l.strip.split(' ', 2).first }
  abort "[monitor guard] idf_monitor.py is running (pid=#{pids.join(',')}). " \
        "A human session likely has `rake r2p2:monitor` open — Ctrl+] to detach, " \
        "then retry. If stale: kill #{pids.join(' ')}"
end

namespace :r2p2 do
  desc 'deep clean + mruby rebuild + idf.py set-target esp32s3 (with CoreS3 sdkconfig)'
  task :setup do
    in_r2p2 %Q{rm -f sdkconfig && SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}" rake setup_esp32s3}
  end

  # Removing libmruby.a alone is not enough: rake re-archives it from the
  # object list, so a .o whose source moved or changed identity is silently
  # carried into the new archive. Two link failures on 2026-08-22 came from
  # exactly that (a 12-day-old ble.o still referencing a deleted symbol, and a
  # machine.o predating the estalloc relocation). Drop the whole build dir so
  # every gem object is recompiled from the tree that is actually checked out.
  desc 'rm picoruby build dir so the next build recompiles every gem object from the current tree'
  task :clean_picoruby_build do
    if Dir.exist?(PICORUBY_BUILD_DIR)
      rm_rf PICORUBY_BUILD_DIR
      puts "[r2p2] removed #{PICORUBY_BUILD_DIR} — next build recompiles all gems"
    else
      puts "[r2p2] picoruby build dir already absent"
    end
  end

  desc "build with CoreS3 sdkconfig (QUAD PSRAM + 16MB flash, VM=mruby)"
  task :build => :clean_picoruby_build do
    ensure_sdkconfig_fresh
    in_r2p2 %Q{SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}" rake picoruby:build}
  end

  desc "flash to CoreS3 via USB CDC (override with ESPPORT=...)"
  task :flash do
    ensure_no_concurrent_monitor
    port = espport
    in_r2p2 %Q{ESPPORT=#{port} rake flash}
  end

  desc 'build + flash in one shot (default workflow for code iteration)'
  task :build_flash => :clean_picoruby_build do
    ensure_no_concurrent_monitor
    ensure_sdkconfig_fresh
    port = espport
    in_r2p2 %Q{SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}" ESPPORT=#{port} rake picoruby:build flash}
  end

  desc 'idf.py monitor (HUMAN USE ONLY — claude code Bash has no TTY)'
  task :monitor do
    ensure_no_concurrent_monitor
    port = espport
    in_r2p2 %Q{ESPPORT=#{port} rake monitor}
  end

  desc 'cat ESPPORT into SERIAL_LOG (claude code: launch via run_in_background, then rake r2p2:reset)'
  task :capture do
    ensure_no_concurrent_monitor
    port = espport
    log = ENV.fetch('SERIAL_LOG', SERIAL_LOG_DEFAULT)
    mkdir_p File.dirname(log)
    sh "cat #{port} > #{log}"
  end

  # CoreS3 uses ESP32-S3's native USB-Serial/JTAG peripheral, which drops and
  # re-enumerates the CDC connection for ~0.5-2s around every chip reset
  # (RTS-pulse `r2p2:reset` included, not just physical replug). A plain `cat`
  # holds one fd across that gap and goes silent forever once the far end
  # drops it — reproduced empirically 2026-07-23: a bare `cat` opened <0.3s
  # after reset caught only the first ~7 boot lines then never received
  # another byte for 30+s despite the device continuing to boot and run.
  # This task retries open() in a loop for DURATION seconds so the very first
  # few seconds of boot (BLE_INIT, this gem's own hci_power_control/esp_timer
  # diagnostics, etc.) are never silently missed. See
  # docs/superpowers/handoff/2026-07-22-ble-role-coverage-verification-evidence.md.
  #
  # Reopening only on an exception is not enough: a re-enumeration can leave the
  # fd readable-but-dead, where read() raises nothing and just returns b''
  # forever. Observed 2026-08-22 — a capture caught 286 bytes of boot, then held
  # the port silent for the rest of DURATION while the device ran a probe that
  # printed throughout. So treat a long gap with no bytes as a dead link and
  # reopen. IDLE_REOPEN_S must stay above the device's real quiet stretches
  # (the BLE heartbeat prints about once a second).
  desc 'capture ESPPORT into SERIAL_LOG with automatic reconnect across USB-Serial-JTAG reset blips (DURATION=seconds, default 30)'
  task :capture_resilient do
    ensure_no_concurrent_monitor
    port = espport
    log = ENV.fetch('SERIAL_LOG', SERIAL_LOG_DEFAULT)
    duration = (ENV['DURATION'] || 30).to_f
    mkdir_p File.dirname(log)
    sh ESP_PYTHON, '-c', <<~PY
      import serial, time
      port = #{port.inspect}
      deadline = time.time() + #{duration}
      IDLE_REOPEN_S = 5.0
      reopens = 0
      with open(#{log.inspect}, 'wb') as f:
          while time.time() < deadline:
              try:
                  # Deassert DTR/RTS before open(): on this board those lines
                  # drive reset and download mode, and pyserial asserts both by
                  # default, so an unconfigured open would reset the chip on
                  # every reconnect. exclusive=False matches r2p2:reset.
                  s = serial.Serial(baudrate=115200, timeout=0.2, exclusive=False)
                  s.port = port
                  s.dtr = False
                  s.rts = False
                  s.open()
              except Exception:
                  time.sleep(0.05)
                  continue
              last_data = time.time()
              try:
                  while time.time() < deadline:
                      data = s.read(4096)
                      if data:
                          f.write(data)
                          f.flush()
                          last_data = time.time()
                      elif time.time() - last_data > IDLE_REOPEN_S:
                          reopens += 1
                          break
              except Exception:
                  pass
              finally:
                  try:
                      s.close()
                  except Exception:
                      pass
      print('[r2p2:capture_resilient] done reopens=%d' % reopens)
    PY
  end

  desc 'pulse RTS to reset CoreS3, then capture_resilient in the SAME process (avoids paying rake/bundler startup twice, which otherwise misses the first several seconds of boot). SERIAL_LOG=path DURATION=seconds'
  task :reset_and_capture do
    Rake::Task['r2p2:reset'].invoke
    Rake::Task['r2p2:capture_resilient'].invoke
  end

  desc 'sleep N seconds inside the rake process — use to chain device tasks in one invocation, e.g. `rake r2p2:wipe_storage r2p2:wait[15] r2p2:upload_appmrb r2p2:reset` (quote in shells that gobble brackets)'
  task :wait, [:seconds] do |_t, args|
    seconds = (args[:seconds] || ENV['WAIT'] || 1).to_f
    puts "[r2p2:wait] sleeping #{seconds}s"
    sleep seconds
  end

  desc 'pulse RTS to reset CoreS3 (claude code has no TTY for `idf.py monitor`)'
  task :reset do
    ensure_no_concurrent_monitor
    port = espport
    sh ESP_PYTHON, '-c', <<~PY
      import serial, time
      s = serial.Serial('#{port}', exclusive=False)
      s.dtr = False
      s.rts = True
      time.sleep(0.15)
      s.rts = False
      s.close()
      print('reset sent')
    PY
  end

  # Future-proof: present R2P2 build exits main_task after SIGINT and never
  # re-prints a shell prompt over USB-CDC, so this task does not actually
  # recover anything on the current build. Kept for the day shell echo
  # behavior is restored upstream — see lib/deploy/shell_recovery.rb header
  # for the diagnostic context. For working recovery today, use `wipe_storage`.
  desc 'interrupt autostart via Ctrl-C and rm /home/app.mrb (press M5Stack reset button immediately before invoking)'
  task :rm_appmrb do
    ensure_no_concurrent_monitor
    port = espport
    Deploy::ShellRecovery.rm_app(port: port)
  end

  # Generic R2P2-ESP32 (CoreS3) storage partition erase: nukes /home/* so the
  # next boot starts with no autostart payload. Useful for any picoruby app
  # whose /home/app.mrb panic-loops, jams PicoModem handshake, or otherwise
  # locks out the shell. Storage partition layout is 0x410000-0x510000 (1MB).
  # CRITICAL: this offset MUST match the partition table. The factory partition
  # was expanded 2M->4M for the shinonome font firmware (2026-06-17), so storage
  # moved 0x210000 -> 0x410000. The OLD hardcoded 0x210000 erased the MIDDLE of
  # the 4M factory partition and bricked the firmware ("No bootable app
  # partitions"). If you change partitions.csv, update this offset in lockstep.
  # ~7s end-to-end.
  desc 'erase storage partition (0x410000-0x510000, ~1MB) — fast app.mrb recovery without full flash'
  task :wipe_storage do
    ensure_no_concurrent_monitor
    port = espport
    Dir.chdir(R2P2_ROOT) do
      sh "bash -c '. #{ESP_IDF_EXPORT} && #{ESP_PYTHON} -m esptool -p #{port} erase_region 0x410000 0x100000'"
    end
  end

  desc 'host-compile SRC=path/to/foo.rb to .mrb and upload to DST=/home/path/foo.mrb'
  task :upload_mrb do
    ensure_no_concurrent_monitor
    src = ENV.fetch('SRC') { abort 'SRC=path/to/foo.rb required for r2p2:upload_mrb' }
    dst = ENV.fetch('DST') { abort 'DST=/home/...mrb required for r2p2:upload_mrb' }
    src_path = File.expand_path(src, __dir__)
    abort "SRC not found: #{src_path}" unless File.exist?(src_path)
    upload_mrb_via_picomodem(src: src_path, dst: dst, port: espport)
  end

  desc 'host-compile SRC=path/to/app.rb and upload as autostart payload /home/app.mrb'
  task :upload_appmrb do
    ensure_no_concurrent_monitor
    src = ENV.fetch('SRC') { abort 'SRC=path required for r2p2:upload_appmrb' }
    src_path = File.expand_path(src, __dir__)
    abort "SRC not found: #{src_path}" unless File.exist?(src_path)
    upload_mrb_via_picomodem(src: src_path, dst: '/home/app.mrb', port: espport)
  end

  # Bake SRC (compiled to app.mrb) into the littlefs storage image, then flash
  # firmware + storage in a single esptool pass. R2P2-ESP32's littlefs image is
  # rebuilt from `storage/home/` on every `idf.py build` (FLASH_IN_PROJECT), and
  # `idf.py flash` writes storage.bin at 0x210000 alongside the app binary. So
  # placing app.mrb at R2P2_ROOT/storage/home/app.mrb before build makes it land
  # at /home/app.mrb on device with NO runtime picomodem USB upload. Use this
  # when the firmware is being rebuilt anyway, or when the shell cannot be
  # reached at all. It is NOT the way to avoid a USB replug: the picomodem path
  # resets the board and waits for the shell banner itself, and needs no human
  # (verified 2026-07-31, 5/5 consecutive uploads with the cable untouched).
  # Does NOT reset; the esptool flash performs its own hard-reset, and boot
  # capture is done separately so the monitor guard does not race the flasher.
  desc 'host-compile SRC=app.rb → bake into littlefs /home/app.mrb → build+flash firmware+storage in one pass (no picomodem; SRC=path required)'
  task :build_flash_appmrb => :clean_picoruby_build do
    ensure_no_concurrent_monitor
    ensure_sdkconfig_fresh
    src = ENV.fetch('SRC') { abort 'SRC=path/to/app.rb required for r2p2:build_flash_appmrb' }
    src_path = File.expand_path(src, __dir__)
    abort "SRC not found: #{src_path}" unless File.exist?(src_path)
    picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/mrbc"
    abort "mrbc not found at #{picorbc} — run `rake r2p2:setup` first" unless File.executable?(picorbc)
    mrb_dest = "#{R2P2_ROOT}/storage/home/app.mrb"
    mkdir_p File.dirname(mrb_dest)
    rm_f mrb_dest
    sh picorbc, '-o', mrb_dest, src_path
    abort "mrbc produced no output at #{mrb_dest}" unless File.exist?(mrb_dest)
    puts "[build_flash_appmrb] baked #{src_path} -> #{mrb_dest} (#{File.size(mrb_dest)} bytes)"
    port = espport
    in_r2p2 %Q{SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}" ESPPORT=#{port} rake picoruby:build flash}
    puts "[build_flash_appmrb] PASS — firmware + #{File.basename(src_path)} (baked into littlefs /home/app.mrb) flashed. esptool hard-reset will autostart it."
  end

  desc 'full device rebuild chain: build_flash → wipe_storage → upload_appmrb → reset (SRC=app.rb required, ~7 min total)'
  task :full_rebuild do
    src = ENV.fetch('SRC') { abort 'SRC=path/to/app.rb required for r2p2:full_rebuild' }
    ensure_no_concurrent_monitor
    Rake::Task['r2p2:build_flash'].invoke
    sleep 3  # USB CDC renum settle after esptool flash
    Rake::Task['r2p2:wipe_storage'].invoke
    # Waits only for the /dev node to come back after esptool's hard-reset;
    # upload_appmrb needs it to exist before it can pulse a reset of its own.
    # Shell come-up is not timed here — the uploader waits for the banner.
    sleep 12
    ENV['SRC'] = src
    Rake::Task['r2p2:upload_appmrb'].invoke
    Rake::Task['r2p2:reset'].invoke
    puts "[r2p2:full_rebuild] PASS — firmware rebuilt + #{src} deployed as /home/app.mrb + device reset"
  end

  # E2E smoke: upload application.mrb → reset → wait autostart → torque ON
  # → send a YL/YR/PU position frame via stackchan-ble-control. Defaults
  # exercise a half-left + center-pitch sweep within the protocol's
  # normalized magnitude range (0-100).
  desc 'BLE servo E2E smoke (YL=50 PU=0 T=500 AUTOSTART_WAIT=12 — torque is enabled automatically)'
  task :ble_servo_smoke do
    yl       = ENV['YL']
    yr       = ENV['YR']
    pu       = ENV.fetch('PU', '0')
    time_ms  = ENV.fetch('T',  '500')
    autostart_wait = ENV.fetch('AUTOSTART_WAIT', '12').to_i

    if yl.nil? && yr.nil?
      yl = '50'  # default: half-left sweep
    end

    ENV['SRC'] = 'app/application.rb'
    Rake::Task['r2p2:upload_appmrb'].invoke
    Rake::Task['r2p2:reset'].invoke

    puts "[servo_smoke] waiting #{autostart_wait}s for autostart + BLE advertise"
    sleep autostart_wait

    stackchan = File.expand_path('pc/stackchan-pico/bin/stackchan', __dir__)
    Bundler.with_unbundled_env do
      ok = system(stackchan, 'torque', 'on')
      abort "[servo_smoke] torque on FAIL" unless ok
      sleep 1
      args = [stackchan, 'servo', '--time', time_ms, '--pitch-up', pu]
      args += ['--yaw-left',  yl] if yl
      args += ['--yaw-right', yr] if yr
      ok = system(*args)
      unless ok
        exit $?.exitstatus
      end
    end

    puts "[servo_smoke] PASS — YL=#{yl} YR=#{yr} PU=#{pu} T=#{time_ms} — visual motion check please"
  end

  # E2E smoke: cold-boot → torque on → torque off cycle. Visual: face
  # transitions Closed → Neutral (torque on) → Closed (torque off);
  # servos audibly engage / disengage at each step.
  desc 'BLE torque on/off E2E smoke (cold-boot → torque on → torque off cycle)'
  task :ble_torque_smoke do
    autostart_wait = ENV.fetch('AUTOSTART_WAIT', '12').to_i
    ENV['SRC'] = 'app/application.rb'
    Rake::Task['r2p2:upload_appmrb'].invoke
    Rake::Task['r2p2:reset'].invoke

    puts "[torque_smoke] waiting #{autostart_wait}s for autostart"
    sleep autostart_wait

    stackchan = File.expand_path('pc/stackchan-pico/bin/stackchan', __dir__)
    Bundler.with_unbundled_env do
      %w[on off].each do |state|
        ok = system(stackchan, 'torque', state)
        abort "[torque_smoke] torque #{state} FAIL" unless ok
        sleep 2
      end
    end

    puts "[torque_smoke] PASS — torque on/off cycle complete (visual: face changed Closed→Neutral→Closed)"
  end

  # HITL servo calibration check — sweeps 5 positions, prompts human Y/N
  # for each. Operator MUST be present at the device. The operator first
  # physically aligns the head forward (cold-boot is torque-off Face::Closed
  # so this is a hand-move), then engages torque on, then the rake task
  # walks through the 5-position visual sweep.
  desc 'HITL servo calibration check — sweeps 5 positions, prompts human Y/N for each'
  task :ble_calibration_check do
    autostart_wait = ENV.fetch('AUTOSTART_WAIT', '12').to_i
    ENV['SRC'] = 'app/application.rb'
    Rake::Task['r2p2:upload_appmrb'].invoke
    Rake::Task['r2p2:reset'].invoke

    puts "[cal] waiting #{autostart_wait}s for autostart"
    sleep autostart_wait

    puts "[cal] OPERATOR: physically align StackChan's head to face forward, then press ENTER"
    STDIN.gets

    positions = [
      { label: 'center (forward)', args: ['--yaw-left', '0',   '--pitch-up', '0'],   expect: 'facing forward' },
      { label: 'yaw-right end',    args: ['--yaw-right', '100'],                       expect: "head turned to StackChan's right (operator's left)" },
      { label: 'yaw-left end',     args: ['--yaw-left',  '100'],                       expect: "head turned to StackChan's left (operator's right)" },
      { label: 'pitch-up end',     args: ['--yaw-left', '0', '--pitch-up', '100'],   expect: 'head tilted fully up' },
      { label: 'center (return)',  args: ['--yaw-left', '0', '--pitch-up', '0'],     expect: 'facing forward again' },
    ]

    stackchan = File.expand_path('pc/stackchan-pico/bin/stackchan', __dir__)
    Bundler.with_unbundled_env do
      ok = system(stackchan, 'torque', 'on')
      abort '[cal] torque on FAIL' unless ok
      sleep 1

      positions.each_with_index do |pos, i|
        puts "\n[cal #{i + 1}/5] sending #{pos[:label]} → expect: #{pos[:expect]}"
        ok = system(stackchan, 'servo', '--time', '800', *pos[:args])
        abort "[cal] frame send FAIL at #{pos[:label]}" unless ok
        sleep 1.5
        print '   Did StackChan move as expected? [y/N]: '
        ans = STDIN.gets.to_s.strip.downcase
        abort "[cal] FAIL at #{pos[:label]} (operator marked N)" unless ans == 'y'
      end

      system(stackchan, 'torque', 'off')
    end

    puts "\n[cal] PASS — all 5 positions visually confirmed"
  end

  # E2E smoke: upload application.mrb → reset → wait autostart → send a
  # control frame via stackchan-ble-control combo. Exits with the CLI's
  # exit code so the rake invocation surfaces structured failure (0/2/3/4/5).
  desc 'BLE control E2E smoke (COLOR=red MODE=blink FACE=joy SIDE=both AUTOSTART_WAIT=12)'
  task :ble_control_smoke do
    color = ENV.fetch('COLOR', 'red')
    mode  = ENV.fetch('MODE',  'solid')
    face  = ENV.fetch('FACE',  'neutral')
    side  = ENV.fetch('SIDE',  'both')
    autostart_wait = ENV.fetch('AUTOSTART_WAIT', '12').to_i

    # Mac CoreBluetooth scan is known to truncate / cache device names, stripping
    # long suffixes. Epoch suffix design is ineffective on macOS host side.
    # (Web research confirms no effective host-side workaround: sudo pkill bluetoothd
    # and active scan only provide temporary relief, not root fix.)
    # → Retired epoch suffix infrastructure. Device discovery now uses fixed base name.
    # Single board per session, so "StackChan-PicoRuby" prefix is unique.
    ENV['SRC'] = 'app/application.rb'
    Rake::Task['r2p2:upload_appmrb'].invoke
    Rake::Task['r2p2:reset'].invoke

    puts "[smoke] waiting #{autostart_wait}s for autostart (5s escape + BLE init + advertise)"
    sleep autostart_wait

    # The project-root Bundler env (loaded at the top of this Rakefile) leaks
    # into any child `bundle exec` the stackchan wrapper spawns (e.g. the
    # sidecar). Drop the outer env so those children read their own Gemfile.
    stackchan = File.expand_path('pc/stackchan-pico/bin/stackchan', __dir__)
    Bundler.with_unbundled_env do
      ok = system(stackchan, 'face', face)
      unless ok
        exit $?.exitstatus
      end
      ok = system(stackchan, 'led', side, color, mode)
      unless ok
        exit $?.exitstatus
      end
    end

    puts "[smoke] PASS — face=#{face} LED=#{color} #{mode} (side=#{side}) — visual check please"
  end

  desc 'face verify: host golden-SHA assert + device BLE write + ACK (FACE=neutral|smile|joy|surprised|sad|angry, requires registered golden)'
  task :face_verify do
    face = ENV.fetch('FACE') { abort 'FACE=<name> required for r2p2:face_verify' }
    valid_faces = %w[neutral smile joy surprised sad angry]
    abort "unknown FACE=#{face}; one of: #{valid_faces.join(' / ')}" unless valid_faces.include?(face)

    # Leg 1: host golden SHA — fast (<2s), no device touch.
    Bundler.with_unbundled_env do
      Dir.chdir(__dir__) do  # project root, where test/device/face_golden_test.rb lives
        # picotest filters by filename substring (no per-method filter); face_golden runs all 7 face goldens on the host VM
        ok = system('bundle', 'exec', 'rake', 'test', 'FILTER=face_golden')
        abort "[face_verify] host golden SHA FAIL for face=#{face}" unless ok
      end
    end
    puts "[face_verify] host golden SHA PASS for face=#{face}"

    # Leg 2: device BLE round-trip — slower (~20-30s with autostart wait).
    ENV['FACE'] = face
    ENV['COLOR'] ||= 'white'
    ENV['MODE']  ||= 'solid'
    ENV['SIDE']  ||= 'both'
    Rake::Task['r2p2:ble_control_smoke'].invoke

    puts "[face_verify] PASS — face=#{face} host SHA matched + device ACK received"
  end

  desc "smoke test the calibrate CLI in --align-only mode (interactive, requires connected device)"
  task :ble_calibration_smoke do
    ensure_no_concurrent_monitor
    stackchan = File.expand_path('pc/stackchan-pico/bin/stackchan', __dir__)
    Bundler.with_unbundled_env { sh stackchan, 'calibrate', '--align-only' }
  end

end

# macOS refuses (hard SIGABRT, TCC namespace "privacy-sensitive data without a
# usage description") any CoreBluetooth call from a process that isn't
# launched through LaunchServices out of an app bundle declaring
# NSBluetoothAlwaysUsageDescription — even a direct fork/exec of the identical
# binary+identifier that already has Bluetooth authorization granted from a
# prior `open`-launched run. bin/stackchan's real-mode daemon spawn therefore
# goes through `open -a` against this bundle, never a direct exec of the raw
# build/host/bin/picoruby. Re-run this task after every macos:build (the
# ad-hoc code signature — and thus the granted TCC authorization — is tied to
# the binary's exact bytes, so a rebuild invalidates it, same as any other
# ad-hoc-signed dev binary on this machine).
namespace :pc do
  desc "(re)build ~/Applications/StackchanPico.app wrapping vendor/R2P2-darwin's built VM, so real-mode BLE (CoreBluetooth) can pass macOS TCC"
  task :app_bundle do
    vm = File.expand_path("vendor/R2P2-darwin/build/host/bin/picoruby", __dir__)
    abort "#{vm} not found — run `MRUBY_CONFIG=$(pwd)/vendor/R2P2-darwin/build_config/r2p2-stackchan-pc.rb bundle exec rake -f vendor/R2P2-darwin/Rakefile macos:build` first" unless File.exist?(vm)
    app = File.expand_path("~/Applications/StackchanPico.app")
    macos_dir = File.join(app, "Contents", "MacOS")
    mkdir_p macos_dir
    cp vm, File.join(macos_dir, "picoruby")
    cp File.expand_path("pc/stackchan-pico/StackchanPico-Info.plist", __dir__), File.join(app, "Contents", "Info.plist")
    sh "codesign", "--force", "--deep", "-s", "-", app
    puts "[pc:app_bundle] #{app} ready (STACKCHAN_PICORUBY_APP defaults here)"
  end
end
