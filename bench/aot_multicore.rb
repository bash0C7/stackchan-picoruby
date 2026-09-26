# AW88298#play_ulaw with and without picoruby-multicore, on the VM that
# tools/aot_host_vm.sh builds. Checks the bytes first, then times the decode
# path into a sink that returns at once (so this is decode + hand-over cost,
# not the I2S wait the pipeline overlaps with on the device).
#
#   cat mrbgems/picoruby-aw88298/mrblib/aw88298.rb bench/aot_multicore.rb > build/aot_multicore.rb
#   build/host-aot/bin/picoruby build/aot_multicore.rb

class CaptureI2S
  attr_reader :out
  def initialize; @out = ""; end
  def write(pcm); @out << pcm; pcm.bytesize; end
end

class NullI2S
  def write(pcm); pcm.bytesize; end
end

def clip(n)
  s = "\0" * n
  i = 0
  while i < n
    s.setbyte(i, (i * 37) % 256)   # every code, 0x00 included
    i += 1
  end
  s
end

def time_us(reps)
  t0 = Time.now.to_f
  i = 0
  while i < reps
    yield
    i += 1
  end
  (Time.now.to_f - t0) * 1_000_000 / reps
end

require 'multicore'
MC = Multicore
all = clip(256)
raise "kernel mismatch" unless Multicore.run(:ulaw_decode, all) == AW88298.ulaw_decode(all)

[4096, 16000].each do |n|
  c = clip(n)
  cap = CaptureI2S.new
  AW88298.new(i2c: nil, i2s: cap).play_ulaw(c)
  raise "play_ulaw mismatch n=#{n}" unless cap.out == AW88298.ulaw_decode(c)

  spk = AW88298.new(i2c: nil, i2s: NullI2S.new)
  reps = n == 4096 ? 20 : 5
  mc = time_us(reps) { spk.play_ulaw(c) }
  Object.send(:remove_const, :Multicore)
  here = time_us(reps) { spk.play_ulaw(c) }
  Object.const_set(:Multicore, MC)
  puts "play_ulaw n=#{n} (#{n / 8} ms of audio)\tinterpreted #{(here * 10).round / 10.0} us\tmulticore #{(mc * 10).round / 10.0} us"
end
