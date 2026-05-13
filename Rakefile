R2P2_ROOT = File.expand_path('../../bash0C7/R2P2-ESP32', __dir__)
ESP_IDF_EXPORT = File.expand_path('~/esp/esp-idf/export.sh')
ESP_PYTHON = File.expand_path('~/.espressif/python_env/idf5.4_py3.14_env/bin/python')

SDKCONFIG_DEFAULTS_CORES3 = 'sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3'
ESPPORT_DEFAULT = '/dev/cu.usbmodem1101'
LONGRUN_DIR = File.expand_path('tmp/longrun', __dir__)
SERIAL_LOG_DEFAULT = "#{LONGRUN_DIR}/serial.log"

def in_r2p2(*args)
  cmd = args.join(' ')
  sh %Q{bash -c '. #{ESP_IDF_EXPORT} && cd #{R2P2_ROOT} && #{cmd}'}
end

namespace :r2p2 do
  desc 'deep clean + mruby rebuild + idf.py set-target esp32s3 (with CoreS3 sdkconfig)'
  task :setup do
    in_r2p2 %Q{rm -f sdkconfig && SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}" rake setup_esp32s3}
  end

  desc "build with CoreS3 sdkconfig (QUAD PSRAM + 16MB flash, VM=mruby)"
  task :build do
    in_r2p2 %Q{SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}" rake picoruby:build}
  end

  desc "flash to CoreS3 via USB CDC (override with ESPPORT=...)"
  task :flash do
    port = ENV.fetch('ESPPORT', ESPPORT_DEFAULT)
    in_r2p2 %Q{ESPPORT=#{port} rake flash}
  end

  desc 'build + flash in one shot (default workflow for code iteration)'
  task :build_flash do
    port = ENV.fetch('ESPPORT', ESPPORT_DEFAULT)
    in_r2p2 %Q{SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}" ESPPORT=#{port} rake picoruby:build flash}
  end

  desc 'idf.py monitor (HUMAN USE ONLY — claude code Bash has no TTY)'
  task :monitor do
    port = ENV.fetch('ESPPORT', ESPPORT_DEFAULT)
    in_r2p2 %Q{ESPPORT=#{port} rake monitor}
  end

  desc 'cat ESPPORT into SERIAL_LOG (claude code: launch via run_in_background, then rake r2p2:reset)'
  task :capture do
    port = ENV.fetch('ESPPORT', ESPPORT_DEFAULT)
    log = ENV.fetch('SERIAL_LOG', SERIAL_LOG_DEFAULT)
    mkdir_p File.dirname(log)
    sh "cat #{port} > #{log}"
  end

  desc 'pulse RTS to reset CoreS3 (claude code has no TTY for `idf.py monitor`)'
  task :reset do
    port = ENV.fetch('ESPPORT', ESPPORT_DEFAULT)
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
end
