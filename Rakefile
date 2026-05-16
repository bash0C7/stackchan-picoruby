require "bundler/setup" if File.exist?(File.expand_path("Gemfile", __dir__))
require_relative "lib/deploy/picomodem"

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

  desc 'force regenerate mrbgem bytecode (.rb -> .c) before next build. Use when only mrblib/*.rb changed; idf.py build alone keeps stale cached bytecode'
  task :rebuild_gems do
    if File.exist?(LIBMRUBY_FILE)
      rm LIBMRUBY_FILE
      puts "removed #{LIBMRUBY_FILE} — next build will re-run picoruby rake"
    else
      puts "libmruby.a already absent — next build will run picoruby rake anyway"
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
  task :build_flash do
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

  desc 'send `led <COLOR> <MODE>` via stackchan-control (defaults: COLOR=red MODE=solid)'
  task :send_led do
    color = ENV.fetch('COLOR', 'red')
    mode  = ENV.fetch('MODE', 'solid')
    port = espport
    Dir.chdir(File.expand_path('pc/stackchan-protocol', __dir__)) do
      sh 'bundle', 'exec', 'exe/stackchan-control', '--port', port, 'led', color, mode
    end
  end

  desc 'send `face <NAME>` via stackchan-control (default NAME=neutral)'
  task :send_face do
    name = ENV.fetch('NAME', 'neutral')
    port = espport
    Dir.chdir(File.expand_path('pc/stackchan-protocol', __dir__)) do
      sh 'bundle', 'exec', 'exe/stackchan-control', '--port', port, 'face', name
    end
  end

  desc 'one-shot HW verify: reset + capture serial + send_led + tail log (COLOR/MODE/WAIT env override)'
  task :verify_led do
    color = ENV.fetch('COLOR', 'red')
    mode  = ENV.fetch('MODE', 'solid')
    autostart_wait = ENV.fetch('AUTOSTART_WAIT', '12').to_i
    settle_wait    = ENV.fetch('SETTLE_WAIT', '4').to_i
    port = espport
    log = File.expand_path('tmp/longrun/verify-led-serial.log', __dir__)
    mkdir_p File.dirname(log)
    File.write(log, '')

    Rake::Task['r2p2:reset'].invoke
    sleep 1

    cat_pid = spawn("cat #{port} > #{log}")
    puts "[verify_led] serial capture pid=#{cat_pid} -> #{log}"

    puts "[verify_led] waiting #{autostart_wait}s for autostart..."
    sleep autostart_wait

    ENV['COLOR'] = color
    ENV['MODE']  = mode
    Rake::Task['r2p2:send_led'].invoke

    sleep settle_wait
    Process.kill('TERM', cat_pid) rescue nil
    Process.wait(cat_pid) rescue nil

    puts "===== serial log tail (last 80 lines of #{log}) ====="
    sh "tail -80 #{log}"
  end

  # Mac autonomous BLE verification loop. Composes upload_mrb (host picorbc +
  # picomodem) + reset (RTS pulse) + sleep (autostart + sleep_ms 2000 + BLE
  # init) + stackchan-ble-verify (Mac CoreBluetooth central scan/connect/
  # discover/read/write/subscribe). Single command for Claude Code to assert
  # the full device→Mac BLE path with exit 0 / non-zero.
  desc 'autonomous BLE verify loop: upload ble_smoke.rb (.mrb) + reset + Mac-side verify'
  task :ble_verify do
    ENV['SRC'] = 'mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb'
    Rake::Task['r2p2:upload_mrb'].invoke
    Rake::Task['r2p2:reset'].invoke
    autostart_wait = ENV.fetch('AUTOSTART_WAIT', '10').to_i
    puts "[ble_verify] waiting #{autostart_wait}s for autostart (sleep_ms 2000 + BLE init + advertise)..."
    sleep autostart_wait
    Dir.chdir(File.expand_path('pc/stackchan-protocol', __dir__)) do
      sh 'bundle', 'exec', 'exe/stackchan-ble-verify'
    end
  end
end
