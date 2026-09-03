# StackchanRadio as seen from StackchanCentral. Tests script the device's
# replies: a scheduled notification is delivered to on_notification on the
# first pop_and_dispatch whose ordinal reaches `after_polls` from now — one
# packet per call, like the real radio.
class FakeRadio
  attr_accessor :on_notification
  attr_reader :writes, :descriptor_writes, :pop_count, :target, :services, :conn_handle

  def initialize(services: [], conn_handle: 1, target: :fake_target)
    @writes = []
    @descriptor_writes = []
    @scheduled = []       # [[due_pop_count, handle, value], ...]
    @pop_count = 0
    @target = target
    @services = services
    @conn_handle = conn_handle
    @on_notification = nil
    @connect_and_discover_calls = 0
  end

  def schedule_notification(handle, value, after_polls: 1)
    @scheduled << [@pop_count + after_polls, handle, value]
  end

  def pop_and_dispatch
    @pop_count += 1
    idx = @scheduled.index { |s| s[0] <= @pop_count }
    return nil unless idx
    due = @scheduled.delete_at(idx)
    @on_notification.call(due[1], due[2]) if @on_notification
    :notification
  end

  def connect_and_discover(_timeout_ms)
    @connect_and_discover_calls += 1
  end

  def connect_and_discover_calls
    @connect_and_discover_calls
  end

  def write_value_of_characteristic_without_response(_conn_handle, handle, value)
    @writes << [handle, value]
  end

  def write_characteristic_descriptor_using_descriptor_handle(_conn_handle, handle, value)
    @descriptor_writes << [handle, value]
  end
end
