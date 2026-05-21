module TestIsolator
  module ResultAggregator
    module_function

    def aggregate(per_file_results)
      totals = {
        files:      per_file_results.length,
        tests:      per_file_results.sum { |r| r[:test_count] },
        assertions: per_file_results.sum { |r| r[:assertion_count] },
        failures:   per_file_results.sum { |r| r[:failure_count] },
        errors:     per_file_results.sum { |r| r[:error_count] },
      }
      exit_code = (totals[:failures] + totals[:errors]) > 0 ? 1 : 0
      { totals: totals, per_file: per_file_results, exit_code: exit_code }
    end

    def render(per_file_results)
      report = aggregate(per_file_results)
      lines = per_file_results.map { |r| render_file_line(r) }
      lines << format_summary(report[:totals])
      lines.join("\n")
    end

    def render_file_line(r)
      status = r[:passed] ? "PASS" : "FAIL"
      base = "[#{status}] #{r[:file]}  tests=#{r[:test_count]} assertions=#{r[:assertion_count]} failures=#{r[:failure_count]} errors=#{r[:error_count]}"
      r[:output].to_s.empty? ? base : "#{base}\n#{r[:output]}"
    end

    def format_summary(t)
      "SUMMARY  files=#{t[:files]} tests=#{t[:tests]} assertions=#{t[:assertions]} failures=#{t[:failures]} errors=#{t[:errors]}"
    end
  end
end
