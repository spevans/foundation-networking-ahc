// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

#if canImport(SwiftFoundation)
    import SwiftFoundation
#else
    import Foundation
#endif
import AsyncHTTPClient
import NIOHTTP1
import NIO
import NIOFoundationCompat


private let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: .init(decompression: .enabled(limit: .none)))


internal class _HTTPURLProtocol: URLProtocol {

    private var httpClientRequest: HTTPClient.Request
    private var httpClientTask: HTTPClient.Task<Void>? = nil

    // Convert a URLRequest to an AHC HTTPClient.Request
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

        var _headers: [(String, String)] = (request.allHTTPHeaderFields ?? [:]).reduce(into: []) { target, value in
            target.append((value.key, value.value))
        }

        let body: HTTPClient.Body?
        if let bodyData = request.httpBody {
            body = .data(bodyData)
        } else if let bodyStream = request.httpBodyStream {
            body = .stream { streamWriter in

                let promise = httpClient.eventLoopGroup.next().makePromise(of: Void.self)
                DispatchQueue(label: "stream-body").async {
                    bodyStream.open()
                    guard bodyStream.hasBytesAvailable else { return }
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                    defer { buffer.deallocate() }

                    while bodyStream.hasBytesAvailable {
                        let count = bodyStream.read(buffer, maxLength: 1024)
                        let bufferPointer = UnsafeMutableBufferPointer(start: buffer, count: count)
                        _ = streamWriter.write(.byteBuffer(ByteBuffer(bytes: bufferPointer)))
                    }
                    streamWriter.write(.byteBuffer(ByteBuffer())).cascade(to: promise)
                }
                return promise.futureResult
            }
        } else {
             body = nil
        }

        if body != nil && (request.httpMethod == "POST") && (request.value(forHTTPHeaderField: "Content-Type") == nil) {
            _headers.append(("Content-Type", "application/x-www-form-urlencoded"))
        }

        let headers = NIOHTTP1.HTTPHeaders(_headers)

        return try! HTTPClient.Request(url: request.url!, method: method!, headers: headers, body: body)
    }

    public required init(task: URLSessionTask, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        self.httpClientRequest = _HTTPURLProtocol.httpRequest(from: task.originalRequest!)


        super.init(request: task.originalRequest!, cachedResponse: cachedResponse, client: client)
        self.task = task
    }

    public required init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        fatalError("TODO")
//        self.httpClientRequest = _HTTPURLProtocol.httpRequest(from: request)
//        super.init(request: request, cachedResponse: cachedResponse, client: client)
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
        guard let task = self.task else { return }

        switch task.delegateBehaviour {
            case .callDelegate:
                self.httpClientTask = httpClient.execute(request: self.httpClientRequest,
                                                         delegate: _HTTPClientDelegate(task: task),
                                                         deadline: deadline)

            case .dataCompletionHandler(let handler):
                self.httpClientTask = httpClient.execute(request: self.httpClientRequest,
                                                         delegate: _HTTPClientCompletionDelegate(task: task, handler: handler),
                                                         deadline: deadline)

            case .downloadCompletionHandler(let handler):
                fatalError()
        }
    }

    override func stopLoading() {
        self.httpClientTask?.cancel()
    }
}
