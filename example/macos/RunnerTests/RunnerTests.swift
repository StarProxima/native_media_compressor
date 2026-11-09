import AVFoundation
import CoreGraphics
import ImageIO
import XCTest

@testable import native_media_compressor

/// Native unit tests of the shared iOS and macOS code. The same file backs the
/// iOS RunnerTests target.
class RunnerTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nmc-runner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testScalingUsesTheTighterBound() {
    XCTAssertEqual(
      Scaling.factor(width: 1920, height: 1080, maxShortSide: 720, maxLongSide: 1000),
      1000.0 / 1920, accuracy: 1e-9)
    XCTAssertEqual(
      Scaling.factor(width: 1080, height: 1920, maxShortSide: 360, maxLongSide: nil),
      1.0 / 3, accuracy: 1e-9)
  }

  func testScalingNeverGrowsAndIgnoresAbsentBounds() {
    XCTAssertEqual(Scaling.factor(width: 640, height: 480, maxShortSide: 4000, maxLongSide: 8000), 1)
    XCTAssertEqual(Scaling.factor(width: 640, height: 480, maxShortSide: nil, maxLongSide: 0), 1)
    XCTAssertEqual(Scaling.factor(width: 0, height: 0, maxShortSide: 10, maxLongSide: 10), 1)
  }

  func testDisplaySizeFollowsTheRotation() {
    let size = CGSize(width: 1920, height: 1080)
    let turned = MediaAsset.displaySize(size, CGAffineTransform(rotationAngle: .pi / 2))
    XCTAssertEqual(turned.width, 1080, accuracy: 0.5)
    XCTAssertEqual(turned.height, 1920, accuracy: 0.5)
    XCTAssertEqual(MediaAsset.displaySize(size, .identity), size)
  }

  func testOrientationAddsClockwiseQuarterTurns() {
    let frame = CGSize(width: 640, height: 360)
    let once = MediaAsset.orientation(.identity, turnedBy: 1, size: frame)
    XCTAssertEqual(once, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0))
    XCTAssertEqual(MediaAsset.displaySize(frame, once), CGSize(width: 360, height: 640))

    let back = MediaAsset.orientation(.identity, turnedBy: 3, size: frame)
    XCTAssertEqual(back, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 640))

    // A portrait recording (stored landscape, turned 90 degrees) turned once
    // more is upside down; its translation follows the scaled frame.
    let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    let flipped = MediaAsset.orientation(portrait, turnedBy: 1, size: frame)
    XCTAssertEqual(flipped, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 640, ty: 360))
    XCTAssertEqual(
      MediaAsset.orientation(portrait, turnedBy: 0, size: frame),
      CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0))

    let mirrored = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    let turnedMirror = MediaAsset.orientation(mirrored, turnedBy: 2, size: frame)
    XCTAssertEqual(turnedMirror, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 360))
  }

  func testKeptRangeClampsToTheTimeline() throws {
    let duration = CMTime(value: 8000, timescale: 1000)
    let whole = try XCTUnwrap(VideoTranscoder.keptRange(startMs: nil, endMs: nil, duration: duration))
    XCTAssertEqual(whole.start.seconds, 0)
    XCTAssertEqual(whole.end.seconds, 8)

    let middle = try XCTUnwrap(VideoTranscoder.keptRange(startMs: 2000, endMs: 5000, duration: duration))
    XCTAssertEqual(middle.start.seconds, 2)
    XCTAssertEqual(middle.duration.seconds, 3)

    let tail = try XCTUnwrap(VideoTranscoder.keptRange(startMs: 1000, endMs: 30000, duration: duration))
    XCTAssertEqual(tail.end.seconds, 8)

    let early = try XCTUnwrap(VideoTranscoder.keptRange(startMs: -500, endMs: 1000, duration: duration))
    XCTAssertEqual(early.start.seconds, 0)
  }

  func testKeptRangeThatKeepsNothingIsNil() {
    let duration = CMTime(value: 2000, timescale: 1000)
    XCTAssertNil(VideoTranscoder.keptRange(startMs: 3000, endMs: 2000, duration: duration))
    XCTAssertNil(VideoTranscoder.keptRange(startMs: 5000, endMs: nil, duration: duration))
    XCTAssertNil(VideoTranscoder.keptRange(startMs: 1000, endMs: 1000, duration: duration))
  }

  func testDataRateLimitCapsEachSecondAtOneAndAHalfTimesTheAverage() {
    XCTAssertEqual(VideoTranscoder.dataRateLimits(bitrate: 2_000_000), [375_000, 1])
  }

  func testThumbnailTimeStaysOnTheLastFrame() {
    let track = CMTimeRange(start: .zero, duration: CMTime(value: 1067, timescale: 1000))
    XCTAssertEqual(VideoThumbnail.frameTime(positionMs: 500, track: track).seconds, 0.5)
    XCTAssertEqual(VideoThumbnail.frameTime(positionMs: 30000, track: track).seconds, 1.066)
    XCTAssertEqual(VideoThumbnail.frameTime(positionMs: 1067, track: track).seconds, 1.066)
    XCTAssertEqual(VideoThumbnail.frameTime(positionMs: -10, track: track).seconds, 0)
  }

  func testAudioEncodingKeepsWhatAACTakes() {
    XCTAssertEqual(AudioEncoding.sampleRate(for: 48000), 48000)
    XCTAssertEqual(AudioEncoding.sampleRate(for: 22050), 22050)
    XCTAssertEqual(AudioEncoding.sampleRate(for: 88200), 44100)
    XCTAssertEqual(AudioEncoding.sampleRate(for: 96000), 48000)
    XCTAssertEqual(AudioEncoding.sampleRate(for: 0), 48000)
    XCTAssertEqual([1, 2, 6, 0].map(AudioEncoding.channels(for:)), [1, 2, 2, 2])
  }

  func testAudioBitrateMovesToTheClosestTheEncoderOffers() {
    let offered = [32000.0, 64000, 128000].map { AudioValueRange(mMinimum: $0, mMaximum: $0) }
      + [AudioValueRange(mMinimum: 0, mMaximum: 0)]
    XCTAssertEqual(AudioEncoding.closestBitrate(100_000, in: offered), 128000)
    XCTAssertEqual(AudioEncoding.closestBitrate(1_000_000, in: offered), 128000)
    XCTAssertEqual(AudioEncoding.closestBitrate(1000, in: offered), 32000)
    XCTAssertEqual(
      AudioEncoding.closestBitrate(
        100_000, in: [AudioValueRange(mMinimum: 16000, mMaximum: 320_000)]), 100_000)
    XCTAssertEqual(AudioEncoding.closestBitrate(96000, in: []), 96000)
  }

  func testAudioEncodingSettingsFitTheEncoder() throws {
    var source = AudioStreamBasicDescription(
      mSampleRate: 96000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 24,
      mFramesPerPacket: 1, mBytesPerFrame: 24, mChannelsPerFrame: 6, mBitsPerChannel: 32,
      mReserved: 0)
    var format: CMAudioFormatDescription?
    XCTAssertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &source, layoutSize: 0, layout: nil, magicCookieSize: 0,
        magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)

    let settings = AudioEncoding.settings(for: format, bitrate: 1_000_000)

    XCTAssertEqual(settings.encoded[AVSampleRateKey] as? Double, 48000)
    XCTAssertEqual(settings.encoded[AVNumberOfChannelsKey] as? Int, 2)
    XCTAssertEqual(settings.encoded[AVEncoderBitRateKey] as? Int64, 320_000)
    XCTAssertEqual(settings.decoded[AVSampleRateKey] as? Double, 48000)
    let writer = try AVAssetWriter(
      outputURL: directory.appendingPathComponent("audio.mp4"), fileType: .mp4)
    XCTAssertTrue(writer.canApply(outputSettings: settings.encoded, forMediaType: .audio))
  }

  func testSampleRangesWalkTheChunks() {
    let ranges = ContainerAudio.sampleRanges(
      sizes: [10, 20, 30, 40, 50], chunkOffsets: [100, 1000, 5000],
      runs: [(firstChunk: 1, samples: 2), (firstChunk: 3, samples: 1)])
    XCTAssertEqual(ranges, [100..<110, 110..<130, 1000..<1030, 1030..<1070, 5000..<5050])

    XCTAssertNil(
      ContainerAudio.sampleRanges(
        sizes: [10, 20], chunkOffsets: [100], runs: [(firstChunk: 2, samples: 2)]))
    XCTAssertNil(
      ContainerAudio.sampleRanges(
        sizes: [10, 20, 30], chunkOffsets: [100], runs: [(firstChunk: 1, samples: 2)]))
  }

  func testStagedOutputReplacesTheDestinationOnlyOnSuccess() throws {
    let destination = directory.appendingPathComponent("out.jpg")
    try Data("old".utf8).write(to: destination)

    let staged = StagedOutput(destination: destination)
    XCTAssertEqual(staged.file.deletingLastPathComponent().path, directory.path)
    XCTAssertEqual(staged.file.pathExtension, "jpg")
    let failed = staged.run {
      try? Data("partial".utf8).write(to: staged.file)
      return .status(.failed)
    }
    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
    XCTAssertEqual(try entries(), ["out.jpg"])

    let next = StagedOutput(destination: destination)
    let compressed = next.run {
      try? Data("new".utf8).write(to: next.file)
      return .status(.compressed)
    }
    XCTAssertEqual(compressed.status, .compressed)
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
    XCTAssertEqual(try entries(), ["out.jpg"])
  }

  func testStagedOutputLeavesADirectoryAlone() throws {
    let folder = directory.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    var wrote = false

    let reply = StagedOutput(destination: folder).run {
      wrote = true
      return .status(.compressed)
    }

    XCTAssertEqual(reply.status, .failed)
    XCTAssertFalse(wrote)
  }

  func testImageCodecBakesInOrientationAndFitsTheBounds() throws {
    // 400x300 stored, EXIF 6: displayed as 300x400.
    let source = try writeJpeg(width: 400, height: 300, orientation: 6)
    let probe = try XCTUnwrap(ImageCodec.probe(source.path))
    XCTAssertEqual([probe.width, probe.height, probe.frameCount], [300, 400, 1])
    XCTAssertEqual(probe.mimeType, "image/jpeg")

    let destination = directory.appendingPathComponent("small.jpg")
    let reply = ImageCodec.compress(
      ImageRequest(
        source: source.path, destination: destination.path, maxShortSide: nil,
        maxLongSide: 200, format: .jpeg, quality: 80))

    XCTAssertEqual(reply.status, .compressed, reply.message ?? "")
    XCTAssertEqual([reply.width, reply.height], [150, 200])
    let output = try XCTUnwrap(ImageCodec.probe(destination.path))
    XCTAssertEqual([output.width, output.height], [150, 200])
  }

  func testImageCodecRejectsABrokenFileWithoutOutput() throws {
    let source = directory.appendingPathComponent("broken.jpg")
    try Data(repeating: 0x41, count: 512).write(to: source)
    let destination = directory.appendingPathComponent("out.jpg")

    XCTAssertNil(ImageCodec.probe(source.path))
    let reply = ImageCodec.compress(
      ImageRequest(
        source: source.path, destination: destination.path, maxShortSide: nil,
        maxLongSide: 100, format: .png, quality: 80))

    XCTAssertNotEqual(reply.status, .compressed)
    XCTAssertEqual(try entries(), ["broken.jpg"])
  }

  private func entries() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  private func writeJpeg(width: Int, height: Int, orientation: Int) throws -> URL {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let url = directory.appendingPathComponent("source.jpg")
    let target = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(
      target, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(target))
    return url
  }
}
