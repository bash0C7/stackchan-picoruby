require "bundler/setup" if File.exist?(File.expand_path("Gemfile", __dir__))
require "digest"
require "json"
require "open3"
require "rbconfig"
require "tempfile"
require "yaml"
require_relative "lib/deploy/picomodem"
require_relative "lib/qemu_gate"

# Build trees fetched by `rake vendor:setup` (gitignored). ENV-overridable so a
# fork or branch swap needs no edit here.
R2P2_ESP32_REPO = ENV["R2P2_ESP32_REPO"] || "https://github.com/bash0C7/R2P2-ESP32.git"
# c-primitives-verified, not stackchan-integration: the latter's picoruby submodule
# is on the lineage rebased onto upstream master, which overflows the picoruby task
# stack during its own startup and boot-loops. See HANDOFF.
R2P2_ESP32_REF  = ENV["R2P2_ESP32_REF"]  || "claude/stackchan-aot-multicore-drb"
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
      sh "git clone --recursive --branch #{R2P2_ESP32_REF} #{R2P2_ESP32_REPO} #{R2P2_ROOT}" unless Dir.exist?(R2P2_ROOT)
    end
  end

  namespace :r2p2_darwin do
    desc "Clone R2P2_DARWIN_REPO@R2P2_DARWIN_REF into vendor/R2P2-darwin and fetch its picoruby"
    task :setup do
      sh "git clone --branch #{R2P2_DARWIN_REF} #{R2P2_DARWIN_REPO} #{R2P2_DARWIN_ROOT}" unless Dir.exist?(R2P2_DARWIN_ROOT)
      # R2P2-darwin keeps picoruby as a plain clone under its own vendor/, not as a
      # submodule, so cloning R2P2-darwin alone leaves pc:vm_build with nothing to
      # build. Its `rake setup` is what fetches it, and it is idempotent.
      sh "rake", "-C", R2P2_DARWIN_ROOT, "setup"
    end
  end
end

# The host picotest VM is R2P2-ESP32's own picoruby submodule: the same build
# the device runs, so host-VM quirks match device behavior.
PICORUBY_ROOT = ENV["PICORUBY_ROOT"] || File.join(R2P2_ROOT, "components", "picoruby-esp32", "picoruby")
PICORUBY_VM   = File.join(PICORUBY_ROOT, "build", "host-picotest", "bin", "picoruby")

# Rigor is a standalone CLI, not a bundled gem: it wants prism >= 1.0 while this
# repo is pinned to the prism ~> 0.30 that picoruby vendors, so bundler cannot
# resolve both. It gets its own gemset under the gitignored vendor/ tree instead.
RIGOR_VERSION  = ENV["RIGOR_VERSION"] || "0.3.7"
RIGOR_ROOT     = File.expand_path("vendor/rigor-tool", __dir__)
RIGOR_BIN      = File.join(RIGOR_ROOT, "bin", "rigor")
RIGOR_ENV      = { "GEM_HOME" => RIGOR_ROOT, "GEM_PATH" => RIGOR_ROOT }
RIGOR_SNAPSHOT = File.expand_path("rigor.baseline.json", __dir__)

# rigor runs on its own gemset, so it must not inherit this Rakefile's bundler
# environment: BUNDLE_GEMFILE and RUBYOPT=-rbundler/setup survive into the child
# and make it resolve the project's Gemfile against RIGOR_ROOT, which has none of
# those gems. Under `bundle exec rake` that aborts with Bundler::GemNotFound.
def unbundled(&blk)
  defined?(Bundler) ? Bundler.with_unbundled_env(&blk) : blk.call
end

# rigor 0.3.7 reports source diagnostics with an absolute path while config-level
# ones (`.rigor.yml`) stay relative, so the two directions key off whether the
# repo-relative name is a real file.
def rigor_relativize(path) = path.delete_prefix("#{__dir__}/")
def rigor_absolutize(path)
  absolute = File.join(__dir__, path)
  File.file?(absolute) ? absolute : path
end

namespace :rigor do
  desc "Install rigortype RIGOR_VERSION into vendor/rigor-tool (skip if present)"
  task :setup do
    next if File.exist?(RIGOR_BIN)
    unbundled { sh RIGOR_ENV, "gem", "install", "rigortype", "-v", RIGOR_VERSION, "--no-document" }
  end

  # `rigor diff` prints only the diff, so the config warnings `rigor check` emits
  # — including a signature_paths entry that resolves to nothing — never reach
  # the gate. Without them a checkout that skipped `rake vendor:setup` analyses
  # every picoruby type as Dynamic and still reports 0 new.
  task :assert_signatures do
    config = YAML.load_file(File.expand_path(".rigor.dist.yml", __dir__))
    missing = (config["signature_paths"] || []).reject { |p| Dir.exist?(File.expand_path(p, __dir__)) }
    next if missing.empty?
    abort <<~MSG
      rigor: #{missing.size} signature_paths entr#{missing.size == 1 ? "y" : "ies"} resolve to nothing:
      #{missing.map { |p| "  #{p}" }.join("\n")}
      Those types would silently read Dynamic and the diff would still pass.
      Run `rake vendor:setup` to fetch the picoruby tree.
    MSG
  end

  desc "Fail on any diagnostic that is not already in rigor.baseline.json"
  task check: [:setup, :assert_signatures] do
    # The committed snapshot holds repo-relative paths so it survives a different
    # checkout; `rigor diff` matches on the raw path string against a live run's
    # absolute ones, so it is fed an absolutized copy.
    absolute = JSON.parse(File.read(RIGOR_SNAPSHOT))
    absolute["diagnostics"].each { |d| d["path"] = rigor_absolutize(d["path"]) }
    Tempfile.create(["rigor-baseline", ".json"]) do |f|
      f.write(JSON.generate(absolute))
      f.flush
      unbundled { sh RIGOR_ENV, RIGOR_BIN, "diff", f.path }
    end
  end

  desc "Print every current diagnostic, snapshot or not"
  task all: :setup do
    unbundled { sh RIGOR_ENV, RIGOR_BIN, "check" }
  end

  desc "Rewrite rigor.baseline.json from the current diagnostics"
  task snapshot: :setup do
    json = unbundled { IO.popen(RIGOR_ENV, [RIGOR_BIN, "check", "--format=json"], &:read) }
    abort "rigor check produced no JSON" if json.nil? || json.strip.empty?
    report = JSON.parse(json)
    report["diagnostics"].each { |d| d["path"] = rigor_relativize(d["path"]) }
    File.write(RIGOR_SNAPSHOT, JSON.pretty_generate(report) + "\n")
    puts "wrote #{RIGOR_SNAPSHOT} (#{report["diagnostics"].size} diagnostics)"
  end
