require_relative "helper"
require "stackchan_notifier/tuple_space4ractor"

class TupleSpace4RactorTest < Test::Unit::TestCase
  def setup
    @ts = StackchanNotifier::TupleSpace4Ractor.new
  end

  def test_write_then_take_returns_the_tuple
    @ts.write([:hello, 1, :world])
    assert_equal [:hello, 1, :world], @ts.take([:hello, Integer, Symbol])
  end

  def test_write_then_read_does_not_consume
    @ts.write([:keep, 42])
    assert_equal [:keep, 42], @ts.read([:keep, Integer])
    assert_equal [:keep, 42], @ts.read([:keep, Integer])
  end

  def test_take_blocks_until_write
    t = Thread.new { @ts.take([:async, Integer]) }
    sleep 0.05
    assert t.alive?, "take should block before matching tuple is written"
    @ts.write([:async, 7])
    assert_equal [:async, 7], t.value
  end

  def test_type_pattern_only_matches_compatible_types
    @ts.write([:typed, "a string"])
    @ts.write([:typed, 99])
    assert_equal [:typed, 99], @ts.take([:typed, Integer])
    assert_equal [:typed, "a string"], @ts.take([:typed, String])
  end

  def test_take_nonblocking_returns_tuple_when_available
    @ts.write([:nb, 1])
    assert_equal [:nb, 1], @ts.take_nonblocking([:nb, Integer])
  end

  def test_take_nonblocking_raises_when_empty
    assert_raise(Rinda::RequestExpiredError) do
      @ts.take_nonblocking([:missing, Integer])
    end
  end

  def test_drain_loop_pattern_with_take_nonblocking
    3.times { |i| @ts.write([:drain, i]) }
    drained = []
    loop do
      drained << @ts.take_nonblocking([:drain, Integer])
    rescue Rinda::RequestExpiredError
      break
    end
    assert_equal 3, drained.size
    assert_equal [[:drain, 0], [:drain, 1], [:drain, 2]], drained.sort_by { |t| t[1] }
  end
end
