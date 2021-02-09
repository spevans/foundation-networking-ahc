// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

import Foundation
import Dispatch
import AsyncHTTPClient
import NIOHTTP1
import NIO
import NIOFoundationCompat


private let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)

private class HTTPClientDelegate: HTTPClientResponseDelegate {
    typealias Response = Void
    private weak var sessionTask: URLSessionTask?
    private weak var sessionDelegate: URLSessionDelegate?
    private var receivedBodyData = Data()

    init(task: URLSessionTask?, sessionDelegate: URLSessionDelegate? = nil) {
        self.sessionTask = task
        self.sessionDelegate = sessionDelegate
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        // this is executed when we receive parts of the response body, could be called zero or more times

        receivedBodyData += Data(buffer: buffer)

        //count += buffer.readableBytes
        // in case backpressure is needed, all reads will be paused until returned future is resolved
        return task.eventLoop.makeSucceededFuture(())
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws -> Void {

        if let dataTask = sessionTask as? URLSessionDataTask,
           let session = sessionTask?.session as? URLSession,
           let urlSessionDelegate = sessionDelegate as? URLSessionDataDelegate {
            urlSessionDelegate.urlSession(session, dataTask: dataTask, didReceive: receivedBodyData)
        }
    }
}


internal class _HTTPURLProtocol: URLProtocol {

    private var httpClientRequest: HTTPClient.Request
    private var httpClientDelegate: HTTPClientDelegate
    private var httpClientTask: HTTPClient.Task<Void>? = nil

    private static func httpRequest(from request: URLRequest) -> HTTPClient.Request {
        let method: NIOHTTP1.HTTPMethod? = {
            switch request.httpMethod {
                case "GET": return .GET
                case "POST": return .POST
                case "DELETE": return .DELETE
                case "HEAD": return .HEAD
                case "PUT": return .PUT
                default: return nil
            }
        }()

        let _headers: [(String, String)] = (request.allHTTPHeaderFields ?? [:]).reduce(into: []) { target, value in
            target.append((value.key, value.value))
        }

        let headers = NIOHTTP1.HTTPHeaders(_headers)
        let body: HTTPClient.Body?
        if let bodyData = request.httpBody {
            body = .data(bodyData)
        } else if let bodyStream = request.httpBodyStream {
            fatalError("Cant handle a stream")
        } else {
             body = nil
        }

        return try! HTTPClient.Request(url: request.url!, method: method!, headers: headers, body: body)
    }

    public required init(task: URLSessionTask, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        self.httpClientRequest = _HTTPURLProtocol.httpRequest(from: task.originalRequest!)
        self.httpClientDelegate = HTTPClientDelegate(task: task, sessionDelegate: task.session.delegate)
        super.init(request: task.originalRequest!, cachedResponse: cachedResponse, client: client)
        self.task = task
    }

    public required init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        self.httpClientRequest = _HTTPURLProtocol.httpRequest(from: request)
        self.httpClientDelegate = HTTPClientDelegate(task: nil, sessionDelegate: nil)
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.url?.scheme == "http" || request.url?.scheme == "https" else { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let timeout = Int64(task?.originalRequest?.timeoutInterval ?? 30)
        let deadline = NIO.NIODeadline.now() + .seconds(timeout)
        let task = httpClient.execute(request: self.httpClientRequest,
                                       delegate: self.httpClientDelegate,
                                       deadline: deadline)
    }

    override func stopLoading() {
        self.httpClientTask?.cancel()
    }
}
