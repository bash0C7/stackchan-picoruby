#!/usr/bin/env ruby
require "digest"
require "fileutils"

ROOT    = File.expand_path("../..", __dir__)
LIB     = "stackchan_aot"
KDIR    = File.join(ROOT, "aot", "kernels")
AOT     = File.join(ROOT, "build", "aot")
ENTRIES = %w[StackchanAot.ulaw_decode StackchanAot.glyph16].freeze
TABLE   = "multicore_kernels"

def die(msg)
  warn "kernels_build: #{msg}"
  exit 2
end

board = ARGV[0]
die "usage: tools/aot/kernels_build.rb <esp32|host>" unless %w[esp32 host].include?(board)
suppify = File.join(AOT, "suppify", "suppify.rb")
spinel  = File.join(AOT, "spinel", "bin", "spinel")
die "run tools/aot/setup.sh first" unless File.exist?(suppify) && File.executable?(spinel)

sources = Dir[File.join(KDIR, "*.rb")].sort
die "no kernels in #{KDIR}" if sources.empty?
merged = sources.map { |f| File.read(f) }.join("\n")

out = File.join(AOT, board)
gems_dir = File.join(out, "gems")
gem = File.join(gems_dir, "picoruby-#{LIB}")
stamp = File.join(gems_dir, "#{LIB}.stamp")
FileUtils.mkdir_p(gems_dir)
merged_rb = File.join(out, "#{LIB}.rb")
File.write(merged_rb, merged)

options = ["-o", LIB, "-d", gems_dir, "--table", TABLE]
options << "--newlib" if board == "esp32"
inputs = [merged, *ENTRIES, *options, File.read(File.join(ROOT, "aot", "suppify.pin")),
          File.read(File.join(AOT, "suppify", "spinel.pin"))]
want = Digest::SHA256.hexdigest(inputs.join("\0"))
unless File.directory?(gem) && File.exist?(stamp) && File.read(stamp).strip == want
  FileUtils.rm_rf(gem)
  env = { "SPINEL" => spinel }
  ok = system(env, "ruby", suppify, merged_rb, *ENTRIES, *options, out: $stderr, chdir: out)
  die "suppify failed" unless ok
  File.write(stamp, "#{want}\n")
end

warn "kernels_build: #{ENTRIES.join(' ')} [#{board}] -> #{gem}"
puts gem
