require "digest"
require "fileutils"
require "open3"

module AotKernels
  LIB     = "stackchan_aot"
  ENTRIES = %w[StackchanAot.ulaw_decode StackchanAot.glyph16].freeze
  TABLE   = "multicore_kernels"

  class Error < StandardError; end

  module_function

  def xtensa_gcc
    return ENV["XTENSA_GCC"] if ENV["XTENSA_GCC"]
    tools = ENV["IDF_TOOLS_PATH"] || File.expand_path("~/.espressif")
    Dir[File.join(tools, "tools", "xtensa-esp-elf", "*", "xtensa-esp-elf", "bin", "xtensa-esp32s3-elf-gcc")].max ||
      raise(Error, "no xtensa-esp32s3-elf-gcc under #{tools}; set XTENSA_GCC")
  end

  def build(root, board)
    raise Error, "board must be esp32 or host, not #{board}" unless %w[esp32 host].include?(board)
    aot = File.join(root, "build", "aot")
    suppify_lib = File.join(aot, "suppify", "lib")
    spinel = File.join(aot, "spinel", "bin", "spinel")
    raise Error, "run rake aot:setup first" unless File.directory?(suppify_lib) && File.executable?(spinel)

    sources = Dir[File.join(root, "aot", "kernels", "*.rb")].sort
    raise Error, "no kernels in #{File.join(root, 'aot', 'kernels')}" if sources.empty?
    merged = sources.map { |f| File.read(f) }.join("\n")

    out = File.join(aot, board)
    gems_dir = File.join(out, "gems")
    gem = File.join(gems_dir, "picoruby-#{LIB}")
    stamp = File.join(gems_dir, "#{LIB}.stamp")
    FileUtils.mkdir_p(gems_dir)
    merged_rb = File.join(out, "#{LIB}.rb")
    File.write(merged_rb, merged)

    options = ["-o", LIB, "-d", gems_dir, "--table", TABLE]
    options += ["--cc", xtensa_gcc] if board == "esp32"
    inputs = [merged, *ENTRIES, *options, File.read(File.join(root, "aot", "suppify.pin")),
              File.read(File.join(aot, "suppify", "spinel.pin"))]
    want = Digest::SHA256.hexdigest(inputs.join("\0"))
    unless File.directory?(gem) && File.exist?(stamp) && File.read(stamp).strip == want
      FileUtils.rm_rf(gem)
      $LOAD_PATH.unshift(suppify_lib) unless $LOAD_PATH.include?(suppify_lib)
      require "suppify"
      Suppify::CLI.run([merged_rb, *ENTRIES, *options], spinel: Suppify::Spinel.new(bin: spinel))
      File.write(stamp, "#{want}\n")
    end
    gem
  end

  def gem_flags(gem)
    rake = File.read(File.join(gem, "mrbgem.rake"))
    scope = Struct.new(:dir, :newlib).new(gem, "#{gem}/src/newlib")
    incs = rake.scan(/spec\.cc\.include_paths(?:\.(?:concat|unshift)\((.*?)\)| << (.*))$/)
               .flat_map { |m| scope.instance_eval("[#{m.compact[0]}]").flatten }
    defs = rake.scan(/spec\.cc\.defines\.concat\((.*?)\)$/).flat_map { |m| scope.instance_eval(m[0]) }
    flags = rake.scan(/spec\.cc\.flags\.concat\((.*?)\)$/).flat_map { |m| scope.instance_eval(m[0]) }
    incs.map { |i| "-I#{i}" } + defs.map { |d| "-D#{d}" } + flags
  end

  def syntax_check(gem, cc: xtensa_gcc, out: $stdout)
    gem = File.expand_path(gem)
    unless File.directory?(File.join(gem, "src", "newlib"))
      raise Error, "not a suppify gem generated with --cc for a newlib board: #{gem}"
    end
    flags = ["-mlongcalls", "-fsyntax-only", "-Os", "-include", File.join(gem, "src", "newlib", "sp_newlib_config.h"),
             "-I#{File.join(gem, 'include')}", *gem_flags(gem)]
    files = Dir[File.join(gem, "src", "*.c")].sort.reject { |f| File.basename(f) == "binding.c" } +
            Dir[File.join(gem, "src", "instances", "*_glue.c")].sort
    failed = files.reject do |f|
      extra = f.start_with?(File.join(gem, "src", "instances")) ? ["-I#{File.join(gem, 'src')}"] : []
      text, status = Open3.capture2e(cc, *flags, *extra, f)
      unless status.success?
        out.puts "== #{File.basename(f)}"
        out.puts text.lines.grep(/error|fatal/).first(40).join
      end
      status.success?
    end
    failed.empty?
  end
end
