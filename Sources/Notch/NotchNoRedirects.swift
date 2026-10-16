import Foundation

/// Refuses every redirect, so a request never follows one to another address: T3's bearer token stays on loopback,
/// and the update check stays one request to GitHub.
final class NotchNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
