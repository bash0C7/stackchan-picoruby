require "bundler/setup" if File.exist?(File.expand_path("Gemfile", __dir__))
begin
  require_relative "lib/deploy/picomodem"
  require_relative "lib/deploy/shell_recovery"
rescue LoadError
  # Optional dependencies for deploy tasks
end
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.test_files = FileList['test/**/*_test.rb']
  t.warning = false
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
    port = espport
    in_r2p2 %Q{ESPPORT=#{port} rake flash}
  end

  desc 'build + flash in one shot (default workflow for code iteration)'
  task :build_flash => :clear_libmruby_cache do
    ensure_sdkconfig_fresh
    port = espport
    in_r2p2 %Q{SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}" ESPPORT=#{port} rake picoruby:build flash}
  end

  desc 'idf.py monitor (HUMAN USE ONLY — claude code Bash has no TTY)'
  task :monitor do
    port = espport
    in_r2p2 %Q{ESPPORT=#{port} rake monitor}
  end

  desc 'cat ESPPORT into SERIAL_LOG (claude code: launch via run_in_background, then rake r2p2:reset)'
  task :capture do
    port = espport
    log = ENV.fetch('SERIAL_LOG', SERIAL_LOG_DEFAULT)
    mkdir_p File.dirname(log)
    sh "cat #{port} > #{log}"
  end

  desc 'pulse RTS to reset CoreS3 (claude code has no TTY for `idf.py monitor`)'
  task :reset do
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
    port = espport
    Dir.chdir(R2P2_ROOT) do
      sh "bash -c '. #{ESP_IDF_EXPORT} && #{ESP_PYTHON} -m esptool -p #{port} erase_region 0x210000 0x100000'"
    end
  end

  desc 'upload a Ruby file via PicoModem (SRC=path DST=/home/foo.rb), defaults to examples/app.rb'
  task :upload do
    src  = ENV.fetch('SRC', 'mrbgems/picoruby-stackchan-protocol/examples/app.rb')
    dst  = ENV.fetch('DST', '/home/app.rb')
    port = espport
    abs_src = File.expand_path(src, __dir__)
    Deploy::Picomodem.upload(src: abs_src, dst: dst, port: port)
  end

  desc 'host-compile SRC=path/to/foo.rb to .mrb and upload as /home/app.mrb (autostart bytecode path; bypasses on-device compile)'
  task :upload_mrb do
    src = ENV.fetch('SRC') { abort 'SRC=path/to/file.rb is required for r2p2:upload_mrb' }
    src_path = File.expand_path(src, __dir__)
    abort "SRC not found: #{src_path}" unless File.exist?(src_path)

    picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/picorbc"
    unless File.executable?(picorbc)
      abort "picorbc not found at #{picorbc} — run `rake r2p2:setup` first (host picoruby build)"
    end

    build_dir = File.expand_path('tmp/build', __dir__)
    mkdir_p build_dir
    base = File.basename(src_path, File.extname(src_path))
    mrb_path = File.join(build_dir, "#{base}.mrb")
    rm_f mrb_path
    sh picorbc, '-o', mrb_path, src_path
    abort "picorbc produced no output at #{mrb_path}" unless File.exist?(mrb_path)
    puts "[upload_mrb] compiled #{src} -> #{mrb_path} (#{File.size(mrb_path)} bytes)"

    port = espport
    Deploy::Picomodem.upload(src: mrb_path, dst: '/home/app.mrb', port: port)
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
    ENV['SRC'] = 'mrbgems/picoruby-stackchan-protocol/examples/application.rb'
    Rake::Task['r2p2:upload_mrb'].invoke
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
      Dir.chdir(File.expand_path('mrbgems/picoruby-stackchan-protocol', __dir__)) do
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

end
