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

private let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)

internal class _HTTPURLProtocol: URLProtocol {

    public required init(task: URLSessionTask, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        super.init(request: task.originalRequest!, cachedResponse: cachedResponse, client: client)
        self.task = task
    }

    public required init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
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
    }

    override func stopLoading() {
    }
}
