import AVFoundation
import AudioToolbox
import Foundation

/// Reader and writer settings that re-encode a sound track to AAC-LC.
enum AudioEncoding {
  struct Settings {
    /// For the reader output: the decoded PCM the encoder takes.
    let decoded: [String: Any]
    /// For the writer input.
    let encoded: [String: Any]
  }

  /// Sample rates the AAC-LC encoder takes.
  static let sampleRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

  static func settings(for format: CMFormatDescription?, bitrate: Int64) -> Settings {
    let source = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
    let rate = sampleRate(for: source?.mSampleRate ?? 0)
    let count = channels(for: Int(source?.mChannelsPerFrame ?? 0))
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = count == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
    let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    let common: [String: Any] = [
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: count,
      AVChannelLayoutKey: layoutData,
    ]
    return Settings(
      decoded: common.merging([
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]) { $1 },
      encoded: common.merging([
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVEncoderBitRateKey: closestBitrate(
          bitrate, in: supportedBitrates(sampleRate: rate, channels: count)),
      ]) { $1 })
  }

  /// The source rate when AAC takes it, otherwise 44.1 kHz for rates of that
  /// family (88.2 kHz) and 48 kHz for the rest.
  static func sampleRate(for source: Double) -> Double {
    if sampleRates.contains(source) { return source }
    return source > 0 && source.truncatingRemainder(dividingBy: 11025) == 0 ? 44100 : 48000
  }

  /// Mono stays mono; anything else is mixed to stereo, which every player
  /// handles without a channel layout of its own.
  static func channels(for source: Int) -> Int { source == 1 ? 1 : 2 }

  /// The bitrate closest to `requested` among the ones the encoder offers.
  /// The writer accepts any number in its settings and only fails once it
  /// starts encoding, so an out-of-range request has to be moved first.
  static func closestBitrate(_ requested: Int64, in supported: [AudioValueRange]) -> Int64 {
    let wanted = Double(requested)
    let candidates = supported.filter { $0.mMaximum > 0 }.map {
      min(max(wanted, $0.mMinimum), $0.mMaximum)
    }
    guard let closest = candidates.min(by: { abs($0 - wanted) < abs($1 - wanted) }) else {
      return requested
    }
    return Int64(closest.rounded())
  }

  private static func supportedBitrates(sampleRate: Double, channels: Int) -> [AudioValueRange] {
    let count = UInt32(channels)
    var input = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * count,
      mFramesPerPacket: 1, mBytesPerFrame: 4 * count, mChannelsPerFrame: count,
      mBitsPerChannel: 32, mReserved: 0)
    var output = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
      mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: count,
      mBitsPerChannel: 0, mReserved: 0)
    var converter: AudioConverterRef?
    guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return [] }
    defer { AudioConverterDispose(converter) }
    var size: UInt32 = 0
    guard
      AudioConverterGetPropertyInfo(
        converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr
    else { return [] }
    var ranges = [AudioValueRange](
      repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard
      AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges)
        == noErr
    else { return [] }
    return Array(ranges.prefix(Int(size) / MemoryLayout<AudioValueRange>.size))
  }
}
