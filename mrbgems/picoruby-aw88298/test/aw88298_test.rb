class AW88298Test < Picotest::Test
  # ITU G.711 mu-law decode. Known vectors: 0xFF/0x7F -> 0, 0x00 -> -32124, 0x80 -> +32124.
  def test_ulaw_zero_codes
    assert_equal "\x00\x00", AW88298.ulaw_decode("\xFF")
    assert_equal "\x00\x00", AW88298.ulaw_decode("\x7F")
  end

  def test_ulaw_extremes
    assert_equal "\x84\x82", AW88298.ulaw_decode("\x00")  # -32124 -> 0x8284, LE 84 82
    assert_equal "\x7C\x7D", AW88298.ulaw_decode("\x80")  # +32124 -> 0x7D7C, LE 7C 7D
  end

  def test_ulaw_two_bytes_per_code
    # bytesize, not length: host PicoRuby VM mis-counts multibyte String#length
    assert_equal 6, AW88298.ulaw_decode("\x00\x80\xFF").bytesize
  end

  # All 256 codes, as the C decoder (ITU-T G.711) produced them.
  ULAW_ALL_PCM_HEX =
    "84828486848a848e84928496849a849e84a284a684aa84ae84b284b684ba84be" \
    "84c184c384c584c784c984cb84cd84cf84d184d384d584d784d984db84dd84df" \
    "04e104e204e304e404e504e604e704e804e904ea04eb04ec04ed04ee04ef04f0" \
    "c4f044f1c4f144f2c4f244f3c4f344f4c4f444f5c4f544f6c4f644f7c4f744f8" \
    "a4f8e4f824f964f9a4f9e4f924fa64faa4fae4fa24fb64fba4fbe4fb24fc64fc" \
    "94fcb4fcd4fcf4fc14fd34fd54fd74fd94fdb4fdd4fdf4fd14fe34fe54fe74fe" \
    "8cfe9cfeacfebcfeccfedcfeecfefcfe0cff1cff2cff3cff4cff5cff6cff7cff" \
    "88ff90ff98ffa0ffa8ffb0ffb8ffc0ffc8ffd0ffd8ffe0ffe8fff0fff8ff0000" \
    "7c7d7c797c757c717c6d7c697c657c617c5d7c597c557c517c4d7c497c457c41" \
    "7c3e7c3c7c3a7c387c367c347c327c307c2e7c2c7c2a7c287c267c247c227c20" \
    "fc1efc1dfc1cfc1bfc1afc19fc18fc17fc16fc15fc14fc13fc12fc11fc10fc0f" \
    "3c0fbc0e3c0ebc0d3c0dbc0c3c0cbc0b3c0bbc0a3c0abc093c09bc083c08bc07" \
    "5c071c07dc069c065c061c06dc059c055c051c05dc049c045c041c04dc039c03" \
    "6c034c032c030c03ec02cc02ac028c026c024c022c020c02ec01cc01ac018c01" \
    "74016401540144013401240114010401f400e400d400c400b400a40094008400" \
    "7800700068006000580050004800400038003000280020001800100008000000"

  # Binary Strings in a failure message break picotest's JSON report; compare hex.
  def hex(s)
    s.unpack("H*")[0]
  end

  def all_codes
    s = "\0" * 256
    i = 0
    while i < 256
      s.setbyte(i, i)
      i += 1
    end
    s
  end

  def test_ulaw_every_code_matches_the_c_decoder
    assert_equal ULAW_ALL_PCM_HEX, hex(AW88298.ulaw_decode(all_codes))
  end

  # AW88298 init writes (from M5Unified), 16-bit big-endian -> [reg, hi, lo] triples.
  def test_aw88298_init_writes_8khz
    seq = AW88298.aw88298_init_writes(8000)
    assert_equal [0x61, 0x06, 0x73], seq[0]
    assert_equal [0x04, 0x40, 0x40], seq[1]
    assert_equal [0x05, 0x00, 0x08], seq[2]
    assert_equal [0x06, 0x14, 0xC0], seq[3]   # 8 kHz -> reg0x06 = 0x14C0
    assert_equal [0x0C, 0x00, 0x64], seq[4]
  end

  def test_aw88298_reg06_16khz
    assert_equal 0x14C3, AW88298.aw88298_reg06(16000)
  end

  # Instance behaviour against host fakes (FakeI2C + FakeI2S via harness load_files).
  # Multicore is absent on the host VM unless a test defines FakeMulticore as Multicore.
  def test_init_amp_writes_registers_via_i2c
    i2c = FakeI2C.new
    spk = AW88298.new(i2c: i2c, i2s: I2S.new(sample_rate: 8000))
    spk.init_amp(8000)
    assert_equal 5, i2c.writes.length
    assert_equal [0x36, [0x61, 0x06, 0x73]], i2c.writes[0]
  end

  def test_play_ulaw_feeds_decoded_pcm_to_i2s
    spk = AW88298.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
    spk.play_ulaw("\x00\x80")   # 2 mu-law codes -> 4 bytes of int16 PCM
    assert_equal 4, spk.i2s.written.bytesize
  end

  # --- play_ulaw over picoruby-multicore (FakeMulticore stands in for it) ---

  def with_multicore(fake)
    Object.const_set(:Multicore, fake)
    yield
  ensure
    Object.send(:remove_const, :Multicore)
  end

  def long_clip(n)
    s = "\0" * n
    i = 0
    while i < n
      s.setbyte(i, (i * 37) % 256)
      i += 1
    end
    s
  end

  def test_play_ulaw_on_multicore_decodes_in_chunks_and_writes_in_order
    clip = long_clip(AW88298::MULTICORE_CHUNK * 2 + 10)
    spk = AW88298.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
    fake = FakeMulticore.reset
    with_multicore(fake) { spk.play_ulaw(clip) }
    assert_equal hex(AW88298.ulaw_decode(clip)), hex(spk.i2s.written)
    assert_equal [AW88298::MULTICORE_CHUNK, AW88298::MULTICORE_CHUNK, 10], fake.spawned_sizes
  end

  def test_next_chunk_is_spawned_before_the_previous_one_is_written
    clip = long_clip(AW88298::MULTICORE_CHUNK + 1)
    i2s = OrderI2S.new
    fake = FakeMulticore.reset(log: i2s.log)
    spk = AW88298.new(i2c: FakeI2C.new, i2s: i2s)
    with_multicore(fake) { spk.play_ulaw(clip) }
    assert_equal [[:spawn, AW88298::MULTICORE_CHUNK], [:spawn, 1],
                  [:write, AW88298::MULTICORE_CHUNK * 2], [:write, 2]], i2s.log
  end

  def test_a_failed_spawn_plays_the_rest_decoded_here
    clip = long_clip(AW88298::MULTICORE_CHUNK * 2)
    spk = AW88298.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
    with_multicore(FakeMulticore.reset(fail_on_spawn: 2)) { spk.play_ulaw(clip) }
    assert_equal hex(AW88298.ulaw_decode(clip)), hex(spk.i2s.written)
  end

  def test_core_busy_from_the_start_plays_everything_decoded_here
    clip = long_clip(100)
    spk = AW88298.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
    with_multicore(FakeMulticore.reset(fail_on_spawn: 1)) { spk.play_ulaw(clip) }
    assert_equal hex(AW88298.ulaw_decode(clip)), hex(spk.i2s.written)
  end
end

class OrderI2S
  attr_reader :log
  def initialize; @log = []; end
  def write(pcm); @log << [:write, pcm.bytesize]; pcm.bytesize; end
end

# picoruby-multicore's surface as play_ulaw uses it: Multicore.spawn -> Job
# (done? / value / discard), errors under Multicore::Error. Jobs finish on the
# second done?.
module FakeMulticore
  class Error < StandardError; end
  class CoreBusy < Error; end

  class Job
    def initialize(value); @value = value; @polls = 0; end
    def done?; @polls += 1; @polls >= 2; end
    def value; @value; end
    def discard; nil; end
  end

  def self.reset(log: nil, fail_on_spawn: nil)
    @log = log
    @fail_on_spawn = fail_on_spawn
    @spawned_sizes = []
    self
  end

  def self.spawned_sizes = @spawned_sizes

  def self.spawn(name, arg)
    raise CoreBusy, "busy" if @fail_on_spawn && @spawned_sizes.size + 1 == @fail_on_spawn
    raise "unexpected kernel #{name}" unless name == :ulaw_decode
    @spawned_sizes << arg.bytesize
    @log << [:spawn, arg.bytesize] if @log
    Job.new(AW88298.ulaw_decode(arg))
  end
end
