require 'drb'
def out(s); $stdout.write(s + "\n"); $stdout.flush; end
out "CLIENT_START"
begin
  DRb.start_service
  out "START_SERVICE_OK"
rescue => e
  out "start_service err: #{e.class}: #{e.message}"
end
begin
  ro = DRb::DRbObject.new_with_uri("druby://127.0.0.1:8787")
  out "PING=" + ro.ping.to_s
  out "RESP=" + ro.respond("頭を撫でられた", {:touch_zone => 1, "k" => "x"}).to_s
  out "CLIENT_OK"
rescue => e
  out "CLIENT_ERR: #{e.class}: #{e.message}"
end
