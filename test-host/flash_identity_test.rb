require 'test/unit'
require 'flash_identity'

class FlashIdentityTest < Test::Unit::TestCase
  FIX = File.expand_path("fixtures", __dir__)
  TABLE = File.binread(File.join(FIX, "cores3_partition_table.bin"))
  APP = File.binread(File.join(FIX, "cores3_app_header.bin"))

  def test_the_cores3_partition_table_puts_storage_at_0x410000
    parts = FlashIdentity.partitions(TABLE)
    assert_equal %w[nvs phy_init factory storage], parts.map { |p| p["label"] }
    storage = parts.find { |p| p["label"] == "storage" }
    assert_equal ["0x410000", "0x100000"], storage.values_at("offset", "size")
  end

  def test_the_app_header_carries_the_firmware_version_and_project
    assert_equal({ "version" => "2f18720", "project" => "R2P2-ESP32" }, FlashIdentity.app_version(APP))
  end

  def test_an_erased_app_slot_is_an_error
    assert_raise(FlashIdentity::Error) { FlashIdentity.app_version("\xFF".b * 0x100) }
  end

  def test_the_printed_lines_parse_back
    got = FlashIdentity.parse(FlashIdentity.lines(TABLE, APP).join("\n") + "\n")
    assert_equal "0x410000", got["partitions"]["storage"]["offset"]
    assert_equal "2f18720", got["app_version"]
  end

  def test_one_read_from_the_partition_table_through_the_app_header_splits_into_both
    assert_equal [0x8000, 0x8100], FlashIdentity::READ
    bin = TABLE + "\xFF".b * (0x8000 - TABLE.size) + APP
    assert_equal 0x8100, bin.size
    assert_equal [TABLE, APP], FlashIdentity.split(bin)
    assert_equal "2f18720", FlashIdentity.parse(FlashIdentity.lines(*FlashIdentity.split(bin)).join("\n") + "\n")["app_version"]
  end

  def test_the_sha_comes_from_a_bare_sha_or_a_git_describe_version
    assert_equal "2f18720", FlashIdentity.sha_of("2f18720")
    assert_equal "2f18720", FlashIdentity.sha_of("0.2.21-30-g2f18720")
    assert_nil FlashIdentity.sha_of("0.2.21-30-g2f18720-dirty")
    assert_nil FlashIdentity.sha_of("0.2.21")
  end
end
