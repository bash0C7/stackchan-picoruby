require "test_helper"
require "stringio"

class CalibrationMedianTest < Test::Unit::TestCase
  def test_median_of_odd_count
    assert_equal 485, StackchanBleClient::Calibration.median([482, 485, 487])
  end

  def test_median_of_even_count_uses_lower_middle
    assert_equal 484, StackchanBleClient::Calibration.median([482, 484, 486, 488])
  end

  def test_median_single_value
    assert_equal 500, StackchanBleClient::Calibration.median([500])
  end

  def test_median_empty_raises
    assert_raise(ArgumentError) { StackchanBleClient::Calibration.median([]) }
  end
end

class CalibrationComputeAnchorsTest < Test::Unit::TestCase
  def sample_pose(yaw, pitch)
    { yaw_raw: yaw, pitch_raw: pitch }
  end

  def test_symmetric_ranges
    result = StackchanBleClient::Calibration.compute_anchors(
      forward:    sample_pose(485, 628),
      left_max:   sample_pose(530, 628),
      right_max:  sample_pose(440, 628),
      up_max:     sample_pose(485, 660),
      fwd_verify: sample_pose(485, 628),
    )
    assert_equal 485, result[:servo_yaw_zero]
    assert_equal 628, result[:servo_pitch_zero]
    assert_equal 45,  result[:yaw_range_raw]
    assert_equal 32,  result[:pitch_range_raw]
    assert_equal({ yaw_delta: 0, pitch_delta: 0 }, result[:forward_verify])
  end

  def test_asymmetric_yaw_picks_min_radius
    result = StackchanBleClient::Calibration.compute_anchors(
      forward:    sample_pose(485, 628),
      left_max:   sample_pose(540, 628),
      right_max:  sample_pose(450, 628),
      up_max:     sample_pose(485, 660),
      fwd_verify: sample_pose(485, 628),
    )
    assert_equal 35, result[:yaw_range_raw]
  end

  def test_forward_verify_records_delta_signed
    result = StackchanBleClient::Calibration.compute_anchors(
      forward:    sample_pose(485, 628),
      left_max:   sample_pose(530, 628),
      right_max:  sample_pose(440, 628),
      up_max:     sample_pose(485, 660),
      fwd_verify: sample_pose(488, 626),
    )
    assert_equal({ yaw_delta: 3, pitch_delta: -2 }, result[:forward_verify])
  end
end

class CalibrationClassifyVerifyTest < Test::Unit::TestCase
  def test_pass_within_three
    result = StackchanBleClient::Calibration.classify_verify(yaw_delta: 2, pitch_delta: -3)
    assert_equal :pass, result
  end

  def test_warn_above_three_within_ten
    result = StackchanBleClient::Calibration.classify_verify(yaw_delta: 5, pitch_delta: 0)
    assert_equal :warn, result
  end

  def test_warn_when_only_pitch_exceeds
    result = StackchanBleClient::Calibration.classify_verify(yaw_delta: 1, pitch_delta: -8)
    assert_equal :warn, result
  end

  def test_fail_above_ten
    result = StackchanBleClient::Calibration.classify_verify(yaw_delta: 12, pitch_delta: 0)
    assert_equal :fail, result
  end
end

class CalibrationFormatTest < Test::Unit::TestCase
  def anchors
    {
      servo_yaw_zero: 485, servo_pitch_zero: 628,
      yaw_range_raw: 45, pitch_range_raw: 32,
      forward_verify: { yaw_delta: 1, pitch_delta: 0 },
    }
  end

  def test_format_ruby
    out = StackchanBleClient::Calibration.format(anchors, :ruby)
    assert_match(/^SERVO_YAW_ZERO\s*=\s*485$/,   out)
    assert_match(/^SERVO_PITCH_ZERO\s*=\s*628$/, out)
    assert_match(/^YAW_RANGE_RAW\s*=\s*45$/,     out)
    assert_match(/^PITCH_RANGE_RAW\s*=\s*32$/,   out)
  end

  def test_format_env
    out = StackchanBleClient::Calibration.format(anchors, :env)
    assert_equal(
      "SERVO_YAW_ZERO=485\nSERVO_PITCH_ZERO=628\nYAW_RANGE_RAW=45\nPITCH_RANGE_RAW=32\n",
      out
    )
  end

  def test_format_json
    out = StackchanBleClient::Calibration.format(anchors, :json)
    parsed = JSON.parse(out)
    assert_equal 485, parsed["servo_yaw_zero"]
    assert_equal 32,  parsed["pitch_range_raw"]
    assert_equal 1,   parsed["forward_verify"]["yaw_delta"]
  end

  def test_format_unknown_raises
    assert_raise(ArgumentError) { StackchanBleClient::Calibration.format(anchors, :yaml) }
  end
