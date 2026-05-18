module StackchanProtocol
  class Dispatcher
    ERROR_BYTE = "?"
    ACK_BYTE   = "."

    FACE_TABLE = {
      "0" => Face::Neutral,
      "1" => Face::Smile,
      "2" => Face::Joy,
      "3" => Face::Surprised,
      "4" => Face::Sad,
      "5" => Face::Angry,
    }.freeze

    MODE_TABLE = {
      "s" => :solid,
      "b" => :blink,
      "p" => :breathing,
      "o" => :off,
    }.freeze

    SIDE_TABLE = {
      "L" => :left,
      "R" => :right,
      "B" => :both,
    }.freeze

    attr_reader :current_face_class

    def initialize(display:, led:, stdout: $stdout)
      @display = display
      @led     = led
      @stdout  = stdout
      @current_face_class = Face::Neutral
    end

    def handle(frame)
      attempts = []
      attempts << handle_face(frame) if frame.key?("F")
      attempts << handle_led(frame)  if frame.key?("L")
      success = !attempts.empty? && attempts.all? { |ok| ok }
      @stdout.write(success ? ACK_BYTE : ERROR_BYTE)
    rescue => e
      log_error(e)
      @stdout.write(ERROR_BYTE)
    end

    private

    def handle_face(frame)
      face_class = FACE_TABLE[frame["F"]]
      return false unless face_class
      @current_face_class = face_class
      face_class.new.draw(@display)
      true
    end

    def handle_led(frame)
      mode = MODE_TABLE[frame["M"]]
      return false unless mode
      side = SIDE_TABLE[frame["S"]]
      return false unless side
      r = (frame["R"] || "0").to_i
      g = (frame["G"] || "0").to_i
      b = (frame["B"] || "0").to_i
      @led.animate_side(side, r, g, b, mode)
      true
    end

    def log_error(e)
      # No-op for now; on-device logging would go here.
    end
  end
end
