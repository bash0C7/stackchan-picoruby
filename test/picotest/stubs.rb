# On-device constants referenced at class-body load time by the extracted
# application classes. Loaded into BOTH the CRuby orchestrator (for test-class
# enumeration) and the target VM (first load_files entry).

# Deterministic clock: delay_ms advances uptime_us instantly and is recorded.
module Machine
  @offset_us = 0
  @delays = []
  def self.uptime_us = @offset_us
  def self.delays = @delays
  def self.delay_ms(ms)
    @delays << ms
    @offset_us += ms * 1_000
  end
end

# StackchanApp::Face's module body assigns EYE/MOUTH/BACKGROUND colors from
# ILI9342::Color::WHITE / BLACK at load time.
module ILI9342
  module Color
    WHITE = 0xFFFF
    BLACK = 0x0000
  end
end
