require "test_helper"

class FaceTableTest < Test::Unit::TestCase
  def test_neutral_index_is_zero
    assert_equal "0", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:neutral)
  end

  def test_smile_index_is_one
    assert_equal "1", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:smile)
  end

  def test_joy_index_is_two
    assert_equal "2", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:joy)
  end

  def test_surprised_index_is_three
    assert_equal "3", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:surprised)
  end

  def test_unknown_face_raises_key_error
    assert_raise(KeyError) do
      StackchanBleClient::FaceTable::FACE_INDICES.fetch(:bogus)
    end
  end
end