end

class CalibrationParseRawDetailTest < Test::Unit::TestCase
  def test_parse_numeric_pair
    pose = StackchanBleClient::Calibration.parse_raw_detail("<yaw_raw:485,pitch_raw:628>\n")
    assert_equal({ yaw_raw: 485, pitch_raw: 628 }, pose)
  end

  def test_parse_unknown_yaw
    pose = StackchanBleClient::Calibration.parse_raw_detail("<yaw_raw:unknown,pitch_raw:628>\n")
    assert_nil pose[:yaw_raw]
    assert_equal 628, pose[:pitch_raw]
  end

  def test_parse_both_unknown
    pose = StackchanBleClient::Calibration.parse_raw_detail("<yaw_raw:unknown,pitch_raw:unknown>\n")
    assert_nil pose[:yaw_raw]
    assert_nil pose[:pitch_raw]
  end

  def test_parse_negative_value
    pose = StackchanBleClient::Calibration.parse_raw_detail("<yaw_raw:-27139,pitch_raw:628>\n")
    assert_equal(-27139, pose[:yaw_raw])
  end

  def test_parse_malformed_raises
    assert_raise(ArgumentError) { StackchanBleClient::Calibration.parse_raw_detail(".\n") }
  end
end

class CalibrationSampleTest < Test::Unit::TestCase
  class FakeClient
    attr_reader :detail_frames_left, :send_calls
    def initialize(detail_frames)
      @detail_frames_left = detail_frames.dup
      @send_calls = 0
    end
    def send(&block)
      @send_calls += 1
      block.call(self)
      self
    end
    def read_pos; end
    def last_detail_frame
      @detail_frames_left.shift
    end
  end

  def test_sample_pose_returns_median_of_n_reads
    client = FakeClient.new([
      "<yaw_raw:482,pitch_raw:627>\n",
      "<yaw_raw:485,pitch_raw:628>\n",
      "<yaw_raw:487,pitch_raw:629>\n",
    ])
    pose = StackchanBleClient::Calibration.sample_pose(client, samples: 3)
    assert_equal 485, pose[:yaw_raw]
    assert_equal 628, pose[:pitch_raw]
    assert_equal 3, client.send_calls
  end

  def test_sample_pose_raises_when_any_unknown
    client = FakeClient.new([
      "<yaw_raw:485,pitch_raw:628>\n",
      "<yaw_raw:unknown,pitch_raw:628>\n",
      "<yaw_raw:487,pitch_raw:628>\n",
    ])
    assert_raise(StackchanBleClient::Calibration::UnknownReadError) do
      StackchanBleClient::Calibration.sample_pose(client, samples: 3)
    end
  end

  def test_sample_pose_single_sample
    client = FakeClient.new(["<yaw_raw:500,pitch_raw:620>\n"])
    pose = StackchanBleClient::Calibration.sample_pose(client, samples: 1)
    assert_equal 500, pose[:yaw_raw]
  end
end

class CalibrationAlignOnlyTest < Test::Unit::TestCase
  class ScriptedClient
    attr_reader :sent
    def initialize; @sent = []; end
    def send(&block)
      collector = Collector.new(@sent)
      block.call(collector)
      self
    end
    class Collector
      def initialize(sink); @sink = sink; end
      def torque(on:); @sink << [:torque, on]; end
      def read_pos;    @sink << [:read_pos]; end
    end
  end

  def test_run_align_only_sends_torque_off_prompts_then_torque_on
    client = ScriptedClient.new
    prompts = []
    StackchanBleClient::Calibration.run_align_only(
      client: client,
      prompt: ->(msg) { prompts << msg },
      stdout: StringIO.new,
    )
    assert_equal [[:torque, false], [:torque, true]], client.sent
    assert_equal 1, prompts.length
    assert_match(/FORWARD/, prompts[0])
  end

  def test_run_align_only_skip_torque_omits_torque_calls_but_keeps_prompt
    client = ScriptedClient.new
    prompts = []
    StackchanBleClient::Calibration.run_align_only(
      client: client,
      prompt: ->(msg) { prompts << msg },
      stdout: StringIO.new,
      skip_torque: true,
    )
    assert_equal [], client.sent
    assert_equal 1, prompts.length
    assert_match(/FORWARD/, prompts[0])
  end