end

desc "Run all PicoRuby-native suites (alias of picotest:run), gated on rigor"
task :test => ["rigor:check", "picotest:run"]

namespace :test do
  desc "Run CRuby-only host tests (test-host/*_test.rb)"
  task :host do
    Dir[File.expand_path("test-host/*_test.rb", __dir__)].sort.each do |file|
      sh "bundle exec ruby -Ilib -Itest-host -Itools #{file}"
    end
  end
end

# Load the application's Face classes + FakeDisplay into this CRuby process.
def load_face_context
  $LOAD_PATH.unshift(File.expand_path('lib', __dir__))
  $LOAD_PATH.unshift(File.expand_path('test', __dir__))
  load File.expand_path('test/picotest/stubs.rb', __dir__)
  require 'ruby_class_extract'
  RubyClassExtract.load_classes_from(File.expand_path('app/application.rb', __dir__), exclude_superclasses: %w[BLE])
  require 'fake_display'
  require 'face_golden_hash'
end

def write_face_golden(name, klass)
  out = File.expand_path("spec/golden/face_#{name}.dump", __dir__)
  File.write(out, FaceGoldenHash.compute_dump(klass))
  puts "[face:register_golden] wrote #{out}"
end

namespace :face do
  desc "Write spec/golden/face_<NAME>.dump. FACE=neutral|smile|joy|surprised|sad|angry|closed"
  task :register_golden do
    name = ENV.fetch('FACE') { abort 'FACE=<name> required' }
    load_face_context
    klass = FaceGoldenHash::FACE_CASES.fetch(name.to_sym) do
      abort "unknown FACE=#{name}; one of: #{FaceGoldenHash::FACE_CASES.keys.join(' / ')}"
    end
    write_face_golden(name, klass)
  end

  desc "Write goldens for all faces"
  task :register_all_goldens do
    load_face_context
    FaceGoldenHash::FACE_CASES.each { |name, klass| write_face_golden(name, klass) }
  end
end

namespace :picotest do
  desc "Force-build the host picoruby test VM (MRUBY_CONFIG=picoruby-test). Run after a picoruby update or a firmware build."
  task :build do
    abort "picoruby tree not found: #{PICORUBY_ROOT}\n  set PICORUBY_ROOT, or run `rake vendor:setup`." unless File.directory?(PICORUBY_ROOT)
    config = File.expand_path('build_config/picoruby-test.rb', __dir__)
    Dir.chdir(PICORUBY_ROOT) { sh "MRUBY_CONFIG=#{config} rake all" }
  end

  task :ensure_vm do
    Rake::Task["picotest:build"].invoke unless File.executable?(PICORUBY_VM)
  end

  desc "Run the PicoRuby-native suites (device / pc / shared) on the host VM. SUITE=<name>, FILTER=<file substring>"
  task :run => :ensure_vm do
    $LOAD_PATH.unshift File.expand_path("test", __dir__)
    require "picotest/harness"
    exit PicotestHarness.run(filter: ENV["FILTER"], suite: ENV["SUITE"])
  end
end

# esp-idf installs itself wherever it was unpacked and names its venv after the
# IDF and Python versions it was built with, so both differ per machine — the
# Espressif container puts them under /opt/esp. Find the venv rather than
# spelling one. Highest version wins, compared as numbers: a machine with both
# idf5.4_py3.9 and idf5.4_py3.14 has to get 3.14, and strings sort it the other
# way. Either path can also be named outright.
def newest_esp_python
  Dir[File.expand_path('~/.espressif/python_env/idf*_py*_env/bin/python'),
      '/opt/esp/python_env/idf*_py*_env/bin/python']
    .max_by { |p| File.basename(File.dirname(File.dirname(p))).scan(/\d+/).map(&:to_i) }
end

ESP_IDF_EXPORT = ENV['ESP_IDF_EXPORT'] || File.expand_path('~/esp/esp-idf/export.sh')
ESP_PYTHON = ENV['ESP_PYTHON'] || newest_esp_python ||
             File.expand_path('~/.espressif/python_env/idf5.4_py3.14_env/bin/python')

