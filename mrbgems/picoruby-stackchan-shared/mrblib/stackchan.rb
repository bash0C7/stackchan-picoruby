# Namespace root for the shared layer. Defined first so that the
# `module Stackchan::BLE` / `module Stackchan::AI` reopenings in the
# sibling files resolve their parent. On PicoRuby the gem bundles every
# mrblib file (no sibling `require`), so this file must load before them.
module Stackchan
  module BLE; end
  module AI; end
end
