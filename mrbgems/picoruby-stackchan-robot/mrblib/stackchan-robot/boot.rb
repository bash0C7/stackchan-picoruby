module StackChan
  class Robot
    class Boot
      I2C_SDA_PIN  = 12
      I2C_SCL_PIN  = 11
      AXP2101_ADDR = 0x34
      AW9523_ADDR  = 0x58
      PY32_ADDR    = 0x6F
      SCK_PIN       = 36
      MOSI_PIN      = 37
      CS_PIN        = 3
      DC_PIN        = 35
      DUMMY_RST_PIN = 1
      DUMMY_BL_PIN  = 2
      SPEAKER_SAMPLE_RATE = 8000

      def self.run
        puts ""
        puts "[application] boot"

        i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000,
                      sda_pin: I2C_SDA_PIN, scl_pin: I2C_SCL_PIN)

        i2c.write(AXP2101_ADDR, 0x97, 0x1C)
        i2c.write(AXP2101_ADDR, 0x69, 0x35)
        i2c.write(AXP2101_ADDR, 0x30, 0x3F)
        i2c.write(AXP2101_ADDR, 0x90, 0xBF)
        i2c.write(AXP2101_ADDR, 0x92, 13)
        i2c.write(AXP2101_ADDR, 0x94, 28)
        i2c.write(AXP2101_ADDR, 0x95, 28)
        i2c.write(AXP2101_ADDR, 0x27, 0x00)
        i2c.write(AXP2101_ADDR, 0x99, 24)

        i2c.write(AW9523_ADDR, 0x02, 0b00000111)
        i2c.write(AW9523_ADDR, 0x03, 0b10000001)
        i2c.write(AW9523_ADDR, 0x04, 0b00011000)
        i2c.write(AW9523_ADDR, 0x05, 0b00001100)
        i2c.write(AW9523_ADDR, 0x11, 0b00010000)
        i2c.write(AW9523_ADDR, 0x12, 0b11111111)
        i2c.write(AW9523_ADDR, 0x13, 0b11111111)
        Machine.delay_ms(20)
        i2c.write(AW9523_ADDR, 0x03, 0b10000011)
        Machine.delay_ms(10)

        spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
                      sck_pin: SCK_PIN, copi_pin: MOSI_PIN, mode: 2)
        display = ILI9342.new(
          spi: spi,
          dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
          cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
          rst_pin: GPIO.new(DUMMY_RST_PIN, GPIO::OUT),
          bl_pin:  GPIO.new(DUMMY_BL_PIN,  GPIO::OUT),
          width: 320, height: 240, rotation: :landscape
        )

        Machine.delay_ms(800)
        ver_bytes = i2c.read(PY32_ADDR, 1, 0x02, timeout: 200)
        if ver_bytes && ver_bytes.length > 0
          puts sprintf("[application] PY32 REG_VERSION = 0x%02X", ver_bytes.bytes[0])
        end

        # REQUIRED FOR PY32 COLD-BOOT
        puts "[boot] step:py32-init-begin"
        py32 = PY32IOExpander.new(i2c)
        puts "[boot] step:py32-instance"
        py32.set_direction(0, true)
        py32.set_pull_mode(0, true)
        py32.digital_write(0, true)
        Machine.delay_ms(200)
        puts "[boot] step:py32-gpio-enabled"

        led_init_attempt = 0
        led = nil
        begin
          led = StackchanLed.new(py32)
        rescue IOError => e
          led_init_attempt += 1
          if led_init_attempt < 6
            Machine.delay_ms(200)
            retry
          end
          raise e
        end
        puts "[boot] step:led-init-ok"

        Machine.delay_ms(50)
        led.show
        puts "[boot] step:led-show-ok"
        StackChan::Robot::Face.new(eyes: :closed, mouth: :none).draw(display)
        puts "[application] LCD cold-boot done (torque-OFF idle)"
        touch = nil
        begin
          touch = Si12T.new(i2c)
          puts "[boot] step:si12t-init-ok"
        rescue => e
          puts "[boot] si12t init failed: #{e.class}: #{e.message}"
        end

        head = nil
        begin
          servo_uart = UART.new(unit: :ESP32_UART1, txd_pin: 6, rxd_pin: 7, baudrate: 1_000_000)
          yaw_servo   = SCServo.new(servo_uart, id: 1)
          pitch_servo = SCServo.new(servo_uart, id: 2)
          yaw_servo.enable_torque(false)
          pitch_servo.enable_torque(false)
          head = StackChan::Robot::Head.new(yaw_servo, pitch_servo)
          puts "[boot] servo init OK (torque OFF, awaiting <torque:on>)"
        rescue => e
          puts "[boot] servo init failed: #{e.class}: #{e.message}"
        end

        speaker = nil
        begin
          speaker_i2s = I2S.new(sample_rate: SPEAKER_SAMPLE_RATE)
          speaker = AW88298.new(i2c: i2c, i2s: speaker_i2s)
          speaker.init_amp(SPEAKER_SAMPLE_RATE)
          puts "[boot] speaker init OK (AW88298 @ 0x36 + I2S @ #{SPEAKER_SAMPLE_RATE}Hz)"
        rescue => e
          puts "[boot] speaker init failed: #{e.class}: #{e.message}"
        end

        { display: display, led: led, head: head, touch: touch, speaker: speaker }
      end
    end
  end
end
