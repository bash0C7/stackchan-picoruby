require "bundler/setup" if File.exist?(File.expand_path("Gemfile", __dir__))
require_relative "lib/deploy/picomodem"
require_relative "lib/deploy/shell_recovery"

PICORUBY_ROOT = ENV["PICORUBY_ROOT"] || "/Users/bash/dev/src/github.com/picoruby/picoruby"

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
  desc "Build the host picoruby test VM (MRUBY_CONFIG=picoruby-test). One-time / after picoruby update."
  task :build do
    Dir.chdir(PICORUBY_ROOT) { sh "MRUBY_CONFIG=picoruby-test rake all" }
  end

  desc "Run the PicoRuby-native device suite (test/device/*_test.rb) on the host picoruby VM. FILTER=<substr> to scope."
  task :run do
    binary = File.join(PICORUBY_ROOT, "build", "host", "bin", "picoruby")
    abort "host picoruby not built: #{binary}\n  run: bundle exec rake picotest:build" unless File.executable?(binary)
    $LOAD_PATH.unshift File.expand_path("test", __dir__)
    require "picotest/harness"
    exit PicotestHarness.run(filter: ENV["FILTER"])
  end
end

R2P2_ROOT = File.expand_path('../../bash0C7/R2P2-ESP32', __dir__)
ESP_IDF_EXPORT = File.expand_path('~/esp/esp-idf/export.sh')
ESP_PYTHON = File.expand_path('~/.espressif/python_env/idf5.4_py3.14_env/bin/python')

SDKCONFIG_DEFAULTS_CORES3 = 'sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3;sdkconfigs/bt_btstack'
LIBMRUBY_FILE = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/build/esp32-picoruby/lib/libmruby.a"
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
  cmd = args.join(' ')
  sh %Q{bash -c '. #{ESP_IDF_EXPORT} && cd #{R2P2_ROOT} && #{cmd}'}
end

