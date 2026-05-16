module StackchanProtocol
  module FrameWriter
    module_function

    def encode(**pairs)
      body = pairs.map { |k, v| "#{k}:#{v}" }.join(",")
      "<#{body}>\n"
    end
  end
end
