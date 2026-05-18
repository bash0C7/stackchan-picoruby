$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'test/unit'
require 'tempfile'
require 'ruby_class_extract'

class RubyClassExtractTest < Test::Unit::TestCase
  def setup
    @fixture = Tempfile.new(['fixture', '.rb'])
    @fixture.write(<<~RUBY)
      require 'nonexistent_gem'
      puts "top-level execution should be stripped"

      module Sample
        class Greeter
          def hello
            "hi"
          end
        end
      end

      Sample::Greeter.new.hello
    RUBY
    @fixture.close
  end

  def teardown
    @fixture.unlink
  end

  def test_load_classes_from_strips_requires_and_top_level
    RubyClassExtract.load_classes_from(@fixture.path)
    assert defined?(Sample::Greeter), "class should be loaded"
    assert_equal "hi", Sample::Greeter.new.hello
  end

  def test_exclude_superclasses_skips_matching_class
    fix = Tempfile.new(['fixture', '.rb'])
    fix.write(<<~RUBY)
      class BLE
      end

      class StackChanApp < BLE
        def boot; end
      end

      class Plain
        def whatever; end
      end
    RUBY
    fix.close

    Object.const_set(:BLE, Class.new) unless defined?(BLE)

    RubyClassExtract.load_classes_from(fix.path, exclude_superclasses: %w[BLE])
    assert defined?(Plain), "non-excluded class should be loaded"
    refute defined?(StackChanApp), "BLE-derived class should be skipped"
    fix.unlink
  end

  def test_load_classes_from_handles_minimal_class
    fix = Tempfile.new(['fixture', '.rb'])
    fix.write("class Beacon\nend\n")
    fix.close
    RubyClassExtract.load_classes_from(fix.path)
    assert defined?(Beacon), "class loaded from tempfile-extracted source"
    fix.unlink
  end
end
