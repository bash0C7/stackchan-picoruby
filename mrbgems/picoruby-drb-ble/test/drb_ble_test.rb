class DRbBleTest < Picotest::Test
  class Front
    def servo(opts)
      [opts[:yaw_left], opts[:pitch_up]]
    end

    def face(name)
      "face:#{name}"
    end

    def echo(s)
      s
    end

    def boom
      raise ArgumentError, "bad"
    end
  end

  ALLOW = [:servo, :face, :echo, :boom]

  # Peripheral side in-process: every written chunk goes to the Responder and
  # its reply comes back as notification-sized chunks, one per poll.
  class LoopbackLink
    attr_reader :sent

    def initialize(responder, chunk)
      @responder = responder
      @chunk = chunk
      @sent = []
      @inbox = []
    end

    def send_chunk(bytes)
      @sent << bytes
      reply = @responder.feed(bytes)
      parts = DRbBle.chunks(reply, @chunk)
      i = 0
      while i < parts.length
        @inbox << parts[i]
        i += 1
      end
    end

    def poll
      @inbox.shift
    end
  end

  class SilentLink
    def send_chunk(_bytes); end
    def poll = nil
  end

  def setup
    @responder = DRbBle::Responder.new(Front.new, allow: ALLOW)
    @link = LoopbackLink.new(@responder, 20)
    DRbBle.register("drbble://stackchan", @link)
    @remote = DRb::DRbObject.new_with_uri("drbble://stackchan")
  end

  def request_bytes(msg_id, args)
    w = DRbBle::Writer.new
    DRb::DRbMessage.new(w).send_request(nil, msg_id, args, nil)
    w.out
  end

  def decode_reply(bytes)
    DRb::DRbMessage.new(DRbBle::Reader.new(bytes)).recv_reply
  end

  def test_chunks_splits_at_size
    assert_equal ["abc", "de"], DRbBle.chunks("abcde", 3)
    assert_equal [], DRbBle.chunks("", 3)
  end

  def test_call_round_trips_through_drb_object
    assert_equal "face:joy", @remote.face("joy")
  end

  def test_hash_argument_and_array_result
    assert_equal [50, 30], @remote.servo({ yaw_left: 50, pitch_up: 30 })
  end

  def test_request_leaves_as_small_chunks
    @remote.echo("x" * 400)
    assert_true @link.sent.length >= 3
    i = 0
    while i < @link.sent.length
      assert_true @link.sent[i].bytesize <= DRbBle::CHUNK
      i += 1
    end
  end

  def test_large_payload_survives_both_directions
    s = "0123456789" * 50
    assert_equal s, @remote.echo(s)
  end

  def test_responder_waits_for_the_whole_request
    req = request_bytes(:face, ["smile"])
    i = 0
    while i < req.bytesize - 1
      assert_equal "", @responder.feed(req.byteslice(i, 1))
      i += 1
    end
    reply = @responder.feed(req.byteslice(req.bytesize - 1, 1))
    assert_equal [true, "face:smile"], decode_reply(reply)
    # nothing left over: the next request parses on its own
    assert_equal [true, "face:a"], decode_reply(@responder.feed(request_bytes(:face, ["a"])))
  end

  def test_two_requests_in_one_write_get_two_replies
    reply = @responder.feed(request_bytes(:face, ["a"]) + request_bytes(:face, ["b"]))
    r = DRbBle::Reader.new(reply)
    m = DRb::DRbMessage.new(r)
    assert_equal [true, "face:a"], m.recv_reply
    assert_equal [true, "face:b"], m.recv_reply
  end

  def test_method_outside_allow_list_is_refused
    reply = @responder.feed(request_bytes(:instance_variables, []))
    ok, msg = decode_reply(reply)
    assert_false ok
    assert_equal "NoMethodError: instance_variables is not exposed", msg
  end

  def test_exception_in_front_becomes_remote_error
    err = nil
    begin
      @remote.boom
    rescue => e
      err = e
    end
    assert_equal "ArgumentError: bad", err.message
  end

  def test_reset_drops_partial_request
    req = request_bytes(:face, ["x"])
    @responder.feed(req.byteslice(0, 5))
    @responder.reset
    assert_equal [true, "face:x"], decode_reply(@responder.feed(req))
  end

  def test_silent_peer_times_out
    DRbBle.register("drbble://silent", SilentLink.new, timeout_ms: 40)
    err = nil
    begin
      DRb::DRbObject.new_with_uri("drbble://silent").face("joy")
    rescue DRb::DRbConnError => e
      err = e
    end
    assert_equal "drbble: no reply in 40 ms", err.message
  end

  def test_unregistered_uri_is_bad_uri
    err = nil
    begin
      DRb::DRbObject.new_with_uri("drbble://nobody").face("joy")
    rescue DRb::DRbBadURI => e
      err = e
    end
    assert_equal "drbble: no link registered for drbble://nobody", err.message
  end

  def test_garbage_is_dropped_and_the_next_request_still_answers
    assert_equal "", @responder.feed("\x00\x00\x00\x03xyz")
    assert_equal [true, "face:ok"], decode_reply(@responder.feed(request_bytes(:face, ["ok"])))
  end

  def test_a_request_that_never_completes_is_dropped_past_the_limit
    @responder.feed("\x00\x0f\xff\xff")
    @responder.feed("x" * DRbBle::Responder::MAX_REQUEST)
    assert_equal [true, "face:ok"], decode_reply(@responder.feed(request_bytes(:face, ["ok"])))
  end
end
