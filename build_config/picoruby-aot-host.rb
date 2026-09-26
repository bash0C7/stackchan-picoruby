# Host VM for bench/aot_ab.rb and bench/aot_multicore.rb: the picotest defines
# without PICORB_DEBUG, picoruby-multicore's pthread port, and the gems
# tools/aot/kernels_build.rb generated for the host (the AOT kernels and their
# multicore_kernels table). Built by tools/aot_host_vm.sh.
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
  conf.linker.libraries << 'crypt'   # the spinel runtime's String#crypt

  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gem core: 'picoruby-bin-picoruby'

  conf.gem gemdir: "#{AOT_BUILD}/picoruby-multicore-host"
  conf.gem gemdir: "#{AOT_BUILD}/host/gems/picoruby-stackchan_aot"
  conf.gem gemdir: "#{AOT_BUILD}/host/picoruby-kernel_registry"
end
