module Multicore
  class Job
    def initialize(value)
      @value = value
      @polls = 0
    end

    def done?
      @polls += 1
      @polls >= 2
    end

    attr_reader :value
  end

  @log = []

  def self.log
    @log
  end

  def self.spawn(name, *args)
    @log << [:spawn, name, args[0].bytesize]
    Job.new(send(name, *args))
  end
end
