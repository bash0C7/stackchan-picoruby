class LatencySummaryTest < Picotest::Test
  LOG = "status-1\t0.412\trc=0\tble_connected: true\n" \
        "face-1\t3.190\trc=0\tok\n" \
        "face-2\t2.070\trc=0\tok\n" \
        "face-3\t18.740\trc=1\tACK timeout\n" \
        "recovered (try 1)\n" \
        "face-4\t2.960\trc=0\tok\n" \
        "torque-off\t1.500\trc=0\tok\n" \
        "=== done ===\n"

  def summary_for(verb)
    LatencySummary.summarize(LatencySummary.parse(LOG)).find { |h| h[:verb] == verb }
  end

  def test_parse_keeps_only_measurement_rows_and_derives_the_verb
    rows = LatencySummary.parse(LOG)
    assert_equal %w[status-1 face-1 face-2 face-3 face-4 torque-off], rows.map { |r| r[:label] }
    assert_equal %w[status face face face face torque-off], rows.map { |r| r[:verb] }
    assert_equal 1, rows[3][:rc]
    assert_in_delta 18.74, rows[3][:seconds], 0.0001
  end

  def test_statistics_exclude_failed_samples
    s = summary_for("face")
    assert_equal 4, s[:n]
    assert_equal 1, s[:failures]
    assert_in_delta 2.96, s[:median], 0.0001
    assert_in_delta 3.19, s[:p90], 0.0001
    assert_in_delta 3.19, s[:max], 0.0001
  end

  def test_even_count_median_averages_the_middle_pair
    rows = LatencySummary.parse("a-1\t1.0\trc=0\tx\na-2\t3.0\trc=0\tx\n")
    assert_in_delta 2.0, LatencySummary.summarize(rows)[0][:median], 0.0001
  end

  def test_all_failed_verb_has_nil_statistics
    s = LatencySummary.summarize(LatencySummary.parse("led-1\t18.0\trc=1\tx\n"))[0]
    assert_nil s[:median]
    assert_equal 1, s[:failures]
  end

  def test_markdown_has_one_row_per_verb
    md = LatencySummary.to_markdown(LatencySummary.summarize(LatencySummary.parse(LOG)))
    assert md.include?("| face | 4 | 2.96 | 3.19 | 3.19 | 1 |")
    assert md.include?("| status | 1 | 0.41 | 0.41 | 0.41 | 0 |")
    failed = LatencySummary.to_markdown(LatencySummary.summarize(LatencySummary.parse("led-1\t18.0\trc=1\tx\n")))
    assert failed.include?("| led | 1 | - | - | - | 1 |")
  end
end
