import Foundation
import AVFoundation

/// Normalizes HTTP byte-range responses for AVFoundation. Google Drive returns
/// a small Content-Length for each 206 response (correct HTTP behaviour), but
/// CoreMedia occasionally treats that value as the complete movie size and
/// rejects multi-gigabyte MP4s. Supplying the response through AVAsset's
/// resource loader lets us explicitly report the total size from Content-Range.
final class RemoteVideoAssetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private final class Context {
        let request: AVAssetResourceLoadingRequest
        var nextOffset: Int64
        let finalOffset: Int64
        init(_ request: AVAssetResourceLoadingRequest, start: Int64, finalOffset: Int64) {
            self.request = request
            nextOffset = start
            self.finalOffset = finalOffset
        }
    }

    private let sourceURL: URL
    private let delegateQueue = DispatchQueue(label: "app.livewall.remote-video-loader")
    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]
    private let chunkSize: Int64 = 4 * 1024 * 1024
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    lazy var asset: AVURLAsset = {
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)!
        components.scheme = "livewall-video"
        let value = AVURLAsset(url: components.url!)
        value.resourceLoader.setDelegate(self, queue: delegateQueue)
        return value
    }()

    init(url: URL) {
        sourceURL = url
        super.init()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // AVFoundation commonly asks for content metadata before it asks for
        // bytes. Satisfy that request with a two-byte range so we can read the
        // total size from Content-Range; rejecting it makes the item appear as
        // unsupported before playback has a chance to begin.
        let dataRequest = loadingRequest.dataRequest
        let start = dataRequest.map { $0.currentOffset > 0 ? $0.currentOffset : $0.requestedOffset } ?? 0
        let requestedLength = dataRequest.map { max(Int64($0.requestedLength), 1) } ?? 2
        let finalOffset = start + requestedLength - 1
        let context = Context(loadingRequest, start: start, finalOffset: finalOffset)
        startNextTask(for: context)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        let taskID = contexts.first(where: { $0.value.request === loadingRequest })?.key
        if let taskID { contexts.removeValue(forKey: taskID) }
        lock.unlock()
        if let taskID { session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == taskID }?.cancel() } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let context = context(for: dataTask.taskIdentifier),
              let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            completionHandler(.cancel)
            return
        }

        if let info = context.request.contentInformationRequest {
            info.contentType = "public.mpeg-4"
            info.isByteRangeAccessSupported = true
            if let range = response.value(forHTTPHeaderField: "Content-Range"),
               let totalText = range.split(separator: "/").last,
               let total = Int64(totalText) {
                info.contentLength = total
            } else {
                info.contentLength = response.expectedContentLength
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        context(for: dataTask.taskIdentifier)?.request.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock(); let context = contexts.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let context else { return }
        if let error { context.request.finishLoading(with: error) }
        else if context.nextOffset <= context.finalOffset && !context.request.isCancelled {
            startNextTask(for: context)
        } else {
            context.request.finishLoading()
        }
    }

    func invalidate() {
        session.invalidateAndCancel()
        lock.lock(); let pending = contexts.values; contexts.removeAll(); lock.unlock()
        pending.forEach { $0.request.finishLoading(with: URLError(.cancelled)) }
    }

    private func context(for taskID: Int) -> Context? {
        lock.lock(); defer { lock.unlock() }
        return contexts[taskID]
    }

    private func startNextTask(for context: Context) {
        let start = context.nextOffset
        let end = min(context.finalOffset, start + chunkSize - 1)
        context.nextOffset = end + 1
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("LiveWall/1.6", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        lock.lock(); contexts[task.taskIdentifier] = context; lock.unlock()
        task.resume()
    }
}
