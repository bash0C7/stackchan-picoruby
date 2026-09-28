import AVFoundation

final class SpeechSynth: NSObject {
    static let shared = SpeechSynth()

    private let gain: Float = 0.175
    private let targetRate: Double = 8000.0

    private let synthesizer = AVSpeechSynthesizer()

    func synthesize(text: String, completion: @escaping (String?) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.pitchMultiplier = 1.5

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetRate,
                                            channels: 1,
                                            interleaved: false) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var converter: AVAudioConverter?
        var samples: [Float] = []
        var failed = false
        var finished = false

        synthesizer.write(utterance) { buffer in
            if finished { return }
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                finished = true
                let hex = failed ? nil : Self.encodeMuLawHex(samples, gain: self.gain)
                DispatchQueue.main.async { completion(hex) }
                return
            }
            if converter == nil {
                converter = AVAudioConverter(from: pcm.format, to: outFormat)
            }
            guard let conv = converter else { failed = true; return }

            let capacity = AVAudioFrameCount(
                Double(pcm.frameLength) * self.targetRate / pcm.format.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                             frameCapacity: capacity) else {
                failed = true; return
            }
            var fed = false
            var convError: NSError?
            conv.convert(to: out, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return pcm
            }
            if convError != nil { failed = true; return }
            if let ch = out.floatChannelData {
                samples.append(contentsOf:
                    UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            }
        }
    }

    private static func encodeMuLawHex(_ samples: [Float], gain: Float) -> String? {
        guard !samples.isEmpty else { return nil }
        var hex = ""
        hex.reserveCapacity(samples.count * 2)
        let digits = Array("0123456789abcdef".utf8)
        for s in samples {
            let scaled = max(-1.0, min(1.0, s * gain))
            let i16 = Int16(scaled * 32767.0)
            let b = muLaw(i16)
            hex.append(Character(UnicodeScalar(digits[Int(b >> 4)])))
            hex.append(Character(UnicodeScalar(digits[Int(b & 0x0f)])))
        }
        return hex
    }

    private static func muLaw(_ sample: Int16) -> UInt8 {
        let bias: Int32 = 0x84
        let clip: Int32 = 32635
        var s = Int32(sample)
        let sign: UInt8 = s < 0 ? 0x80 : 0x00
        if s < 0 { s = -s }
        if s > clip { s = clip }
        s += bias
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && (s & mask) == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = UInt8((s >> (exponent + 3)) & 0x0f)
        return ~(sign | (UInt8(exponent) << 4) | mantissa)
    }
}
