import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

public final class NativeMediaCompressorPlugin: NSObject, FlutterPlugin, MediaCompressorHostApi {
  private let flutterApi: MediaCompressorFlutterApi
  // Two encodes at once would share the hardware encoder and each would take
  // about twice as long.
  private let videoQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    return queue
  }()
  // A batch of 48 MP photos decoded all at once would exhaust memory and get
  // the app killed.
  private let imageQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    return queue
  }()
  // Touched only on the platform thread.
  private var stopFlags: [Int64: StopFlag] = [:]

  init(messenger: FlutterBinaryMessenger) {
    flutterApi = MediaCompressorFlutterApi(binaryMessenger: messenger)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #elseif os(macOS)
      let messenger = registrar.messenger
    #endif
    let instance = NativeMediaCompressorPlugin(messenger: messenger)
    MediaCompressorHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
  }

  func compressVideo(
    taskId: Int64, request: VideoRequest,
    completion: @escaping (Result<CompressionReply, Error>) -> Void
  ) {
    let flag = StopFlag()
    stopFlags[taskId] = flag
    // Taken when the task is queued, not when it starts, so the app is not
    // suspended between one queued video and the next.
    let backgroundTime = BackgroundTime(name: "Video compression") {
      flag.set(.interrupted, "the system ended the background time")
    }
    let flutterApi = self.flutterApi
    videoQueue.addOperation { [weak self] in
      let transcoder = VideoTranscoder(request: request, stopRequest: flag.request) { progress in
        DispatchQueue.main.async {
          flutterApi.onProgress(taskId: taskId, progress: progress) { _ in }
        }
      }
      let reply = transcoder.run()
      DispatchQueue.main.async {
        // After a hot restart a new task may reuse this id while this one is
        // still finishing; its flag must stay.
        if self?.stopFlags[taskId] === flag { self?.stopFlags[taskId] = nil }
        completion(.success(reply))
        backgroundTime.end()
      }
    }
  }

  func compressImage(
    request: ImageRequest, completion: @escaping (Result<CompressionReply, Error>) -> Void
  ) {
    imageQueue.addOperation {
      let reply = ImageCodec.compress(request)
      DispatchQueue.main.async { completion(.success(reply)) }
    }
  }

  func cancel(taskId: Int64) throws {
    stopFlags[taskId]?.set(.cancelled)
  }

  func setForegroundNotification(notification: ForegroundNotification?) throws {}

  func probeImage(source: String, completion: @escaping (Result<ImageProbe?, Error>) -> Void) {
    imageQueue.addOperation {
      let probe = ImageCodec.probe(source)
      DispatchQueue.main.async { completion(.success(probe)) }
    }
  }

  func probeVideo(source: String, completion: @escaping (Result<VideoProbe?, Error>) -> Void) {
    Task.detached(priority: .userInitiated) {
      let probe = await MediaAsset.probe(source)
      DispatchQueue.main.async { completion(.success(probe)) }
    }
  }

  func videoThumbnail(
    request: ThumbnailRequest, completion: @escaping (Result<CompressionReply, Error>) -> Void
  ) {
    imageQueue.addOperation {
      let reply = VideoThumbnail.capture(request)
      DispatchQueue.main.async { completion(.success(reply)) }
    }
  }
}

/// Asks a running task to stop and says how it should answer. The first
/// request wins.
final class StopFlag {
  private let lock = NSLock()
  private var reply: CompressionReply?

  func set(_ status: CompressionStatus, _ message: String? = nil) {
    lock.lock()
    if reply == nil { reply = .status(status, message) }
    lock.unlock()
  }

  func request() -> CompressionReply? {
    lock.lock()
    defer { lock.unlock() }
    return reply
  }
}
