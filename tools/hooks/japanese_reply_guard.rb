require "json"

payload = JSON.parse($stdin.read) rescue exit(0)
path = payload["transcript_path"].to_s
exit 0 unless File.file?(path)

text = nil
File.foreach(path) do |line|
  entry = JSON.parse(line) rescue next
  next unless entry["type"] == "assistant"
  content = entry.dig("message", "content")
  next unless content.is_a?(Array)
  chunk = content.select { |c| c["type"] == "text" }.map { |c| c["text"] }.join("\n")
  text = chunk unless chunk.strip.empty?
end
exit 0 if text.nil?

prose = text.gsub(/```.*?```/m, "").gsub(/`[^`\n]*`/, "")
exit 0 if prose.strip.empty?
exit 0 if prose.match?(/[\p{Hiragana}\p{Katakana}\p{Han}]/)

warn "japanese_reply_guard: the last reply has no Japanese outside code. Write the reply to the user in Japanese."
exit 2
