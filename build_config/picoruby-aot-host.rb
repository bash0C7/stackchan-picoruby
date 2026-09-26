# Host VM for bench/aot_ab.rb: the picotest defines without PICORB_DEBUG, the
# C gem, and the suppify gem that tools/aot_host_vm.sh generated from
# aot/kernels/. Used through MRUBY_CONFIG=<this file>.
MRuby::Build.new("host-aot") do |conf|
  conf.toolchain :gcc

  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.linker.libraries << 'ssl'
  conf.linker.libraries << 'crypto'

  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gem core: 'picoruby-bin-picoruby'

  conf.gem File.expand_path('../mrbgems/picoruby-aw88298', __dir__)
  conf.gem File.expand_path('../build/aot/picoruby-stackchan_aot', __dir__)
end
