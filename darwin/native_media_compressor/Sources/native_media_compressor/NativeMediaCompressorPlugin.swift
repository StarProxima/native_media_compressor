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
  private var cancelFlags: [Int64: CancelFlag] = [:]

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
    let flag = CancelFlag()
    cancelFlags[taskId] = flag
    let flutterApi = self.flutterApi
    videoQueue.addOperation { [weak self] in
      let transcoder = VideoTranscoder(request: request, isCancelled: flag.isSet) { progress in
        DispatchQueue.main.async {
          flutterApi.onProgress(taskId: taskId, progress: progress) { _ in }
        }
      }
      let reply = transcoder.run()
      DispatchQueue.main.async {
        self?.cancelFlags[taskId] = nil
        completion(.success(reply))
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
    cancelFlags[taskId]?.set()
  }

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
}

final class CancelFlag {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  func isSet() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
