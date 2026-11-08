class SidecarServiceTest < Picotest::Test
  def service(session: FakeSession.new, say: FakeSay.new)
    StackchanSidecar::Service.new(session: session, say: say)
  end

  def test_a_bare_prompt_goes_to_the_session_as_is_with_the_timeout
    session = FakeSession.new(reply: "こんにちは！")
    assert_equal "こんにちは！", service(session: session).respond("こんにちは")
    assert_equal [["こんにちは", 60_000]], session.calls
  end

  def test_the_context_becomes_a_situation_above_the_question
    session = FakeSession.new
    service(session: session).respond("元気？", { last_face: "joy", last_say: "やあ", last_heard: "おはよう", last_action: "say" })
    want = "今の状況:\n- 今の表情: joy\n- 自分が直前に言ったこと: 「やあ」\n" \
           "- 直前に相手から聞いた話: 「おはよう」\n\n問いかけ: 元気？"
    assert_equal want, session.calls[0][0]
  end

  def test_a_context_without_known_keys_leaves_the_prompt_bare
    session = FakeSession.new
    service(session: session).respond("元気？", { last_action: "chat" })
    assert_equal "元気？", session.calls[0][0]
  end

  def test_a_timeout_or_a_failed_generation_answers_nil
    [FoundationModel::TimeoutError.new("no reply within 60000 ms"),
     FoundationModel::GenerationError.new("guardrail")].each do |error|
      assert_nil service(session: FakeSession.new(error: error)).respond("こんにちは")
    end
  end

  def test_synthesize_encodes_the_speech_at_the_default_gain
    pcm = [20000, -20000].pack("s<*")
    say = FakeSay.new(pcm: pcm)
    ulaw = service(say: say).synthesize("やあ")
    assert_equal StackchanSidecar::Ulaw.encode_pcm(pcm, StackchanSidecar::DEFAULT_GAIN), ulaw
    assert_equal [["やあ", nil]], say.calls
  end

  def test_synthesize_passes_the_gain_and_the_rate
    pcm = [20000].pack("s<*")
    say = FakeSay.new(pcm: pcm)
    ulaw = service(say: say).synthesize("やあ", 0.5, 220)
    assert_equal StackchanSidecar::Ulaw.encode_pcm(pcm, 0.5), ulaw
    assert_equal [["やあ", 220]], say.calls
  end

  def test_synthesize_answers_nil_when_say_or_the_wav_fails
    [StackchanSidecar::Say::Error.new("say failed"),
     StackchanSidecar::Wav::FormatError.new("no data chunk")].each do |error|
      assert_nil service(say: FakeSay.new(error: error)).synthesize("やあ")
    end
  end

  def test_the_stub_replies_with_the_prompt_cut_to_19_characters
    stub = StackchanSidecar::StubService.new
    assert_equal "stub返答:こんにちは", stub.respond("こんにちは", {})
    assert_equal 19, stub.respond("あいうえおかきくけこさしすせそたちつてと").length
  end

  def test_the_stub_speaks_80_bytes_of_silence_per_character
    assert_equal "\xFF" * 240, StackchanSidecar::StubService.new.synthesize("abc")
  end
end
