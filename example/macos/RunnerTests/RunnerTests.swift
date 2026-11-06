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
