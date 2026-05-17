require_relative "stackchan_notifier/version"

module StackchanNotifier
  class Error < StandardError; end

  def self.default_socket_path
    "/tmp/stackchan-notifier-#{Process.uid}.sock"
  end

  def self.default_drb_uri(socket_path = default_socket_path)
    "drbunix:#{socket_path}"
  end
end
