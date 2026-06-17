require "foundation_model_mac"
require "stackchan_ai_companion/frame_text"
require "stackchan_notifier/emotion_tag"

module StackchanNotifier
  module Handlers
    # Reacts to a head-touch zone event: zone -> themed prompt -> FM (words +
    # emotion tag) -> face + text -> one <F:n,text:...> frame to the device.
    class TouchReactionHandler
      # FM persona: emit a leading emotion tag, then one short Japanese sentence.
      PERSONA =
        "あなたは小さな卓上ロボットです。返事の先頭に感情タグを1つ付け、" \
        "その後に日本語で1文だけ20文字以内で答えます。" \
        "感情タグは [neutral] [smile] [joy] [surprised] [sad] [angry] のいずれか。" \
        "例: [joy]うれしいな"

      # Zone -> themed prompt fragment. Exact zone<->physical mapping is
      # confirmed by HITL (Phase D) and these strings refined then.
      ZONE_THEME = {
        0 => "頭のてっぺんをやさしく撫でられました。",
        1 => "ほっぺのあたりを触られました。",
        2 => "後頭部を不意に触られました。",
      }.freeze
      DEFAULT_THEME = "頭を触られました。"

      # Per-zone default face if the FM omits a usable tag.
      ZONE_DEFAULT_FACE = { 0 => 2, 1 => 1, 2 => 3 }.freeze # joy / smile / surprised
      NEUTRAL_FACE = 0
      SAD_FACE     = 4

      def initialize(session:, frame_text: StackchanAiCompanion::FrameText,
                     emotion: StackchanNotifier::EmotionTag)
        @session    = session
        @frame_text = frame_text
        @emotion    = emotion
      end

      def deliver(client:, params:, ctx:)
        zone   = params[:zone]
        theme  = ZONE_THEME[zone] || DEFAULT_THEME
        prompt = "#{theme}短く反応してください。"
        reply  = @session.respond(to: prompt)
        face, text = @emotion.parse(reply, fallback_face: ZONE_DEFAULT_FACE[zone] || NEUTRAL_FACE)
        client.raw_send(@frame_text.build(face_index: face, text: text))
      rescue AppleFoundationModel::GenerationError
        client.raw_send(@frame_text.build(face_index: SAD_FACE, text: "うまく考えられませんでした"))
      end
    end
  end
end
