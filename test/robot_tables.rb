module RobotTables
  FACE_INDEX = {
    "0" => :neutral,
    "1" => :smile,
    "2" => :joy,
    "3" => :surprised,
    "4" => :sad,
    "5" => :angry,
  }

  def self.faces
    {
      neutral:   StackChan::Robot::Face.new,
      smile:     StackChan::Robot::Face.new(mouth: 8),
      joy:       StackChan::Robot::Face.new(mouth: 18),
      surprised: StackChan::Robot::Face.new(mouth: :open),
      sad:       StackChan::Robot::Face.new(mouth: -8),
      angry:     StackChan::Robot::Face.new(brows: :angry),
      closed:    StackChan::Robot::Face.new(eyes: :closed, mouth: :none),
    }
  end

  def self.touch_handlers
    {
      0 => ->(r) { r.face(:surprised); r.led(:both,  [0, 60, 0], flash: 300) },
      1 => ->(r) { r.face(:angry);     r.led(:right, [60, 0, 0], flash: 300) },
      2 => ->(r) { r.face(:sad);       r.led(:left,  [0, 0, 60], flash: 300) },
    }
  end

  def self.dispatcher(display:, led:, stdout:, head: nil, speaker: nil, frame_handlers: {})
    StackChan::Robot::Dispatcher.new(
      display: display, led: led, stdout: stdout, head: head, speaker: speaker,
      faces: faces, face_index: FACE_INDEX, frame_handlers: frame_handlers
    )
  end
end
