// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

import Foundation
import AsyncHTTPClient
import NIOHTTP1
import NIO


// For tasks with a completion handler where only a few calls to the delegate are made, usually authentication.

internal class _HTTPClientCompletionDelegate: HTTPClientResponseDelegate {
    typealias Response = Void
    private weak var sessionTask: URLSessionTask?
    private let handler: URLSession._TaskRegistry.DataTaskCompletion

    private var httpUrlResponse: HTTPURLResponse?
    private var lastHeadSent: HTTPRequestHead?
    private var receivedBodyData: Data?

   // private var receivedBodyData = Data()

    init(task: URLSessionTask?, handler: @escaping URLSession._TaskRegistry.DataTaskCompletion) {
        self.sessionTask = task
        self.handler = handler
    }

    func didSendRequestHead(task: HTTPClient.Task<Void>, _ head: HTTPRequestHead) {
        lastHeadSent = head
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        if let headSent = lastHeadSent {
            let headers: [String: String] = head.headers.reduce(into: [:]) { target, header in
                target[header.name] = header.value
            }
            let url = URL(string: headSent.uri)!
            httpUrlResponse = HTTPURLResponse(url: url,
                                                statusCode: Int(head.status.code),
                                                httpVersion: head.version.description,
                                                headerFields: headers)
        }
        return task.eventLoop.makeSucceededFuture(())
    }

    // this is executed when we receive parts of the response body, could be called zero or more times
    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {

        receivedBodyData = (receivedBodyData ?? Data()) + Data(buffer: buffer)

        // in case backpressure is needed, all reads will be paused until returned future is resolved
        return task.eventLoop.makeSucceededFuture(())
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws -> Void {

        self.handler(receivedBodyData, httpUrlResponse, nil)
    }
}
