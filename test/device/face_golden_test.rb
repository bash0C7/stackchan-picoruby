class FaceGoldenTest < Picotest::Test
  GOLDEN_DIR = File.join(ENV["STACKCHAN_REPO_ROOT"].to_s, "spec", "golden")

  FACE_CASES = FaceGoldenHash::FACE_CASES

  def self.compute_dump(face) = FaceGoldenHash.compute_dump(face)

  FACE_CASES.each do |name, face|
    define_method("test_#{name}_matches_golden") do
      golden_path = File.join(GOLDEN_DIR, "face_#{name}.dump")
      actual = self.class.compute_dump(face)
      unless File.exist?(golden_path)
        raise "no golden at #{golden_path}; run `rake face:register_golden FACE=#{name}`"
      end
      expected = File.read(golden_path)
      assert_equal expected, actual
    end
  end
end
