# picoruby-si12t

Si12T 3-zone capacitive touch sensor (I2C 0x68).

## Usage

```ruby
touch = Si12T.new(i2c)
touch.read_zones            # => [z0, z1, z2] intensities 0..3
touch.poll_rising_edge      # => zone index once on touch onset, else nil
```
