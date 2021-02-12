// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

#if canImport(SwiftFoundation)
    import SwiftFoundation
#else
    import Foundation
#endif
import AsyncHTTPClient
import NIOHTTP1
import NIO

// For tasks with a delegate set.

internal class _HTTPClientDelegate: HTTPClientResponseDelegate {
    typealias Response = Void
    private weak var sessionTask: URLSessionTask?

    private var httpUrlResponse: HTTPURLResponse?
    private var lastHeadSent: HTTPRequestHead?
    private var receivedBodyData: Data?
    private var totalBytesSent: Int64 = 0

    init(task: URLSessionTask?) {
        self.sessionTask = task
    }


    func didSendRequestHead(task: HTTPClient.Task<Void>, _ head: HTTPRequestHead) {
        lastHeadSent = head
    }

    func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {
        let bytesSent = Int64(part.readableBytes)
        totalBytesSent += bytesSent

        if let sessionTask = sessionTask,
           let session = sessionTask.session as? URLSession,
           let urlSessionDelegate = session.delegate as? URLSessionTaskDelegate {
            urlSessionDelegate.urlSession(session, task: sessionTask, didSendBodyData: bytesSent,
                                          totalBytesSent: sessionTask.countOfBytesSent,
                                          totalBytesExpectedToSend: sessionTask.countOfBytesExpectedToSend)

        }

    }

    func didSendRequest(task: HTTPClient.Task<Response>) {

    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        if let headSent = lastHeadSent {
            let headers: [String: String] = head.headers.reduce(into: [:]) { target, header in
                target[header.name] = header.value
            }
            let url = URL(string: headSent.uri)!
            let response = HTTPURLResponse(url: url,
                                                statusCode: Int(head.status.code),
                                                httpVersion: head.version.description,
                                                headerFields: headers)

            httpUrlResponse = response

            if let dataTask = sessionTask as? URLSessionDataTask, let session = dataTask.session as? URLSession,
               let urlSessionDelegate = session.delegate as? URLSessionDataDelegate {
               let response = httpUrlResponse! as URLResponse
                urlSessionDelegate.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: { _ in })
            }
            httpUrlResponse = response

        }
        return task.eventLoop.makeSucceededFuture(())
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        // this is executed when we receive parts of the response body, could be called zero or more times

        receivedBodyData = (receivedBodyData ?? Data()) + Data(buffer: buffer)

        if let dataTask = sessionTask as? URLSessionDataTask,
           let session = dataTask.session as? URLSession,
           let urlSessionDelegate = session.delegate as? URLSessionDataDelegate {
            urlSessionDelegate.urlSession(session, dataTask: dataTask, didReceive: Data(buffer: buffer))
        }

        //count += buffer.readableBytes
        // in case backpressure is needed, all reads will be paused until returned future is resolved
        return task.eventLoop.makeSucceededFuture(())
    }

    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {

    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws -> Void {

        guard let session = sessionTask?.session as? URLSession else { return }

        if let sessionTask = sessionTask, let urlSessionDelegate = sessionTask.session.delegate as? URLSessionTaskDelegate {
            urlSessionDelegate.urlSession(session, task: sessionTask, didCompleteWithError: nil)
        }

    }
}
