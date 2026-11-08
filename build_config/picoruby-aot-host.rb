# Host VM for bench/aot_ab.rb: the picotest defines
# without PICORB_DEBUG, picoruby-multicore's pthread port, and the gems
# lib/aot_kernels.rb generated for the host (the AOT kernels, with the
# multicore_kernels table). Built by `rake aot:host`.
AOT_BUILD = File.expand_path('../build/aot', __dir__)

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

  conf.gem gemdir: "#{AOT_BUILD}/picoruby-multicore-host"
  conf.gem gemdir: "#{AOT_BUILD}/host/gems/picoruby-stackchan_aot"
end
