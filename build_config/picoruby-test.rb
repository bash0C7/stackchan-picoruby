# Host picotest VM: upstream picoruby-test.rb plus the C gems of this repo.
# Used by `rake picotest:build` through MRUBY_CONFIG=<this file>.
MRuby::Build.new do |conf|
  conf.toolchain :gcc

  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_DEBUG"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  # Link OpenSSL libraries for socket SSL support
  conf.linker.libraries << 'ssl'
  conf.linker.libraries << 'crypto'

  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gem core: 'picoruby-bin-picoruby'
  conf.gem core: 'picoruby-picotest'

  # This repo's C gems, so the host suites exercise the same code the device runs.
  conf.gem File.expand_path('../mrbgems/picoruby-aw88298', __dir__)
end
