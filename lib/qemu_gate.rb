require 'prism'
require_relative 'ruby_class_extract'

module QemuGate
  QEMU_VERSION = 'esp_develop_9.2.2_20250817'
  QEMU_RELEASE_TAG = 'esp-develop-9.2.2-20250817'

  PINS = {
    'x86_64-linux' => {
      url: "https://github.com/espressif/qemu/releases/download/#{QEMU_RELEASE_TAG}/" \
           "qemu-xtensa-softmmu-#{QEMU_VERSION}-x86_64-linux-gnu.tar.xz",
      sha256: '588bfaccd0f929650655d10a580f020c6ba9c131712d8fa519280081b8d126eb',
    },
    'aarch64-linux' => {
      url: "https://github.com/espressif/qemu/releases/download/#{QEMU_RELEASE_TAG}/" \
           "qemu-xtensa-softmmu-#{QEMU_VERSION}-aarch64-linux-gnu.tar.xz",
      sha256: '317f6e0fd1dba0886d8110709823d909593ef29438822a14f81ebe19d72ce7cd',
    },
    'x86_64-darwin' => {
      url: "https://github.com/espressif/qemu/releases/download/#{QEMU_RELEASE_TAG}/" \
           "qemu-xtensa-softmmu-#{QEMU_VERSION}-x86_64-apple-darwin.tar.xz",
      sha256: '00b9dbc2124cf7633cb86f264fbc524226ad4001bce68bbdba43c9bdc4eb026e',
    },
    'arm64-darwin' => {
      url: "https://github.com/espressif/qemu/releases/download/#{QEMU_RELEASE_TAG}/" \
           "qemu-xtensa-softmmu-#{QEMU_VERSION}-aarch64-apple-darwin.tar.xz",
      sha256: 'aa92e337461d482f5d9f31cd8efc0bd67b3de8fcfcfb567289cb43a59c184651',
    },
  }.freeze

  FAIL_PATTERNS = [/Guru Meditation/, /abort\(\)/, /Rebooting\.\.\./, /assert failed/].freeze
  ERROR_CLASS_PATTERN = /\((NameError|LoadError|NoMethodError|ArgumentError|TypeError|RuntimeError|Exception)\)|^Error: |^Exception\(vm_id=/
  MARKER = 'QEMU_PROBE_OK'

  Verdict = Struct.new(:pass, :message)

  module_function

  def platform(host_os:, host_cpu:)
    os = case host_os
         when /linux/ then 'linux'
         when /darwin/ then 'darwin'
         end
    cpu = case host_cpu
          when /x86_64|amd64/ then 'x86_64'
          when /aarch64|arm64/ then 'aarch64'
          end
    key = { ['linux', 'x86_64'] => 'x86_64-linux',
            ['linux', 'aarch64'] => 'aarch64-linux',
            ['darwin', 'x86_64'] => 'x86_64-darwin',
            ['darwin', 'aarch64'] => 'arm64-darwin' }[[os, cpu]]
    raise "unsupported platform: host_os=#{host_os.inspect} host_cpu=#{host_cpu.inspect}" unless key
    key
  end

  def efuse_image
    bytes = Array.new(1024, 0)
    bytes[37] = 0x0c
    bytes[64] = 0x01
    bytes.pack('C*')
  end

  def argv(qemu:, flash:, efuse:, log:)
    [
      qemu,
      '-M', 'esp32s3',
      '-m', '8M',
      '-drive', "file=#{flash},if=mtd,format=raw",
      '-drive', "file=#{efuse},if=none,format=raw,id=efuse",
      '-global', 'driver=nvram.esp32s3.efuse,property=drive,value=efuse',
      '-global', 'driver=timer.esp32s3.timg,property=wdt_disable,value=true',
      '-display', 'none',
      '-serial', "file:#{log}",
      '-monitor', 'none',
    ]
  end

  def sdkconfig_defaults(cores3_list, fragment_path)
    cores3_list.split(';').map { |entry| entry == 'sdkconfigs/usb_console' ? fragment_path : entry }.join(';')
  end

  def top_level_requires(path)
    result = Prism.parse(File.read(path))
    raise "parse error: #{result.errors}" unless result.success?

    result.value.statements.body.each_with_object([]) do |node, out|
      next unless node.is_a?(Prism::CallNode)
      next unless node.name == :require && node.receiver.nil?

      args = node.arguments&.arguments
      next unless args && args.size == 1 && args.first.is_a?(Prism::StringNode)

      out << "require '#{args.first.unescaped}'"
    end
  end

  def probe_source(application:, gem_sources:)
    sections = []
    sections << top_level_requires(application).join("\n")
    gem_sources.each { |path| sections << File.read(path) }
    sections << RubyClassExtract.extract_source_from(application, exclude_superclasses: %w[BLE])
    sections << <<~RUBY
      raise "frame parser round trip failed" unless StackchanProtocol::FrameParser.new.feed("<F:1>\\n") == [{"F"=>"1"}]
    RUBY
    sections << 'puts "QEMU_PROBE_OK"'
    sections.join("\n\n")
  end

  def verdict(log)
    text = log.to_s
    FAIL_PATTERNS.each do |pattern|
      match = text[pattern]
      return Verdict.new(false, "boot log shows #{match.inspect}") if match
    end

    after_loading = false
    text.each_line do |line|
      after_loading ||= line.include?('Loading app.mrb')
      next unless after_loading

      return Verdict.new(false, "boot log shows #{line.strip.inspect}") if line.match?(ERROR_CLASS_PATTERN)
    end

    return Verdict.new(true, "marker #{MARKER} found") if text.include?(MARKER)

    Verdict.new(false, 'no marker')
  end
end