SDKCONFIG_DEFAULTS_CORES3 = 'sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3;sdkconfigs/bt_nimble'
PICORUBY_BUILD_DIR = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/build/esp32-picoruby"
R2P2_VM_BY_TASK = { 'picoruby' => 'mruby', 'femtoruby' => 'mrubyc' }.freeze
R2P2_VM_TASK = 'picoruby'
PICORB_VM = R2P2_VM_BY_TASK.fetch(R2P2_VM_TASK)
SERIAL_LOG_DEFAULT = '/tmp/stackchan-picoruby-debug/serial.log'
# Storage partition (littlefs, /home). Must match R2P2-ESP32's partitions.csv.
STORAGE_OFFSET = '0x410000'
STORAGE_SIZE   = '0x100000'

def espport
  ENV.fetch('ESPPORT') do
    candidates = Dir.glob('/dev/cu.usbmodem*').sort
    abort 'ESPPORT not set and no /dev/cu.usbmodem* device found. Plug the CoreS3 in or set ESPPORT=...' if candidates.empty?
    warn "multiple /dev/cu.usbmodem* devices, using #{candidates.first} (override with ESPPORT=...)" if candidates.size > 1
    candidates.first
  end
end

def in_r2p2(cmd)
  abort "vendor/R2P2-ESP32 not found — run `rake vendor:setup` first" unless Dir.exist?(R2P2_ROOT)
  sh %Q{bash -c '. #{ESP_IDF_EXPORT} && export #{aot_build_env} && cd #{R2P2_ROOT} && #{cmd}'}
end

def r2p2_build_cmd(*targets, port: nil)
  env = %Q{SDKCONFIG_DEFAULTS="#{SDKCONFIG_DEFAULTS_CORES3}"}
  env += " ESPPORT=#{port}" if port
  "#{env} rake #{targets.join(' ')}"
end

def src_from_env(task)
  src = ENV.fetch('SRC') { abort "SRC=path/to/app.rb required for #{task}" }
  path = File.expand_path(src, __dir__)
  abort "SRC not found: #{path}" unless File.exist?(path)
  path
end

# Pure-Ruby driver gems live under mrbgems/ but are not in the firmware build_config, so
# their mrblib is prepended to the application source before picorbc.
DEVICE_GEM_SOURCES = %w[stackchan-led si12t aw88298 drb-ble].flat_map { |g| Dir[File.expand_path("mrbgems/picoruby-#{g}/mrblib/*.rb", __dir__)].sort }

def bundle_app_source(src)
  out = File.expand_path("tmp/build/#{File.basename(src, '.rb')}.bundled.rb", __dir__)
  mkdir_p File.dirname(out)
  File.write(out, (DEVICE_GEM_SOURCES + [src]).map { |f| File.read(f) }.join("\n"))
  out
end

def compile_mrb(src, out)
  picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/mrbc"
  abort "mrbc not found at #{picorbc} — run `rake r2p2:setup` first" unless File.executable?(picorbc)
  mkdir_p File.dirname(out)
  rm_f out
  sh picorbc, '-o', out, src
  abort "mrbc produced no output at #{out}" unless File.exist?(out)
  puts "[mrbc] #{src} -> #{out} (#{File.size(out)} bytes)"
end

def upload_mrb_via_picomodem(src:, dst:, port:, bundle: false)
  mrb = File.expand_path("tmp/build/#{File.basename(src, File.extname(src))}.mrb", __dir__)
  compile_mrb(bundle ? bundle_app_source(src) : src, mrb)
  Deploy::Picomodem.upload(src: mrb, dst: dst, port: port)
end

# idf.py never re-applies SDKCONFIG_DEFAULTS to an existing sdkconfig, so a
# fragment newer than sdkconfig means sdkconfig has to be regenerated.
def ensure_sdkconfig_fresh
  sdkconfig = "#{R2P2_ROOT}/sdkconfig"
  return puts "[r2p2] sdkconfig missing — will be generated from defaults" unless File.exist?(sdkconfig)
  cfg_mtime = File.mtime(sdkconfig)
  stale = SDKCONFIG_DEFAULTS_CORES3.split(';').select do |rel|
    path = File.join(R2P2_ROOT, rel)
    File.exist?(path) && File.mtime(path) > cfg_mtime
  end
  return if stale.empty?
  puts "[r2p2] sdkconfig fragment(s) newer than sdkconfig: #{stale.inspect} — regenerating"
  rm sdkconfig
end

# USB CDC bytes go to whichever reader claims them first, so an open
# idf_monitor silently eats uploader ACKs and esptool handshakes.
def ensure_no_concurrent_monitor
  hits = `ps -axo pid=,command= 2>/dev/null`.lines.select { |l| l =~ %r{python[^\s]*\s.*idf_monitor\.py} }
  return if hits.empty?
  pids = hits.map { |l| l.strip.split(' ', 2).first }
  abort "[monitor guard] idf_monitor.py is running (pid=#{pids.join(',')}). " \
        "Ctrl+] to detach `rake r2p2:monitor`, then retry. If stale: kill #{pids.join(' ')}"
end

def stackchan_cli(*args)
  cli = File.expand_path('pc/stackchan-pico/bin/stackchan', __dir__)
  # Drop this Rakefile's Bundler env so children read their own Gemfile.
  Bundler.with_unbundled_env { system(cli, *args) }
end

def stackchan_cli!(label, *args)
  stackchan_cli(*args) or abort "[#{label}] `stackchan #{args.join(' ')}` FAIL"
end

