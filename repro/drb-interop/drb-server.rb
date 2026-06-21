require 'drb/drb'
class AISvc
  def respond(prompt, ctx)
    "reply<= #{prompt} | zone=#{ctx[:touch_zone]} | echo=#{ctx['k']}"
  end
  def ping; "pong"; end
end
DRb.start_service("druby://127.0.0.1:8787", AISvc.new)
$stdout.sync = true
puts "SERVER_READY"
sleep 30
