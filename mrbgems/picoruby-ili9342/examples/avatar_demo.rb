# examples/avatar_demo.rb — cycle 3 expressions every 5 seconds.
require 'spi'
require 'gpio'
require 'ili9342'
require_relative '_face'   # if LoadError on device, copy _face.rb to /home/ and use require '_face'

SCK_PIN  = 36
MOSI_PIN = 37
CS_PIN   = 3
DC_PIN   = 35
RST_PIN  = 1   # placeholder — see black_fill.rb header
BL_PIN   = 2   # placeholder

spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, cs_pin: CS_PIN, mode: 2)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

EXPRESSIONS = [
  [:neutral, 0],
  [:smile,   8],
  [:joy,    18],
]

loop do
  EXPRESSIONS.each do |_name, delta|
    Face.draw(display, delta)
    sleep 5
  end
end
