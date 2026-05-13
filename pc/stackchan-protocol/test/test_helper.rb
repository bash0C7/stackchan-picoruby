$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

require "test/unit"
require "fake_uart"
