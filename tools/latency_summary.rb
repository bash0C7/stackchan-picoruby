#!/usr/bin/env ruby
# Summarize a tools/latency_baseline.zsh log (TSV: label, seconds, rc=N, output
# head) per verb: sample count, median / p90 / max of the successful samples,
# and the number of failed samples (rc != 0, i.e. ACK timeout + recovery).
#
#   ruby tools/latency_summary.rb [/tmp/stackchan-picoruby-debug/baseline.log]
# Summarizes latency_baseline.zsh logs per verb.
module LatencySummary
  # @rbs!
  #   type summary_row = { verb: String, n: Integer, median: Float?, p90: Float?, max: Float?, failures: Integer }

  # One sample: its label, the verb derived from the label, seconds taken and the exit code.
  Row = Struct.new(
    :label, #: String
    :verb, #: String
    :seconds, #: Float
    :rc #: Integer
  )

  module_function

  # Parses TSV log text into rows, skipping lines without an rc= field.
  #: (String text) -> Array[Row]
  def parse(text)
    rows = []
    text.each_line do |line|
      parts = line.chomp.split("\t")
      next unless parts.size >= 3 && parts[2].start_with?("rc=")
      label = parts[0]
      rows << Row.new(label, label.sub(/-\d+\z/, ""), parts[1].to_f, parts[2].sub("rc=", "").to_i)
    end
    rows
  end

  # Nearest-rank percentile on an ascending Array; nil when empty.
  # Nearest-rank percentile p (0..1) of an ascending array; nil when empty.
  #: (Array[Float] sorted, Float p) -> Float?
  def percentile(sorted, p)
    return nil if sorted.empty?
    rank = (p * sorted.size).ceil
    rank = 1 if rank < 1
    sorted[rank - 1]
  end

  # Median of an ascending array; nil when empty.
  #: (Array[Float] sorted) -> Float?
  def median(sorted)
    return nil if sorted.empty?
    n = sorted.size
    n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  end

  # Returns per verb the sample count, median, p90, max of the successful samples and the failure count.
  #: (Array[Row] rows) -> Array[summary_row]
  def summarize(rows)
    rows.group_by(&:verb).map do |verb, rs|
      ok = rs.select { |r| r.rc == 0 }.map(&:seconds).sort
      {
        verb: verb,
        n: rs.size,
        median: median(ok),
        p90: percentile(ok, 0.9),
        max: ok.last,
        failures: rs.count { |r| r.rc != 0 },
      }
    end
  end

  # Renders the summary as a Markdown table.
  #: (Array[summary_row] summary) -> String
  def to_markdown(summary)
    fmt = ->(v) { v.nil? ? "-" : format("%.2f", v) }
    lines = ["| verb | n | median s | p90 s | max s | failures |", "|---|---|---|---|---|---|"]
    summary.each do |s|
      lines << "| #{s[:verb]} | #{s[:n]} | #{fmt.call(s[:median])} | #{fmt.call(s[:p90])} | #{fmt.call(s[:max])} | #{s[:failures]} |"
    end
    lines.join("\n")
  end
end

if __FILE__ == $0
  path = ARGV[0] || "/tmp/stackchan-picoruby-debug/baseline.log"
  puts LatencySummary.to_markdown(LatencySummary.summarize(LatencySummary.parse(File.read(path))))
end