# Upload application.rb as the autostart payload, reset, and wait for
# advertising (5 s escape hatch + cold-boot + 3 s BLE yield).
def deploy_application_and_wait(label)
  wait = ENV.fetch('AUTOSTART_WAIT', '12').to_i
  ENV['SRC'] = 'app/application.rb'
  Rake::Task['r2p2:upload_appmrb'].invoke
  Rake::Task['r2p2:reset'].invoke
  puts "[#{label}] waiting #{wait}s for autostart + BLE advertise"
  sleep wait
end

# AOT kernels (aot/) and picoruby-multicore go into every firmware build:
# aot:esp32 generates them, in_r2p2 hands their dirs to R2P2-ESP32.
AOT_ESP32_DIR     = File.expand_path("build/aot/esp32", __dir__)
AOT_MULTICORE_DIR = File.expand_path("build/aot/picoruby-multicore", __dir__)

def aot_build_env
  gems = [File.join(AOT_ESP32_DIR, "gems", "picoruby-stackchan_aot"), File.join(AOT_ESP32_DIR, "picoruby-kernel_registry")]
  %Q{STACKCHAN_AOT_GEMS="#{gems.join(':')}" STACKCHAN_MULTICORE_DIR="#{AOT_MULTICORE_DIR}"}
end

namespace :aot do
  desc "Fetch suppify / spinel / picoruby-multicore at their pins and build spinel (tools/aot/setup.sh)"
  task :setup do
    sh File.expand_path("tools/aot/setup.sh", __dir__)
  end

  desc "Generate the AOT kernel gem + multicore_kernels registry for the firmware (build/aot/esp32)"
  task :esp32 do
    Rake::Task["aot:setup"].invoke
    sh "ruby", File.expand_path("tools/aot/kernels_build.rb", __dir__), "esp32"
  end
end

QEMU_ROOT = File.expand_path("build/qemu", __dir__)
QEMU_RUN_DIR = File.join(QEMU_ROOT, "run")
QEMU_BUILD_DIR = "#{R2P2_ROOT}/build-qemu"
QEMU_CONSOLE_FRAGMENT = File.expand_path("build_config/qemu_console.sdkconfig", __dir__)
QEMU_SDKCONFIG_DEFAULTS = QemuGate.sdkconfig_defaults(SDKCONFIG_DEFAULTS_CORES3, QEMU_CONSOLE_FRAGMENT)
QEMU_MISSING_LIB_PACKAGE_CMD = {
  'linux'  => 'sudo apt-get install libsdl2-2.0-0 libslirp0',
  'darwin' => 'brew install libgcrypt glib pixman sdl2 libslirp',
}.freeze

def qemu_platform
  QemuGate.platform(host_os: RbConfig::CONFIG['host_os'], host_cpu: RbConfig::CONFIG['host_cpu'])
end

def qemu_pin
  QemuGate::PINS.fetch(qemu_platform)
end

def qemu_version_dir
  File.join(QEMU_ROOT, QemuGate::QEMU_VERSION)
end

def qemu_binary_path
  File.join(qemu_version_dir, 'qemu', 'bin', 'qemu-system-xtensa')
end

def qemu_tarball_path
  File.join(QEMU_ROOT, File.basename(qemu_pin.fetch(:url)))
end

def qemu_missing_lib_package_cmd
  os = qemu_platform.split('-').last
  QEMU_MISSING_LIB_PACKAGE_CMD.fetch(os, '(no package command known for this platform)')
end

namespace :qemu do
  desc 'Download + verify + extract the pinned QEMU build for this host into build/qemu/'
  task :setup do
    mkdir_p QEMU_ROOT
    pin = qemu_pin
    tarball = qemu_tarball_path

    if File.exist?(tarball)
      actual = Digest::SHA256.file(tarball).hexdigest
      abort "[qemu:setup] #{tarball} exists but sha256 #{actual} does not match pinned #{pin.fetch(:sha256)}" unless actual == pin.fetch(:sha256)
      puts "[qemu:setup] #{tarball} present, sha256 matches — skip download"
    else
      sh 'curl', '-fsSL', '-o', tarball, pin.fetch(:url)
      actual = Digest::SHA256.file(tarball).hexdigest
      abort "[qemu:setup] downloaded #{tarball} sha256 #{actual} does not match pinned #{pin.fetch(:sha256)}" unless actual == pin.fetch(:sha256)
    end

    unless File.executable?(qemu_binary_path)
      mkdir_p qemu_version_dir
      sh 'tar', '-xJf', tarball, '-C', qemu_version_dir
    end

    out, err, status = Open3.capture3(qemu_binary_path, '--version')
    if !status.success?
      lib = err[/error while loading shared libraries: (\S+)/, 1] || err[/Library not loaded: (\S+)/, 1]
      abort "[qemu:setup] missing shared library #{lib} — #{qemu_missing_lib_package_cmd}" if lib
      abort "[qemu:setup] #{qemu_binary_path} --version failed:\n#{err}"
    end
    abort "[qemu:setup] unexpected --version output (want #{QemuGate::QEMU_VERSION}):\n#{out}" unless out.include?(QemuGate::QEMU_VERSION)
    puts "[qemu:setup] #{out.lines.first.strip}"
  end
end

def qemu_littlefs_python
  Dir.glob(File.join(QEMU_BUILD_DIR, '**', 'littlefs-python')).find { |p| File.executable?(p) } or
    abort "[r2p2:qemu_check] littlefs-python not found under #{QEMU_BUILD_DIR} — did the qemu build run?"
end

