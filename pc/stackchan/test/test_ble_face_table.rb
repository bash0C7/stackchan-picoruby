require_relative "test_helper"
require "stackchan/ble"

class FaceTableTest < Test::Unit::TestCase
  def test_neutral_index_is_zero
    assert_equal "0", Stackchan::BLE::FaceTable::FACE_INDICES.fetch(:neutral)
  end

  def test_smile_index_is_one
    assert_equal "1", Stackchan::BLE::FaceTable::FACE_INDICES.fetch(:smile)
  end

  def test_joy_index_is_two
    assert_equal "2", Stackchan::BLE::FaceTable::FACE_INDICES.fetch(:joy)
  end

  def test_surprised_index_is_three
    assert_equal "3", Stackchan::BLE::FaceTable::FACE_INDICES.fetch(:surprised)
  end

  def test_sad_index_is_four
    assert_equal "4", Stackchan::BLE::FaceTable::FACE_INDICES.fetch(:sad)
  end

  def test_angry_index_is_five
    assert_equal "5", Stackchan::BLE::FaceTable::FACE_INDICES.fetch(:angry)
  end

  def test_unknown_face_raises_key_error
    assert_raise(KeyError) do
      Stackchan::BLE::FaceTable::FACE_INDICES.fetch(:bogus)
    end
  end
end
