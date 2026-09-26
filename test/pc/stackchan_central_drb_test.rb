# StackchanCentral's dRuby pair: handle resolution, subscription, and a
# DRbObject call whose chunks reach a Responder and whose reply comes back as
# notifications on the DRb TX handle.
class StackchanCentralDrbTest < Picotest::Test
  RX = 0x11; TX = 0x14; CCCD = 0x16
  DRX = 0x21; DTX = 0x24; DCCCD = 0x26

  class Front
    def face(id)
      [".\n", "face #{id}"]
    end

    def echo(s)
      [s]
    end
  end

  # FakeRadio whose DRb RX writes drive a Responder; replies are scheduled as
  # DRb TX notifications in 20-byte pieces.
  class DrbRadio < FakeRadio
    def initialize(services:)
      super(services: services)
      @responder = DRbBle::Responder.new(Front.new, allow: [:face, :echo])
    end

    def write_value_of_characteristic_without_response(conn, handle, value)
      super
      return unless handle == DRX
      reply = @responder.feed(value)
      parts = DRbBle.chunks(reply, 20)
      i = 0
      while i < parts.length
        schedule_notification(DTX, parts[i], after_polls: i + 1)
        i += 1
      end
    end
  end

  def services(with_drb: true)
    chars = [
      { uuid128: NusResolver.rx_uuid, value_handle: RX, descriptors: [] },
      { uuid128: NusResolver.tx_uuid, value_handle: TX,
        descriptors: [{ uuid128: NusResolver.cccd_uuid, handle: CCCD }] },
    ]
    if with_drb
      chars << { uuid128: NusResolver.drb_rx_uuid, value_handle: DRX, descriptors: [] }
      chars << { uuid128: NusResolver.drb_tx_uuid, value_handle: DTX,
                 descriptors: [{ uuid128: NusResolver.cccd_uuid, handle: DCCCD }] }
    end
    [{ characteristics: chars }]
  end

  def build(radio)
    StackchanCentral.new(name_prefix: "StackChan", radio: radio, log_fn: ->(_l) {}).connect
  end

  def setup
    FakeClock.reset(1000)
  end

  def teardown
    DRbBle.unregister(StackchanCentral::DRB_URI)
  end

  def test_connect_subscribes_both_notify_characteristics
    radio = DrbRadio.new(services: services)
    central = build(radio)
    assert_equal [[CCCD, "\x01\x00"], [DCCCD, "\x01\x00"]], radio.descriptor_writes
    assert_true central.drb?
  end

  def test_firmware_without_the_pair_still_connects
    central = build(FakeRadio.new(services: services(with_drb: false)))
    assert_false central.drb?
    assert_raise(Stackchan::BLE::ConnectionError) { central.remote }
  end

  def test_remote_call_round_trips
    radio = DrbRadio.new(services: services)
    central = build(radio)
    assert_equal [".\n", "face 2"], central.remote.face(2)
  end

  def test_long_request_is_paced_between_chunks
    radio = DrbRadio.new(services: services)
    central = build(radio)
    FakeClock.sleeps.clear
    s = "x" * 400
    assert_equal [s], central.remote.echo(s)
    drb_writes = radio.writes.select { |w| w[0] == DRX }
    assert_true drb_writes.length >= 3
    paced = FakeClock.sleeps.select { |ms| ms == StackchanCentral::POLLING_UNIT_MS }
    assert_true paced.length >= drb_writes.length - 1
  end

  def test_text_notifications_do_not_reach_the_drb_inbox
    radio = DrbRadio.new(services: services)
    central = build(radio)
    radio.schedule_notification(TX, ".\n")
    assert_equal [".\n", "face 1"], central.remote.face(1)
  end
end
