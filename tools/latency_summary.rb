module LatencySummary
  def self.parse(text)
    rows = []
    text.each_line do |line|
      parts = line.chomp.split("\t")
      next unless parts.size >= 3 && parts[2].start_with?("rc=")
      label = parts[0]
      rows << { label: label, verb: label.sub(/-\d+\z/, ""), seconds: parts[1].to_f, rc: parts[2].sub("rc=", "").to_i }
    end
    rows
  end

  def self.percentile(sorted, p)
    return nil if sorted.empty?
    rank = (p * sorted.size).ceil
    rank = 1 if rank < 1
    sorted[rank - 1]
  end

  def self.median(sorted)
    return nil if sorted.empty?
    n = sorted.size
    n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  end

  def self.summarize(rows)
    verbs = []
    rows.each { |r| verbs << r[:verb] unless verbs.include?(r[:verb]) }
    verbs.map do |verb|
      ok = []
      failures = 0
      n = 0
      rows.each do |r|
        next unless r[:verb] == verb
        n += 1
        if r[:rc] == 0
          ok << r[:seconds]
        else
          failures += 1
        end
      end
      ok = ok.sort
      { verb: verb, n: n, median: median(ok), p90: percentile(ok, 0.9), max: ok.last, failures: failures }
    end
  end

  def self.cell(v)
    v.nil? ? "-" : format("%.2f", v)
  end

  def self.to_markdown(summary)
    lines = ["| verb | n | median s | p90 s | max s | failures |", "|---|---|---|---|---|---|"]
    summary.each do |s|
      lines << "| #{s[:verb]} | #{s[:n]} | #{cell(s[:median])} | #{cell(s[:p90])} | #{cell(s[:max])} | #{s[:failures]} |"
    end
    lines.join("\n")
  end
end

if ARGV[0]
  puts LatencySummary.to_markdown(LatencySummary.summarize(LatencySummary.parse(File.read(ARGV[0]))))
end
