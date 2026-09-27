require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'uart'
require 'ili9342'
require 'py32-io-expander'
require 'stackchan-protocol'
require 'scservo'
require 'ble'
require 'i2s'

StackChan.robot do |bot|
  bot.face :neutral
  bot.face :smile,     mouth: 8
  bot.face :joy,       mouth: 18
  bot.face :surprised, mouth: :open
  bot.face :sad,       mouth: -8
  bot.face :angry,     brows: :angry
  bot.face :closed,    eyes: :closed, mouth: :none

  bot.face_index "0" => :neutral, "1" => :smile, "2" => :joy,
                 "3" => :surprised, "4" => :sad, "5" => :angry

  bot.on_touch(:back)  { |r| r.face(:surprised); r.led(:both,  [0, 60, 0], flash: 300) }
  bot.on_touch(:right) { |r| r.face(:angry);     r.led(:right, [60, 0, 0], flash: 300) }
  bot.on_touch(:left)  { |r| r.face(:sad);       r.led(:left,  [0, 0, 60], flash: 300) }

  bot.every(5000) { |r| r.blink(150) }
end.run
