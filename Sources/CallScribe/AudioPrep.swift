import Foundation
import AVFoundation

/// Turns a raw recording into the 16 kHz mono PCM whisper.cpp expects, and
/// reports whether it actually contains speech-level audio.
///
/// This is done natively rather than by shelling out to ffmpeg so the app can
/// ship as a self-contained bundle.
enum AudioPrep {

    struct Result {
        let url: URL
        let duration: TimeInterval
        let peak: Float
        /// Fraction of 100 ms windows whose RMS clears the noise floor.
        let activeFraction: Float
        /// RMS per 100 ms window, used to tell real speech from speaker bleed.
        let envelope: [Float]

        static let windowSeconds = 0.1

        /// Mean energy over a time range, for comparing one track against another.
        func energy(from start: TimeInterval, to end: TimeInterval) -> Float {
            let first = max(0, Int(start / Self.windowSeconds))
            let last = min(envelope.count, Int(ceil(end / Self.windowSeconds)))
            guard first < last else { return 0 }
            return envelope[first..<last].reduce(0, +) / Float(last - first)
        }

        /// Whisper hallucinates confidently on silence ("Thank you.", subtitle
        /// credits, and so on), so a track with nothing in it must be skipped
        /// rather than transcribed.
        /// Deliberately permissive: dropping a quiet speaker entirely is worse
        /// than a few junk lines, and bleed is removed later by comparing tracks.
        var hasSpeech: Bool {
            duration >= 1.0 && peak > 0.02 && activeFraction > 0.005
        }
    }

    enum PrepError: LocalizedError {
        case cannotOpen(URL)
        case converterUnavailable
        case conversion(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let url): return "Could not read \(url.lastPathComponent)"
            case .converterUnavailable: return "Could not create the audio converter"
            case .conversion(let message): return "Audio conversion failed: \(message)"
            }
        }
    }

    static let whisperSampleRate = 16000.0

    static func prepare(_ source: URL, to destination: URL) throws -> Result {
        guard let input = try? AVAudioFile(forReading: source) else {
            throw PrepError.cannotOpen(source)
        }

        let inputFormat = input.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: whisperSampleRate,
            channels: 1,
            interleaved: true)
        else { throw PrepError.converterUnavailable }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PrepError.converterUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: whisperSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true)

        let inputChunk = AVAudioFrameCount(inputFormat.sampleRate)         // ~1 s
        let outputChunk = AVAudioFrameCount(whisperSampleRate)
        var meter = Meter(windowFrames: Int(whisperSampleRate / 10))       // 100 ms
        var finished = false

        while !finished {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputChunk) else {
                throw PrepError.converterUnavailable
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusOut in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputChunk) else {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: buffer, frameCount: inputChunk)
                } catch {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                if buffer.frameLength == 0 {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                statusOut.pointee = .haveData
                return buffer
            }

            if let conversionError {
                throw PrepError.conversion(conversionError.localizedDescription)
            }
            if outputBuffer.frameLength > 0 {
                meter.consume(outputBuffer)
                try output.write(from: outputBuffer)
            }
            if status == .endOfStream || status == .error || outputBuffer.frameLength == 0 {
                finished = true
            }
        }

        let result = Result(
            url: destination,
            duration: Double(meter.totalFrames) / whisperSampleRate,
            peak: meter.peak,
            activeFraction: meter.activeFraction,
            envelope: meter.envelope)

        // People sitting around a table land far below the levels whisper was
        // trained on, and quiet input is a major source of dropped words. The
        // envelope above stays on the original scale, so cross-track bleed
        // comparisons are unaffected by this.
        // Only lift a track that clearly contains sustained speech: amplifying
        // a sparse, noisy signal makes whisper's output worse, not better.
        if result.hasSpeech, result.activeFraction > 0.10,
           let gain = normalizationGain(peak: result.peak) {
            try amplify(destination, by: gain)
        }
        return result
    }

    /// How much to lift a quiet recording, or nil if it's already loud enough.
    /// Capped so that a track containing only room tone isn't blown up into noise.
    private static func normalizationGain(peak: Float) -> Float? {
        let target: Float = 0.75
        let maximumGain: Float = 4
        guard peak > 0.001, peak < target else { return nil }
        let gain = min(target / peak, maximumGain)
        return gain > 1.2 ? gain : nil
    }

    /// Rewrites the 16 kHz file with a constant gain applied, clipping safely.
    private static func amplify(_ url: URL, by gain: Float) throws {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let frameCount = AVAudioFrameCount(input.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        try input.read(into: buffer)

        if let samples = buffer.int16ChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                let scaled = Float(samples[index]) * gain
                samples[index] = Int16(max(-32768, min(32767, scaled)))
            }
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("amp-" + url.lastPathComponent)
        let output = try AVAudioFile(
            forWriting: temporary,
            settings: input.fileFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true)
        try output.write(from: buffer)

        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// Streaming peak / active-window measurement over int16 samples.
    private struct Meter {
        let windowFrames: Int
        var totalFrames = 0
        var peak: Float = 0

        private var windowSum: Double = 0
        private var windowCount = 0
        private var activeWindows = 0
        private(set) var envelope: [Float] = []
        private var windows: Int { envelope.count }

        /// ~ -40 dBFS: above room tone, below quiet speech.
        private let noiseFloor: Float = 0.01

        init(windowFrames: Int) {
            self.windowFrames = max(1, windowFrames)
        }

        mutating func consume(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.int16ChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            totalFrames += count

            for index in 0..<count {
                let sample = Float(channel[index]) / 32768.0
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }

                windowSum += Double(sample * sample)
                windowCount += 1

                if windowCount == windowFrames {
                    let rms = Float((windowSum / Double(windowCount)).squareRoot())
                    envelope.append(rms)
                    if rms > noiseFloor { activeWindows += 1 }
                    windowSum = 0
                    windowCount = 0
                }
            }
        }

        var activeFraction: Float {
            windows > 0 ? Float(activeWindows) / Float(windows) : 0
        }
    }
}