def qemu_build_storage_image(probe_source, out_bin)
  storage_dir = File.join(QEMU_RUN_DIR, 'storage')
  rm_rf storage_dir
  mkdir_p File.join(storage_dir, 'home')
  probe_rb = File.join(QEMU_RUN_DIR, 'probe.rb')
  File.write(probe_rb, probe_source)
  compile_mrb(probe_rb, File.join(storage_dir, 'home', 'app.mrb'))
  rm_f out_bin
  sh qemu_littlefs_python, 'create', "--fs-size=#{Integer(STORAGE_SIZE, 16)}", '--name-max=64', '--block-size=4096', storage_dir, out_bin
end

def qemu_merged_flash_image(out_bin)
  rm_f out_bin
  sh %Q{bash -c '. #{ESP_IDF_EXPORT} && cd #{QEMU_BUILD_DIR} && esptool.py --chip esp32s3 merge_bin -o #{out_bin} --fill-flash-size 16MB @flash_args'}
end

def qemu_overwrite_storage(flash_bin, storage_bin)
  offset = Integer(STORAGE_OFFSET, 16)
  block = 4096
  abort "[r2p2:qemu_check] STORAGE_OFFSET #{STORAGE_OFFSET} is not #{block}-aligned" unless (offset % block).zero?
  image = File.binread(storage_bin)
  abort "[r2p2:qemu_check] storage image is #{image.bytesize} bytes, partition is #{STORAGE_SIZE}" unless image.bytesize == Integer(STORAGE_SIZE, 16)
  File.open(flash_bin, 'r+b') { |io| io.seek(offset); io.write(image) }
end

def qemu_write_efuse_image(path)
  File.binwrite(path, QemuGate.efuse_image)
end

def qemu_run_and_poll(flash:, efuse:, log:, timeout: 120)
  argv = QemuGate.argv(qemu: qemu_binary_path, flash: flash, efuse: efuse, log: log)
  stderr_log = "#{log}.stderr"
  pid = Process.spawn(*argv, out: File::NULL, err: stderr_log)
  deadline = Time.now + timeout
  loop do
    verdict = QemuGate.verdict(File.exist?(log) ? File.binread(log) : '')
    return verdict if verdict.decided
    _, status = Process.wait2(pid, Process::WNOHANG)
    if status
      pid = nil
      return QemuGate::Verdict.new(false, "qemu exited (#{status}) before a verdict: #{File.read(stderr_log).strip}", true)
    end
    return QemuGate::Verdict.new(false, "#{verdict.message} within #{timeout} s", true) if Time.now >= deadline
    sleep 1
  end
ensure
  qemu_stop(pid) if pid
end

def qemu_stop(pid)
  Process.kill('TERM', pid)
  20.times do
    return if Process.wait(pid, Process::WNOHANG)
    sleep 0.25
  end
  Process.kill('KILL', pid)
  Process.wait(pid)
rescue Errno::ESRCH, Errno::ECHILD
end

