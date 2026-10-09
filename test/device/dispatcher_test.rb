class DispatcherFaceTest < Picotest::Test
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = MiniSink.new
    @disp    = RobotTables.dispatcher(display: @display, led: @led, stdout: @stdout)
  end

  class MiniSink
    attr_reader :writes
    def initialize; @writes = []; end
    def write(b); @writes << b; end
  end

  def test_F_0_draws_neutral
    @disp.handle({ "F" => "0" })
    assert @display.calls.any? { |c| c.first == :draw_ellipse }
  end

  def test_F_4_draws_sad
    @disp.handle({ "F" => "4" })
    line = @display.calls.find { |c| c.first == :draw_line }.last
    assert_equal 148, line[1]
  end

  def test_F_5_draws_angry_with_brows
    @disp.handle({ "F" => "5" })
    methods = @display.calls.map(&:first)
    assert_equal [:draw_rect, :draw_rect, :draw_ellipse, :draw_ellipse,
                  :draw_line, :draw_line, :draw_line, :draw_line], methods
  end

  def test_a_face_command_repaints_only_the_eye_and_mouth_bands_never_the_whole_face_region
    @disp.handle({ "F" => "5" })
    rects = @display.calls.select { |c| c.first == :draw_rect }.map(&:last)
    assert_equal 2, rects.length
    full = rects.select { |r| r[2] == 320 && r[3] == StackChan::Robot::Face::FACE_REGION_HEIGHT }
    assert_equal 0, full.length
  end

  def test_F_known_writes_ack_dot
    @disp.handle({ "F" => "0" })
    assert(@stdout.writes.include?(".\n"))
  end

  def test_F_unknown_writes_question_mark
    @disp.handle({ "F" => "99" })
    assert(@stdout.writes.include?("?\n"))
  end

  class RaisingDisplay
    def draw_rect(x, y, w, h, color, fill: false)
      raise IOError, "spi"
    end
  end

  def test_a_dispatch_exception_answers_question_mark
    disp = RobotTables.dispatcher(display: RaisingDisplay.new, led: @led, stdout: @stdout)
    disp.handle({ "F" => "0" })
    assert_equal ["?\n"], @stdout.writes
  end

  def build(face_index: RobotTables::FACE_INDEX, frame_handlers: {}, faces: RobotTables.faces)
    StackChan::Robot::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout,
      faces: faces, face_index: face_index, frame_handlers: frame_handlers
    )
  end

  def test_the_face_index_maps_the_wire_index_to_the_named_face
    disp = build(face_index: { "7" => :surprised })
    disp.handle({ "F" => "7" })
    assert_equal ".\n", @stdout.writes[0]
    assert_equal :open, disp.current_face.mouth
    assert @display.calls.any? { |c| c.first == :draw_rect && c.last[2] == 12 && c.last[3] == 24 }
  end

  def test_an_index_missing_from_the_face_index_answers_question_mark_and_draws_nothing
    disp = build(face_index: { "7" => :surprised })
    disp.handle({ "F" => "0" })
    assert_equal ["?\n"], @stdout.writes
    assert_equal [], @display.calls
  end

  def test_an_index_naming_a_face_that_is_not_defined_answers_question_mark
    disp = build(face_index: { "0" => :wink })
    disp.handle({ "F" => "0" })
    assert_equal ["?\n"], @stdout.writes
  end

  def test_faces_without_neutral_raise_argument_error
    faces = RobotTables.faces
    faces.delete(:neutral)
    assert_raise(ArgumentError) { build(faces: faces) }
  end

  def test_faces_without_closed_raise_argument_error
    faces = RobotTables.faces
    faces.delete(:closed)
    assert_raise(ArgumentError) { build(faces: faces) }
  end

  def test_torque_off_shows_the_closed_face_and_torque_on_the_neutral_face
    @disp.handle({ "torque" => "off" })
    assert_equal :closed, @disp.current_face.eyes
    @disp.handle({ "torque" => "on" })
    assert_equal :open, @disp.current_face.eyes
    assert_equal 0, @disp.current_face.mouth
    assert_equal [".\n", ".\n"], @stdout.writes
  end

  def test_a_frame_handler_receives_the_handle_and_the_value_and_reaches_the_led
    seen = []
    disp = build(frame_handlers: { "glow" => ->(r, v) { seen << v; r.led(:left, [v.to_i, 0, 0]) } })
    disp.handle({ "glow" => "40" })
    assert_equal ["40"], seen
    assert_equal [[:animate_side, [:left, 40, 0, 0, :solid]]], @led.calls
    assert_equal [".\n"], @stdout.writes
  end

  def test_a_frame_handler_returning_false_answers_question_mark
    disp = build(frame_handlers: { "glow" => ->(_r, _v) { false } })
    disp.handle({ "glow" => "40" })
    assert_equal ["?\n"], @stdout.writes
  end

  def test_a_frame_handler_returning_nil_answers_question_mark
    disp = build(frame_handlers: { "glow" => ->(_r, _v) { nil } })
    disp.handle({ "glow" => "40" })
    assert_equal ["?\n"], @stdout.writes
  end

  def test_a_false_frame_handler_turns_a_good_face_frame_into_question_mark
    disp = build(frame_handlers: { "glow" => ->(_r, _v) { false } })
    disp.handle({ "F" => "1", "glow" => "40" })
    assert_equal ["?\n"], @stdout.writes
  end

  def test_a_truthy_frame_handler_keeps_a_bad_face_frame_at_question_mark
    disp = build(frame_handlers: { "glow" => ->(_r, _v) { 1 } })
    disp.handle({ "F" => "99", "glow" => "40" })
    assert_equal ["?\n"], @stdout.writes
  end

  def test_a_raising_frame_handler_answers_question_mark
    disp = build(frame_handlers: { "glow" => ->(_r, _v) { raise IOError, "x" } })
    disp.handle({ "glow" => "40" })
    assert_equal ["?\n"], @stdout.writes
  end

  def test_a_key_without_a_handler_is_ignored_as_before
    disp = build(frame_handlers: { "glow" => ->(_r, _v) { false } })
    disp.handle({ "other" => "1" })
    assert_equal [".\n"], @stdout.writes
  end
end