end

class CalibrationFullRunTest < Test::Unit::TestCase
  class ScriptedFullClient
    attr_reader :sent, :detail_frames_left
    def initialize(detail_frames)
      @sent = []
      @detail_frames_left = detail_frames.dup
    end
    def send(&block)
      collector = Collector.new(@sent)
      block.call(collector)
      self
    end
    def last_detail_frame; @detail_frames_left.shift; end
    class Collector
      def initialize(sink); @sink = sink; end
      def torque(on:); @sink << [:torque, on]; end
      def read_pos;    @sink << [:read_pos]; end
    end
  end

  def make_client_with_poses(forward:, left:, right:, up:, verify:)
    frames = [forward, left, right, up, verify].map { |p|
      "<yaw_raw:#{p[0]},pitch_raw:#{p[1]}>\n"
    }
    ScriptedFullClient.new(frames)
  end

  def test_run_full_calibrate_happy_path_returns_anchors_outcome_pass
    client = make_client_with_poses(
      forward: [485, 628], left: [530, 628], right: [440, 628],
      up: [485, 660], verify: [486, 628],
    )
    result = StackchanBleClient::Calibration.run_full_calibrate(
      client: client,
      prompt: ->(_msg) { nil },
      stdout: StringIO.new,
      samples: 1,
      engage_torque: false,
    )
    assert_equal :pass, result[:outcome]
    assert_equal 485,   result[:anchors][:servo_yaw_zero]
    assert_equal 45,    result[:anchors][:yaw_range_raw]
    assert_equal 32,    result[:anchors][:pitch_range_raw]
    refute_includes client.sent, [:torque, true]
  end

  def test_run_full_calibrate_engage_torque_sends_torque_on_at_end
    client = make_client_with_poses(
      forward: [485, 628], left: [530, 628], right: [440, 628],
      up: [485, 660], verify: [485, 628],
    )
    StackchanBleClient::Calibration.run_full_calibrate(
      client: client,
      prompt: ->(_msg) { nil },
      stdout: StringIO.new,
      samples: 1,
      engage_torque: true,
    )
    assert_equal [:torque, true], client.sent.last
  end

  def test_run_full_calibrate_verify_fail_returns_outcome_fail
    client = make_client_with_poses(
      forward: [485, 628], left: [530, 628], right: [440, 628],
      up: [485, 660], verify: [500, 628],
    )
    result = StackchanBleClient::Calibration.run_full_calibrate(
      client: client,
      prompt: ->(_msg) { nil },
      stdout: StringIO.new,
      samples: 1,
      engage_torque: false,
    )
    assert_equal :fail, result[:outcome]
  end

  def test_run_full_calibrate_propagates_unknown_read_error
    client = ScriptedFullClient.new([
      "<yaw_raw:unknown,pitch_raw:unknown>\n",
    ])
    assert_raise(StackchanBleClient::Calibration::UnknownReadError) do
      StackchanBleClient::Calibration.run_full_calibrate(
        client: client,
        prompt: ->(_msg) { nil },
        stdout: StringIO.new,
        samples: 1,
        engage_torque: false,
      )
    end
  end

  def test_run_full_calibrate_propagates_operator_abort
    abort_prompt = ->(_msg) { raise Interrupt }
    client = ScriptedFullClient.new([])
    assert_raise(Interrupt) do
      StackchanBleClient::Calibration.run_full_calibrate(
        client: client,
        prompt: abort_prompt,
        stdout: StringIO.new,
        samples: 1,
        engage_torque: false,
      )
    end
  end

  def test_run_full_calibrate_skip_torque_omits_initial_off_and_final_on
    client = make_client_with_poses(
      forward: [485, 628], left: [530, 628], right: [440, 628],
      up: [485, 660], verify: [485, 628],
    )
    StackchanBleClient::Calibration.run_full_calibrate(
      client: client,
      prompt: ->(_msg) { nil },
      stdout: StringIO.new,
      samples: 1,
      engage_torque: true,
      skip_torque: true,
    )
    refute_includes client.sent, [:torque, false]
    refute_includes client.sent, [:torque, true]
  end
end
