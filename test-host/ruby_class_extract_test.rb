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

  def test_extract_to_file_writes_class_bodies_without_executing_toplevel
    src = Tempfile.new(["src", ".rb"])
    src.write(<<~RUBY)
      require 'nonexistent_gem'
      puts "top-level side effect"
      class Widget
        def ping = :pong
      end
      class Secret < BLE
      end
    RUBY
    src.close
    out = Tempfile.new(["out", ".rb"])
    out.close

    returned = RubyClassExtract.extract_to_file(src.path, out.path, exclude_superclasses: %w[BLE])

    assert_equal out.path, returned
    written = File.read(out.path)
    assert written.include?("class Widget")
    refute written.include?("Secret"), "BLE-derived class should be excluded"
    refute written.include?("nonexistent_gem"), "top-level require should be stripped"
    refute written.include?("side effect"), "top-level code should be stripped"
    src.unlink
    out.unlink
  end

  # ble_client.rb wraps its radio classes in `if Object.const_defined?(:BLE)`;
  # the pc suite depends on the walker descending into that guard.
  def test_classes_inside_if_guard_are_extracted
    src = Tempfile.new(["guarded", ".rb"])
    src.write(<<~RUBY)
      module Pure
        def self.one = 1
      end
      if Object.const_defined?(:BLE)
        class Radio < BLE
          def ping; end
        end
        class Central
          def pump; end
        end
      end
    RUBY
    src.close
    out = RubyClassExtract.extract_source_from(src.path)
    assert out.include?("module Pure")
    assert out.include?("class Radio < BLE")
    assert out.include?("class Central")
    refute out.include?("const_defined?"), "the if statement itself is not emitted, only its class bodies"
    src.unlink
  end
end
