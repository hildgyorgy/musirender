import AVFoundation
import AudioToolbox
import Foundation

public struct StreamAudioFormat: Codable, Equatable, Sendable {
    public let codec: String
    public let sampleRateHz: Double?
    public let bitDepth: UInt32?
    public let channels: UInt32?
    public let estimatedBitrateBps: Double?

    static func sampleRate(at url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              tracks.count == 1, let track = tracks.first,
              let stream = await streamDescription(from: track) else { return nil }
        return validSampleRate(stream.mSampleRate)
    }

    private static func streamDescription(from track: AVAssetTrack) async -> AudioStreamBasicDescription? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              descriptions.count == 1, let description = descriptions.first else { return nil }
        return CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
    }

    private static func validSampleRate(_ rate: Double) -> Double? {
        rate.isFinite && rate > 0 ? rate : nil
    }

    static func read(from track: AVAssetTrack) async -> Self? {
        guard let stream = await streamDescription(from: track) else { return nil }
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
            sampleRateHz: validSampleRate(stream.mSampleRate),
            bitDepth: depth,
            channels: stream.mChannelsPerFrame > 0 ? stream.mChannelsPerFrame : nil,
            estimatedBitrateBps: bitrate.isFinite && bitrate > 0 ? bitrate : nil
        )
    }
}