namespace :r2p2 do
  desc 'deep clean + mruby rebuild + idf.py set-target esp32s3 (with CoreS3 sdkconfig)'
  task :setup => 'aot:esp32' do
    in_r2p2 "rm -f sdkconfig && #{r2p2_build_cmd('setup_esp32s3')}"
  end

  # rake re-archives libmruby.a from the object list, so a stale .o whose
  # source moved or changed survives an incremental build. Always start clean.
  def clean_picoruby_build!
    rm_rf PICORUBY_BUILD_DIR if Dir.exist?(PICORUBY_BUILD_DIR)
  end

  def qemu_gate_then_clean!(app: 'app/application.rb')
    ENV['QEMU_PROBE_APP'] = app
    Rake::Task['r2p2:qemu_check'].invoke
    clean_picoruby_build!
  end

  def build_then_flash!(port)
    in_r2p2 r2p2_build_cmd("#{R2P2_VM_TASK}:build")
    header = "#{R2P2_ROOT}/build/config/sdkconfig.h"
    unless File.exist?(header) && QemuGate.flash_console_ok?(File.read(header))
      abort "[r2p2] #{header} lacks `#{QemuGate::FLASH_CONSOLE_DEFINE}` — refusing to flash a build without the USB console"
    end
    in_r2p2 "ESPPORT=#{port} rake flash"
  end

  desc 'rm picoruby build dir so the next build recompiles every gem object'
  task :clean_picoruby_build do
    clean_picoruby_build!
  end

  desc "build with CoreS3 sdkconfig (Quad PSRAM + 16MB flash)"
  task :build => [:clean_picoruby_build, 'aot:esp32'] do
    ensure_sdkconfig_fresh
    in_r2p2 r2p2_build_cmd("#{R2P2_VM_TASK}:build")
  end

  desc "flash to CoreS3 via USB CDC (override with ESPPORT=...)"
  task :flash do
    qemu_gate_then_clean!
    ensure_no_concurrent_monitor
    ensure_sdkconfig_fresh
    build_then_flash!(espport)
  end

  desc "boot this tree under QEMU and require the probe marker (spec steps 1-5); FAILs abort"
  task :qemu_check => ['qemu:setup', 'aot:esp32'] do
    clean_picoruby_build!
    rm_rf QEMU_BUILD_DIR if Dir.exist?(QEMU_BUILD_DIR)
    project_sdkconfig = "#{R2P2_ROOT}/sdkconfig"
    before = File.exist?(project_sdkconfig) ? Digest::SHA256.file(project_sdkconfig).hexdigest : nil
    in_r2p2 %Q{SDKCONFIG_DEFAULTS="#{QEMU_SDKCONFIG_DEFAULTS}" idf.py -B build-qemu -DSDKCONFIG=#{QEMU_BUILD_DIR}/sdkconfig set-target esp32s3}
    in_r2p2 %Q{SDKCONFIG_DEFAULTS="#{QEMU_SDKCONFIG_DEFAULTS}" idf.py -B build-qemu -DSDKCONFIG=#{QEMU_BUILD_DIR}/sdkconfig -DPICORB_VM=#{PICORB_VM} build}
    after = File.exist?(project_sdkconfig) ? Digest::SHA256.file(project_sdkconfig).hexdigest : nil
    abort "[r2p2:qemu_check] the QEMU build changed #{project_sdkconfig}" unless before == after
    abort "[r2p2:qemu_check] #{QEMU_BUILD_DIR}/sdkconfig missing" unless File.exist?("#{QEMU_BUILD_DIR}/sdkconfig")

    mkdir_p QEMU_RUN_DIR
    probe_app = File.expand_path(ENV.fetch('QEMU_PROBE_APP', 'app/application.rb'), __dir__)
    probe_source = QemuGate.probe_source(application: probe_app, gem_sources: DEVICE_GEM_SOURCES)
    storage_bin = File.join(QEMU_RUN_DIR, 'storage.bin')
    qemu_build_storage_image(probe_source, storage_bin)

    flash_bin = File.join(QEMU_RUN_DIR, 'flash.bin')
    qemu_merged_flash_image(flash_bin)
    qemu_overwrite_storage(flash_bin, storage_bin)

    efuse_bin = File.join(QEMU_RUN_DIR, 'efuse.bin')
    qemu_write_efuse_image(efuse_bin)

    mkdir_p '/tmp/stackchan-picoruby-debug'
    log = "/tmp/stackchan-picoruby-debug/qemu-#{Time.now.strftime('%Y%m%d-%H%M%S')}.log"
    verdict = qemu_run_and_poll(flash: flash_bin, efuse: efuse_bin, log: log)

    puts "[r2p2:qemu_check] #{verdict.pass ? 'PASS' : 'FAIL'} — #{verdict.message} — log: #{log}"
    abort "[r2p2:qemu_check] FAIL" unless verdict.pass
  end

  desc 'build + flash in one shot (QEMU gate first; flashes only on a PASS)'
  task :build_flash do
    qemu_gate_then_clean!
    ensure_no_concurrent_monitor
    ensure_sdkconfig_fresh
    build_then_flash!(espport)
  end

  desc 'idf.py monitor (human use only — needs a TTY)'
  task :monitor do
    ensure_no_concurrent_monitor
    in_r2p2 "ESPPORT=#{espport} rake monitor"
  end

  # USB-Serial/JTAG drops the CDC connection for ~0.5-2 s around every reset,
  # so a plain `cat` goes silent forever. Retry open() until DURATION expires.
  desc 'capture ESPPORT into SERIAL_LOG, reconnecting across reset blips (DURATION=seconds, default 30)'
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
      with open(#{log.inspect}, 'wb') as f:
          while time.time() < deadline:
              try:
                  s = serial.Serial(port, 115200, timeout=0.2)
              except Exception:
                  time.sleep(0.05)
                  continue
              try:
                  while time.time() < deadline:
                      data = s.read(4096)
                      if data:
                          f.write(data)
                          f.flush()
              except Exception:
                  pass
              finally:
                  try:
                      s.close()
                  except Exception:
                      pass
      print('[r2p2:capture_resilient] done')
    PY
  end

  desc 'reset, then capture_resilient in the same process (SERIAL_LOG=path DURATION=seconds)'
  task :reset_and_capture do
    Rake::Task['r2p2:reset'].invoke
    Rake::Task['r2p2:capture_resilient'].invoke
  end

  desc 'pulse RTS to reset CoreS3'
  task :reset do
    ensure_no_concurrent_monitor
    sh ESP_PYTHON, '-c', <<~PY
      import serial, time
      s = serial.Serial('#{espport}', exclusive=False)
      s.dtr = False
      s.rts = True
      time.sleep(0.15)
      s.rts = False
      s.close()
      print('reset sent')
    PY
  end

  desc "erase the storage partition (#{STORAGE_OFFSET}, 1MB) — removes /home/app.mrb without a full flash"
  task :wipe_storage do
    ensure_no_concurrent_monitor
    port = espport
    Dir.chdir(R2P2_ROOT) do
      sh "bash -c '. #{ESP_IDF_EXPORT} && #{ESP_PYTHON} -m esptool -p #{port} erase_region #{STORAGE_OFFSET} #{STORAGE_SIZE}'"
    end
  end

  desc 'host-compile SRC=path/to/foo.rb and upload to DST=/home/path/foo.mrb'
  task :upload_mrb do
    ensure_no_concurrent_monitor
    dst = ENV.fetch('DST') { abort 'DST=/home/...mrb required for r2p2:upload_mrb' }
    upload_mrb_via_picomodem(src: src_from_env('r2p2:upload_mrb'), dst: dst, port: espport)
  end

  # /home/app.mrb autostarts and this application never returns, so
  # main_task.rb never reaches `$shell.start` and picomodem finds no shell to
  # talk to. main_task.rb offers no escape hatch either -- it loads the payload
  # unconditionally -- so the payload has to go before the upload rather than
  # after a guaranteed 25 s wait for a banner that cannot come. Rake runs a task
  # once per process, so full_rebuild, which already wipes first, does not wipe
  # twice.
  desc 'host-compile SRC=path/to/app.rb and upload as autostart payload /home/app.mrb'
  task :upload_appmrb do
    ensure_no_concurrent_monitor
    Rake::Task["r2p2:wipe_storage"].invoke
    upload_mrb_via_picomodem(src: src_from_env('r2p2:upload_appmrb'), dst: '/home/app.mrb', port: espport, bundle: true)
  end

  # R2P2-ESP32 rebuilds the littlefs image from storage/home/ on every build
  # and `idf.py flash` writes it with the firmware, so app.mrb placed there
  # lands at /home/app.mrb with no picomodem upload. esptool hard-resets on
  # its own; capture boot separately.
  desc 'host-compile SRC=app.rb → bake into littlefs /home/app.mrb → build+flash firmware+storage in one pass'
  task :build_flash_appmrb do
    src = src_from_env('r2p2:build_flash_appmrb')
    qemu_gate_then_clean!(app: src)
    ensure_no_concurrent_monitor
    ensure_sdkconfig_fresh
    compile_mrb(bundle_app_source(src), "#{R2P2_ROOT}/storage/home/app.mrb")
    build_then_flash!(espport)
    puts "[build_flash_appmrb] PASS — firmware + #{File.basename(src)} flashed"
  end

  desc 'build_flash → wipe_storage → upload_appmrb → reset (SRC=app.rb, ~7 min)'
  task :full_rebuild do
    src = ENV.fetch('SRC') { abort 'SRC=path/to/app.rb required for r2p2:full_rebuild' }
    ensure_no_concurrent_monitor
    Rake::Task['r2p2:build_flash'].invoke
    sleep 3   # USB CDC re-enumeration after esptool
    Rake::Task['r2p2:wipe_storage'].invoke
    sleep 12  # /dev node returns after esptool's hard-reset; the uploader waits for the shell itself
    ENV['SRC'] = src
    Rake::Task['r2p2:upload_appmrb'].invoke
    Rake::Task['r2p2:reset'].invoke
    puts "[r2p2:full_rebuild] PASS — firmware rebuilt + #{src} deployed as /home/app.mrb + device reset"
  end

  desc 'BLE servo E2E smoke (YL=50 PU=0 T=500 AUTOSTART_WAIT=12; torque is enabled first)'
  task :ble_servo_smoke do
    yl = ENV['YL']
    yr = ENV['YR']
    yl = '50' if yl.nil? && yr.nil?
    pu = ENV.fetch('PU', '0')
    t  = ENV.fetch('T', '500')
    deploy_application_and_wait('servo_smoke')
    stackchan_cli!('servo_smoke', 'torque', 'on')
    sleep 1
    args = ['servo', '--time', t, '--pitch-up', pu]
    args += ['--yaw-left',  yl] if yl
    args += ['--yaw-right', yr] if yr
    stackchan_cli(*args) or exit $?.exitstatus
    puts "[servo_smoke] PASS — YL=#{yl} YR=#{yr} PU=#{pu} T=#{t} — visual motion check please"
  end

  desc 'BLE torque on/off E2E smoke (face Closed → Neutral → Closed)'
  task :ble_torque_smoke do
    deploy_application_and_wait('torque_smoke')
    %w[on off].each do |state|
      stackchan_cli!('torque_smoke', 'torque', state)
      sleep 2
    end
    puts "[torque_smoke] PASS — torque on/off cycle complete"
  end

  desc 'BLE control E2E smoke (COLOR=red MODE=blink FACE=joy SIDE=both AUTOSTART_WAIT=12)'
  task :ble_control_smoke do
    color = ENV.fetch('COLOR', 'red')
    mode  = ENV.fetch('MODE',  'solid')
    face  = ENV.fetch('FACE',  'neutral')
    side  = ENV.fetch('SIDE',  'both')
    deploy_application_and_wait('smoke')
    stackchan_cli('face', face) or exit $?.exitstatus
    stackchan_cli('led', side, color, mode) or exit $?.exitstatus
    puts "[smoke] PASS — face=#{face} LED=#{color} #{mode} (side=#{side}) — visual check please"
  end

  desc 'face verify: host golden assert + device BLE write + ACK (FACE=<registered face>)'
  task :face_verify do
    face = ENV.fetch('FACE') { abort 'FACE=<name> required for r2p2:face_verify' }
    abort "no golden for FACE=#{face}" unless File.exist?(File.expand_path("spec/golden/face_#{face}.dump", __dir__))

    Bundler.with_unbundled_env do
      Dir.chdir(__dir__) do
        system('bundle', 'exec', 'rake', 'test', 'FILTER=face_golden') or abort "[face_verify] host golden FAIL"
      end
    end
    puts "[face_verify] host golden PASS"

    ENV['FACE'] = face
    ENV['COLOR'] ||= 'white'
    ENV['MODE']  ||= 'solid'
    ENV['SIDE']  ||= 'both'
    Rake::Task['r2p2:ble_control_smoke'].invoke
    puts "[face_verify] PASS — face=#{face} host golden matched + device ACK received"
  end

  desc "smoke test `stackchan calibrate --align-only` (interactive, device connected)"
  task :ble_calibration_smoke do
    ensure_no_concurrent_monitor
    stackchan_cli!('calibration_smoke', 'calibrate', '--align-only')
  end
end

namespace :pc do
  desc "build vendor/R2P2-darwin's picoruby VM with the stackchan-pc config (input to pc:app_bundle)"
  task :vm_build do
    darwin = R2P2_DARWIN_ROOT
    src    = File.join(darwin, "vendor", "picoruby")
    abort "#{src} not found — run `bundle exec rake vendor:setup` first" unless Dir.exist?(src)
    sh({ "MRUBY_BUILD_DIR" => File.join(darwin, "build"),
         "MRUBY_CONFIG"    => File.join(darwin, "build_config", "r2p2-stackchan-pc.rb") },
       "rake", "-C", src)
  end

  # CoreBluetooth is granted through TCC to a signed bundle identity, and the
  # ad-hoc signature binds to the binary's exact bytes: re-run after every
  # pc:vm_build.
  desc "(re)build ~/Applications/StackchanPico.app around the built VM so CoreBluetooth passes macOS TCC"
  task :app_bundle do
    vm = File.join(R2P2_DARWIN_ROOT, "build", "host", "bin", "picoruby")
    abort "#{vm} not found — run `bundle exec rake pc:vm_build` first" unless File.exist?(vm)
    app = File.expand_path("~/Applications/StackchanPico.app")
    macos_dir = File.join(app, "Contents", "MacOS")
    mkdir_p macos_dir
    cp vm, File.join(macos_dir, "picoruby")
    cp File.expand_path("pc/stackchan-pico/StackchanPico-Info.plist", __dir__), File.join(app, "Contents", "Info.plist")
    sh "codesign", "--force", "--deep", "-s", "-", app
    puts "[pc:app_bundle] #{app} ready"
  end

  def pc_lifecycle
    require_relative "lib/pc_lifecycle"
    PcLifecycle.new(
      { root:         __dir__,
        vm_app:       ENV["STACKCHAN_PICORUBY_APP"] || File.expand_path("~/Applications/StackchanPico.app"),
        ruby:         RbConfig.ruby,
        port:         (ENV["STACKCHAN_PORT"] || ENV["PORT"] || "8787").to_i,
        sidecar_port: (ENV["STACKCHAN_SIDECAR_PORT"] || ENV["SIDECAR_PORT"] || "8788").to_i,
        prefix:       ENV["PREFIX"] || "StackChan",
        ble_fake:     ENV["BLE_FAKE"] == "1",
        stub:         ENV["STUB"] == "1",
        logdir:       ENV["STACKCHAN_LOGDIR"] || "/tmp/stackchan-pico",
        ns:           ENV["NS"] },
      dir: File.expand_path("~/Library/LaunchAgents"),
    )
  end

  desc "(re)start the PC-side backends under launchd. STUB=1 / BLE_FAKE=1 / PREFIX= / STACKCHAN_PORT= / STACKCHAN_SIDECAR_PORT= / NS="
  task :up do
    status = pc_lifecycle.up
    puts "[pc:up] backends running — #{status.inspect}"
  rescue PcLifecycle::Error => e
    abort "[pc:up] #{e.message}"
  end

  desc "stop the PC-side backends and remove their launchd definitions"
  task :down do
    pc_lifecycle.down
    puts "[pc:down] backends stopped"
  end
end


# Device trial (trial/lock.yml): the robot running each arm, built from pinned
# commits, driven from the Mac, timed in one session. lib/device_trial.rb holds
# the order and the pass rules; lib/device_trial_ops.rb touches the machine.
namespace :trial do
  TRIAL_LOCK = File.expand_path("trial/lock.yml", __dir__)
  TRIAL_RESULTS = File.expand_path("trial/results", __dir__)

  def trial_session(stamp)
    require_relative "lib/device_trial"
    require_relative "lib/device_trial_ops"
    ops = DeviceTrialOps.new("/tmp/stackchan-picoruby-debug/trial/#{stamp}")
    DeviceTrial.new(lock: YAML.safe_load(File.read(TRIAL_LOCK)), root: __dir__, ops: ops, stamp: stamp)
  end

  def write_trial_report(t)
    mkdir_p TRIAL_RESULTS
    base = File.join(TRIAL_RESULTS, t.report["stamp"])
    File.write("#{base}.json", JSON.pretty_generate(t.report))
    File.write("#{base}.md", t.markdown)
    puts "[trial] verdict: #{t.report['verdict']} -> #{base}.md"
  end

  def latest_trial_json
    Dir[File.join(TRIAL_RESULTS, "*.json")].max or abort "[trial] no report under #{TRIAL_RESULTS}"
  end

  desc "Run trial/lock.yml on the robot: base then trial arm, each pinned, flashed, booted, driven, timed (~40 min). ESPPORT= optional"
  task :run do
    t = trial_session(Time.now.strftime("%Y%m%d-%H%M%S"))
    t.run
    write_trial_report(t)
  end

  desc "iOS / watchOS apps at the locked R2P2-darwin against the trial firmware (needs DEVELOPMENT_TEAM, a paired iPhone + Watch). Appends to the latest report"
  task :darwin do
    json = latest_trial_json
    t = trial_session(File.basename(json, ".json"))
    t.report.merge!(JSON.parse(File.read(json)))
    t.run_darwin
    write_trial_report(t)
  end

  desc "Ask the questions the latest report left unanswered (it ran without a TTY)"
  task :answer do
    json = latest_trial_json
    t = trial_session(File.basename(json, ".json"))
    t.report.merge!(JSON.parse(File.read(json)))
    t.answer
    write_trial_report(t)
  end
end
