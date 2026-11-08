module AmbientDemo
  COLORS = %w[red green blue yellow cyan magenta white]
  MODES  = %w[blink breathing solid]
  SIDES  = %w[left right both]
  FACES  = %w[smile joy]

  LED_INTERVAL_S  = [4, 9]
  FACE_INTERVAL_S = [12, 25]
  MOVE_INTERVAL_S = [30, 70]

  class Cli
    def initialize(path)
      @path = path
    end

    def run(*args)
      words = args.map { |a| "'#{a}'" }.join(" ")
      io = IO.popen("'#{@path}' #{words} 2>&1; echo exit:$?")
      lines = io.read.split("\n")
      io.close
      code = lines.pop.to_s.sub("exit:", "").to_i
      lines.each { |l| puts l }
      AmbientDemo.log("stackchan #{args.join(' ')} #{code == 0 ? 'OK' : 'FAILED'}")
      code
    end
  end

  def self.log(msg)
    t = Time.now
    puts "[#{format('%02d:%02d:%02d', t.hour, t.min, t.sec)}] #{msg}"
  end

  def self.pick(list)
    list[rand(list.size)]
  end

  def self.between(range)
    range[0] + rand(range[1] - range[0] + 1)
  end

  def self.wait_until_connected(cli, sleep_fn)
    while true
      code = cli.run("connect")
      return true if code == 0
      return false unless code == 8
      log("robot busy, retrying connect...")
      sleep_fn.call(3)
    end
  end

  def self.rest_state(cli)
    cli.run("led", "both", "off", "off")
    cli.run("face", "neutral")
    cli.run("servo", "--yaw-left", 0, "--pitch-up", 0, "--time", 800)
    cli.run("torque", "off")
  end

  def self.ambient(cli)
    now = Time.now.to_f
    next_led = now
    next_face = now
    next_move = now
    while true
      now = Time.now.to_f
      if now >= next_led
        cli.run("led", pick(SIDES), pick(COLORS), pick(MODES))
        next_led = now + between(LED_INTERVAL_S)
      end
      if now >= next_face
        cli.run("face", pick(FACES))
        next_face = now + between(FACE_INTERVAL_S)
      end
      if now >= next_move
        cli.run("servo", pick(%w[--yaw-left --yaw-right]), rand(101), "--pitch-up", rand(101),
                "--time", between([600, 1200]))
        next_move = now + between(MOVE_INTERVAL_S)
      end
      sleep 1
    end
  end
end

if ARGV[0]
  cli = AmbientDemo::Cli.new("#{ARGV[0]}/pc/stackchan-pico/bin/stackchan")
  if ARGV[1] == "rest"
    AmbientDemo.rest_state(cli)
  elsif AmbientDemo.wait_until_connected(cli, ->(s) { sleep s })
    cli.run("torque", "on")
    AmbientDemo.ambient(cli)
  else
    AmbientDemo.log("stackchan connect failed")
    exit 1
  end
end
