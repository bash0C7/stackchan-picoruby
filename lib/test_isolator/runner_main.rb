#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "test_isolator/box_runner"
require "test_isolator/result_aggregator"

module TestIsolator
  module Main
    module_function

    def run(argv)
      if argv.empty?
        warn "usage: ruby lib/test_isolator/runner_main.rb <test_file> [test_file ...]"
        return 2
      end

      results = argv.map { |path| BoxRunner.run_file(path) }
      report  = ResultAggregator.aggregate(results)
      puts ResultAggregator.render(results)
      report[:exit_code]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit TestIsolator::Main.run(ARGV)
end
