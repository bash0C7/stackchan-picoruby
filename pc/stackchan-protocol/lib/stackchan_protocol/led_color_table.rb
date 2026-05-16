module StackchanProtocol
  LED_COLORS = {
    "red"     => [255, 0,   0],
    "green"   => [0,   255, 0],
    "blue"    => [0,   0,   255],
    "yellow"  => [255, 255, 0],
    "cyan"    => [0,   255, 255],
    "magenta" => [255, 0,   255],
    "white"   => [255, 255, 255],
    "off"     => [0,   0,   0],
  }.freeze

  LED_MODES = {
    "solid"     => "s",
    "blink"     => "b",
    "breathing" => "p",
    "off"       => "o",
  }.freeze
end
