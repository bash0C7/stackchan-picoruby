# Reads the partition table and app version from a flash dump of the first 0x10100 bytes.
module FlashIdentity
  PARTITION_TABLE = [0x8000, 0xC00].freeze
  APP_HEADER = [0x10000, 0x100].freeze
  READ = [PARTITION_TABLE[0], APP_HEADER.sum - PARTITION_TABLE[0]].freeze
  APP_DESC_MAGIC = 0xABCD5432

  # Raised when the app image carries no esp_app_desc_t.
  class Error < StandardError; end

  module_function

  # Returns one hash per partition table entry with label, type, subtype, offset and size.
  #: (String bin) -> Array[Hash[String, untyped]]
  def partitions(bin)
    bin.b.scan(/.{32}/m).take_while { |e| e.start_with?("\xAA\x50".b) }.map do |e|
      type, subtype, offset, size = e.unpack("x2CCVV")
      { "label" => e[12, 16].delete("\x00"), "type" => type, "subtype" => subtype,
        "offset" => format("0x%x", offset), "size" => format("0x%x", size) }
    end
  end

  # Splits a flash read into the partition table bytes and the app header bytes.
  #: (String bin) -> Array[String]
  def split(bin)
    [PARTITION_TABLE, APP_HEADER].map { |addr, size| bin.b[addr - READ[0], size] }
  end

  # Returns the version and project name from the esp_app_desc_t of the app header.
  # Raises Error when the descriptor magic is missing.
  #: (String bin) -> Hash[String, String]
  def app_version(bin)
    bin = bin.b
    raise Error, "no esp_app_desc_t at 0x20 of the app image" unless bin.size >= 0x70 && bin[0x20, 4].unpack1("V") == APP_DESC_MAGIC
    { "version" => bin[0x30, 32].delete("\x00"), "project" => bin[0x50, 32].delete("\x00") }
  end

  # Returns the `[flash_identity]` report lines for the partitions, app version and project.
  #: (String partition_bin, String app_bin) -> Array[String]
  def lines(partition_bin, app_bin)
    out = partitions(partition_bin).map { |p| "[flash_identity] partition #{p['label']} #{p['offset']} #{p['size']}" }
    app = app_version(app_bin)
    out << "[flash_identity] app_version #{app['version']}"
    out << "[flash_identity] project #{app['project']}"
  end

  # Parses report lines into partitions (label to offset and size) and the app version.
  #: (String text) -> Hash[String, untyped]
  def parse(text)
    parts = text.scan(/^\[flash_identity\] partition (\S+) (\S+) (\S+)$/).to_h { |l, o, s| [l, { "offset" => o, "size" => s }] }
    { "partitions" => parts, "app_version" => text[/^\[flash_identity\] app_version (\S+)$/, 1] }
  end

  # Returns the git sha of a clean version string, or nil for a dirty or untagged one.
  #: (String? version) -> String?
  def sha_of(version)
    version.to_s[/(?:\A|-g)([0-9a-f]{7,40})\z/, 1]
  end
end
