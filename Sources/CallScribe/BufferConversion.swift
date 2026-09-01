@preconcurrency import AVFoundation

/// The input block only runs synchronously inside `convert(to:error:withInputFrom:)`.
private final class Flag: @unchecked Sendable {
    var raised = false
}

extension AVAudioConverter {
    /// Push one live buffer through, for a recording that must survive a device
    /// switch: the file keeps its original format and whatever the new hardware
    /// delivers is converted to it on the fly.
    func convertLive(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw NSError(domain: "at.skyline.CallScribe", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not allocate a conversion buffer"])
        }

        let delivered = Flag()
        var conversionError: NSError?
        let status = convert(to: converted, error: &conversionError) { _, outStatus in
            if delivered.raised {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered.raised = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            throw conversionError ?? NSError(domain: "at.skyline.CallScribe", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Sample-rate conversion failed"])
        }
        return converted
    }
}
