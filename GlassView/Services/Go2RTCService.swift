import Foundation
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "Go2RTC")

final class Go2RTCService: Sendable {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func fetchStreams() async throws -> [Stream] {
        let url = baseURL.appendingPathComponent("api/streams")
        log.info("GET \(url.absoluteString)")

        let (data, response) = try await Self.session.data(from: url)
        let http = response as? HTTPURLResponse
        log.info("Response status: \(http?.statusCode ?? -1)")

        guard let http, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("Bad response: status=\(http?.statusCode ?? -1) body=\(body)")
            throw Go2RTCError.invalidResponse
        }

        let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
        log.debug("Response body: \(bodyStr)")

        let jsonObj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let streamNames = jsonObj.keys.sorted()
        log.info("Parsed \(streamNames.count) streams: \(streamNames)")
        return streamNames.map { Stream(name: $0) }
    }

    func negotiateWebRTC(streamName: String, offerSDP: String) async throws -> String {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/webrtc"),
            resolvingAgainstBaseURL: false
        ) else {
            throw Go2RTCError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "src", value: streamName)]

        guard let url = components.url else {
            throw Go2RTCError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = offerSDP.data(using: .utf8)

        log.info("POST \(url.absoluteString) (SDP offer \(offerSDP.count) bytes)")

        let (data, response) = try await Self.session.data(for: request)
        let http = response as? HTTPURLResponse
        log.info("WebRTC negotiate response: status=\(http?.statusCode ?? -1)")

        guard let http, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("Negotiation failed: status=\(http?.statusCode ?? -1) body=\(body)")
            throw Go2RTCError.negotiationFailed
        }

        guard let answerSDP = String(data: data, encoding: .utf8) else {
            log.error("Could not decode answer SDP as UTF-8")
            throw Go2RTCError.invalidResponse
        }
        log.info("Got SDP answer (\(answerSDP.count) bytes)")
        return answerSDP
    }
}

enum Go2RTCError: LocalizedError {
    case invalidResponse
    case negotiationFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Could not reach go2rtc server"
        case .negotiationFailed: return "Stream negotiation failed"
        }
    }
}
