module FoundationModel
  class GenerationError < RuntimeError; end
  class TimeoutError < GenerationError; end
end

class FakeSession
  attr_reader :calls

  def initialize(reply: "やあ", error: nil)
    @reply = reply
    @error = error
    @calls = []
  end

  def respond(prompt, timeout_ms: nil)
    @calls << [prompt, timeout_ms]
    raise @error if @error
    @reply
  end
end

class FakeSay
  attr_reader :calls

  def initialize(pcm: "", error: nil)
    @pcm = pcm
    @error = error
    @calls = []
  end

  def pcm(text, rate)
    @calls << [text, rate]
    raise @error if @error
    @pcm
  end
end
