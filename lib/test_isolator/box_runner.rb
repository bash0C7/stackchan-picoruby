require "test-unit"
require "json"

module TestIsolator
  module BoxRunner
    module_function

    def run_file(path)
      unless Ruby::Box.enabled?
        raise "Ruby::Box not enabled — runner_main.rb must be invoked with RUBY_BOX=1"
      end

      box = Ruby::Box.new

      # Inject $LOAD_PATH into the box so it can require gems
      $LOAD_PATH.each do |load_path|
        box.eval("$LOAD_PATH << #{load_path.inspect}")
      end

      expanded_path = File.expand_path(path)

      # Build the script as a string with proper interpolation
      script = build_test_runner_script(expanded_path, path)

      # Execute inside the box and get JSON result back
      result_json = box.eval(script)
      JSON.parse(result_json, symbolize_names: true)
    end

    def build_test_runner_script(expanded_path, display_path)
      # Build as a string to avoid heredoc interpolation issues
      code = "require 'test-unit'\n"
      code += "require 'test/unit/ui/console/testrunner'\n"
      code += "require 'json'\n"
      code += "require 'stringio'\n"
      code += "\n"
      code += "load_error = nil\n"
      code += "test_count = 0\n"
      code += "assertion_count = 0\n"
      code += "failure_count = 0\n"
      code += "error_count = 0\n"
      code += "output_lines = []\n"
      code += "passed = true\n"
      code += "\n"
      code += "begin\n"
      code += "  require #{expanded_path.inspect}\n"
      code += "rescue StandardError, LoadError, ScriptError => ex\n"
      code += "  load_error = \"#{'{'}ex.class#{'}'}}: #{'{'}ex.message#{'}'}}\"\n"
      code += "  error_count = 1\n"
      code += "  passed = false\n"
      code += "end\n"
      code += "\n"
      code += "unless load_error\n"
      code += "  test_cases = Test::Unit::TestCase.subclasses\n"
      code += "  if test_cases.any?\n"
      code += "    # Suppress console output by redirecting stdout\n"
      code += "    old_stdout = $stdout\n"
      code += "    $stdout = StringIO.new\n"
      code += "    begin\n"
      code += "      suite = Test::Unit::TestSuite.new(#{display_path.inspect})\n"
      code += "      test_cases.each { |tc| suite << tc.suite }\n"
      code += "      runner = Test::Unit::UI::Console::TestRunner.new(suite)\n"
      code += "      result = runner.start\n"
      code += "      test_count = result.run_count\n"
      code += "      assertion_count = result.assertion_count\n"
      code += "      failure_count = result.failure_count\n"
      code += "      error_count = result.error_count\n"
      code += "      passed = result.passed?\n"
      code += "      result.failures.each do |f|\n"
      code += "        output_lines << \"  Failure: #{'{'}f.short_display#{'}'} \"\n"
      code += "      end\n"
      code += "      result.errors.each do |ex|\n"
      code += "        output_lines << \"  Error: #{'{'}ex.short_display#{'}'} \"\n"
      code += "      end\n"
      code += "    ensure\n"
      code += "      $stdout = old_stdout\n"
      code += "    end\n"
      code += "  end\n"
      code += "end\n"
      code += "\n"
      code += "{\n"
      code += "  file: #{display_path.inspect},\n"
      code += "  test_count: test_count,\n"
      code += "  assertion_count: assertion_count,\n"
      code += "  failure_count: failure_count,\n"
      code += "  error_count: error_count,\n"
      code += "  passed: passed,\n"
      code += "  output: load_error || output_lines.join(\"\\n\"),\n"
      code += "}.to_json\n"
      code
    end
  end
end