def upload_mrb_via_picomodem(src:, dst:, port:)
  picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/picorbc"
  abort "picorbc not found at #{picorbc} — run `rake r2p2:setup` first" unless File.executable?(picorbc)
  build_dir = File.expand_path('tmp/build', __dir__)
  mkdir_p build_dir
  base = File.basename(src, File.extname(src))
  mrb_path = File.join(build_dir, "#{base}.mrb")
  rm_f mrb_path
  sh picorbc, '-o', mrb_path, src
  abort "picorbc produced no output at #{mrb_path}" unless File.exist?(mrb_path)
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

  desc 'rm libmruby.a so the next build forces picoruby rake to recompile all gems (catches mrblib/*.rb changes that idf.py build silently ignores)'
  task :clear_libmruby_cache do
    if File.exist?(LIBMRUBY_FILE)
      rm LIBMRUBY_FILE
      puts "[r2p2] cleared libmruby cache (#{LIBMRUBY_FILE}) — next build will recompile gems"
    else
      puts "[r2p2] libmruby cache already absent"
    end
  end

  desc "build with CoreS3 sdkconfig (QUAD PSRAM + 16MB flash, VM=mruby)"
  task :build do
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
  task :build_flash => :clear_libmruby_cache do
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
  # locks out the shell. Storage partition layout is 0x210000-0x310000 (1MB);
  # adjust if your sdkconfig partition table differs. ~7s end-to-end.
  desc 'erase storage partition (0x210000-0x310000, ~1MB) — fast app.mrb recovery without full flash'
  task :wipe_storage do
    ensure_no_concurrent_monitor
    port = espport
    Dir.chdir(R2P2_ROOT) do
      sh "bash -c '. #{ESP_IDF_EXPORT} && #{ESP_PYTHON} -m esptool -p #{port} erase_region 0x210000 0x100000'"
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
  # at /home/app.mrb on device with NO runtime picomodem USB upload — and thus no
  # physical USB replug. Use this when the operator is away and the normal
  # picomodem path (which needs a replug) is unavailable. Does NOT reset; the
  # esptool flash performs its own hard-reset, and boot capture is done
  # separately so the monitor guard does not race the flasher.
  desc 'host-compile SRC=app.rb → bake into littlefs /home/app.mrb → build+flash firmware+storage in one pass (no picomodem / no USB replug; SRC=path required)'
  task :build_flash_appmrb => :clear_libmruby_cache do
    ensure_no_concurrent_monitor
    ensure_sdkconfig_fresh
    src = ENV.fetch('SRC') { abort 'SRC=path/to/app.rb required for r2p2:build_flash_appmrb' }
    src_path = File.expand_path(src, __dir__)
    abort "SRC not found: #{src_path}" unless File.exist?(src_path)
    picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/picorbc"
    abort "picorbc not found at #{picorbc} — run `rake r2p2:setup` first" unless File.executable?(picorbc)
    mrb_dest = "#{R2P2_ROOT}/storage/home/app.mrb"
    mkdir_p File.dirname(mrb_dest)
    rm_f mrb_dest
    sh picorbc, '-o', mrb_dest, src_path
    abort "picorbc produced no output at #{mrb_dest}" unless File.exist?(mrb_dest)
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
    sleep 12 # USB renum + R2P2 shell come-up after esptool erase_region
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

    Bundler.with_unbundled_env do
      Dir.chdir(File.expand_path('pc/stackchan-ble-client', __dir__)) do
        ok = system('bundle', 'exec', 'exe/stackchan-ble-control',
                    '--name-prefix', 'StackChan-PicoRuby',
                    'torque', 'on')
        abort "[servo_smoke] torque on FAIL" unless ok
        sleep 1
        args = ['bundle', 'exec', 'exe/stackchan-ble-control',
                '--name-prefix', 'StackChan-PicoRuby',
                '--time', time_ms, '--pitch-up', pu]
        args += ['--yaw-left',  yl] if yl
        args += ['--yaw-right', yr] if yr
        args << 'servo'
        ok = system(*args)
        unless ok
          exit $?.exitstatus
        end
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

    Bundler.with_unbundled_env do
      Dir.chdir(File.expand_path('pc/stackchan-ble-client', __dir__)) do
        %w[on off].each do |state|
          ok = system('bundle', 'exec', 'exe/stackchan-ble-control',
                      '--name-prefix', 'StackChan-PicoRuby',
                      'torque', state)
          abort "[torque_smoke] torque #{state} FAIL" unless ok
          sleep 2
        end
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

    Bundler.with_unbundled_env do
      Dir.chdir(File.expand_path('pc/stackchan-ble-client', __dir__)) do
        ok = system('bundle', 'exec', 'exe/stackchan-ble-control',
                    '--name-prefix', 'StackChan-PicoRuby',
                    'torque', 'on')
        abort '[cal] torque on FAIL' unless ok
        sleep 1

        positions.each_with_index do |pos, i|
          puts "\n[cal #{i + 1}/5] sending #{pos[:label]} → expect: #{pos[:expect]}"
          ok = system('bundle', 'exec', 'exe/stackchan-ble-control',
                      '--name-prefix', 'StackChan-PicoRuby',
                      '--time', '800',
                      *pos[:args], 'servo')
          abort "[cal] frame send FAIL at #{pos[:label]}" unless ok
          sleep 1.5
          print '   Did StackChan move as expected? [y/N]: '
          ans = STDIN.gets.to_s.strip.downcase
          abort "[cal] FAIL at #{pos[:label]} (operator marked N)" unless ans == 'y'
        end

        system('bundle', 'exec', 'exe/stackchan-ble-control',
               '--name-prefix', 'StackChan-PicoRuby',
               'torque', 'off')
      end
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
    # into any child `bundle exec`, which makes pc/stackchan-ble-client's
    # `require "stackchan_ble_client"` fail with LoadError because resolution
    # uses the outer Gemfile instead of the inner one. Drop the outer env so
    # the child `bundle exec` reads its own Gemfile.
    Bundler.with_unbundled_env do
      Dir.chdir(File.expand_path('pc/stackchan-ble-client', __dir__)) do
        ok = system('bundle', 'exec', 'exe/stackchan-ble-control',
                    '--name-prefix', 'StackChan-PicoRuby',
                    '--side', side,
                    'combo',
                    '--face', face,
                    '--led',  "#{color} #{mode}")
        unless ok
          # Propagate the CLI's exit code so the rake call surfaces structured failure.
          exit $?.exitstatus
        end
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
      Dir.chdir(__dir__) do  # project root, where test/face_golden_test.rb lives
        ok = system('bundle', 'exec', 'rake', 'test',
                    "TESTOPTS=--name=FaceGoldenTest#test_#{face}_matches_golden")
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
    sh "cd pc/stackchan-ble-client && bundle exec exe/stackchan-ble-control calibrate --align-only --name-prefix StackChan"
  end

end
