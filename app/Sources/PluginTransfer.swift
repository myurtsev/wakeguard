import Foundation

final class PluginTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let limit: Int
    private let completion: (Result<Data, Error>) -> Void
    private var data = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private let taskLock = NSLock()

    init(request: URLRequest, limit: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        self.request = request
        self.limit = limit
        self.completion = completion
        super.init()
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        taskLock.lock()
        self.session = session
        self.task = task
        taskLock.unlock()
        task.resume()
    }

    func cancel() {
        taskLock.lock()
        let task = task
        taskLock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward plugin headers or settings to a redirect destination.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url?.scheme == "https" else {
            failure = PluginError.invalid("The server did not return a successful HTTPS response. Redirects are not followed.")
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            failure = PluginError.invalid("Server response exceeds the size limit.")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= limit else {
            failure = PluginError.invalid("Server response exceeds the size limit.")
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Data, Error>
        if let failure { result = .failure(failure) }
        else if error != nil { result = .failure(PluginError.invalid("Network request failed or was cancelled.")) }
        else { result = .success(data) }
        completion(result)
        session.finishTasksAndInvalidate()
        taskLock.lock()
        self.session = nil
        self.task = nil
        taskLock.unlock()
    }
}
