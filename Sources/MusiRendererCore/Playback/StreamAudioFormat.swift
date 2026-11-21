import AVFoundation
import AudioToolbox
import Foundation

public struct StreamAudioFormat: Codable, Equatable, Sendable {
    public let codec: String
    public let sampleRateHz: Double?
    public let bitDepth: UInt32?
    public let channels: UInt32?
    public let estimatedBitrateBps: Double?

    static func read(from track: AVAssetTrack) async -> Self? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              descriptions.count == 1, let description = descriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        let codec: String
        let depth: UInt32?
        switch stream.mFormatID {
        case kAudioFormatAppleLossless:
            codec = "ALAC"
            switch stream.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: depth = 16
            case kAppleLosslessFormatFlag_20BitSourceData: depth = 20
            case kAppleLosslessFormatFlag_24BitSourceData: depth = 24
            case kAppleLosslessFormatFlag_32BitSourceData: depth = 32
            default: depth = stream.mBitsPerChannel > 0 ? stream.mBitsPerChannel : nil
            }
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
            codec = "AAC"
            depth = nil
        case kAudioFormatMPEGLayer3:
            codec = "MP3"
            depth = nil
        case kAudioFormatLinearPCM:
            codec = "PCM"
            depth = stream.mBitsPerChannel > 0 ? stream.mBitsPerChannel : nil
        default:
            codec = "0x" + String(stream.mFormatID, radix: 16, uppercase: true)
            depth = nil
        }
        let bitrate = Double((try? await track.load(.estimatedDataRate)) ?? 0)
        return Self(
            codec: codec,
            sampleRateHz: stream.mSampleRate.isFinite && stream.mSampleRate > 0 ? stream.mSampleRate : nil,
            bitDepth: depth,
            channels: stream.mChannelsPerFrame > 0 ? stream.mChannelsPerFrame : nil,
            estimatedBitrateBps: bitrate.isFinite && bitrate > 0 ? bitrate : nil
        )
    }
}
