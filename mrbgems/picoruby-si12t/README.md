# picoruby-si12t

Si12T 3-zone capacitive touch sensor (I2C 0x68).

## Usage

```ruby
touch = Si12T.new(i2c)
touch.read_zones
touch.poll
```

`read_zones` returns the three zone intensities, each 0..3. `poll` returns the zone index
once when a touch starts (the highest intensity, the lowest index on a tie) and nil while the
touch is held and until it is released. Both raise what `I2C#read` raises.
