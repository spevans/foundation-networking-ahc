//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if canImport(SwiftFoundation)
    import SwiftFoundation
#else
    import Foundation
#endif

public struct URLRequest: Equatable, Hashable {
    public typealias ReferenceType = NSURLRequest
    public typealias CachePolicy = NSURLRequest.CachePolicy
    public typealias NetworkServiceType = NSURLRequest.NetworkServiceType

    /*
     NSURLRequest has a fragile ivar layout that prevents the swift subclass approach here, so instead we keep an always mutable copy
     */

    /// Creates and initializes a URLRequest with the given URL and cache policy.
    /// - parameter url: The URL for the request.
    /// - parameter cachePolicy: The cache policy for the request. Defaults to `.useProtocolCachePolicy`
    /// - parameter timeoutInterval: The timeout interval for the request. See the commentary for the `timeoutInterval` for more information on timeout intervals. Defaults to 60.0
    public init(url: URL, cachePolicy: CachePolicy = .useProtocolCachePolicy, timeoutInterval: TimeInterval = 60.0) {
        self.url = url
        self.cachePolicy = cachePolicy
        self._timeoutInterval = timeoutInterval
    }
    
    fileprivate init(_bridged request: NSURLRequest) {
        self.url = request.url
        self.mainDocumentURL = request.mainDocumentURL
        self.cachePolicy = request.cachePolicy
        self.timeoutInterval = request.timeoutInterval
        self.httpMethod = request.httpMethod
        self.allHTTPHeaderFields = request.allHTTPHeaderFields
        self._body = request._body
        self.networkServiceType = request.networkServiceType
        self.allowsCellularAccess = request.allowsCellularAccess
        self.httpShouldHandleCookies = request.httpShouldHandleCookies
        self.httpShouldUsePipelining = request.httpShouldUsePipelining
    }
    
    /// The URL of the receiver.
    public var url: URL?
    
    /// The cache policy of the receiver.
    public var cachePolicy: CachePolicy

    //URLRequest.timeoutInterval should be given precedence over the URLSessionConfiguration.timeoutIntervalForRequest regardless of the value set,
    // if it has been set at least once. Even though the default value is 60 ,if the user sets URLRequest.timeoutInterval
    // to explicitly 60 then the precedence should be given to URLRequest.timeoutInterval.
    internal var isTimeoutIntervalSet = false
    
    /// Returns the timeout interval of the receiver.
    /// - discussion: The timeout interval specifies the limit on the idle
    /// interval allotted to a request in the process of loading. The "idle
    /// interval" is defined as the period of time that has passed since the
    /// last instance of load activity occurred for a request that is in the
    /// process of loading. Hence, when an instance of load activity occurs
    /// (e.g. bytes are received from the network for a request), the idle
    /// interval for a request is reset to 0. If the idle interval ever
    /// becomes greater than or equal to the timeout interval, the request
    /// is considered to have timed out. This timeout interval is measured
    /// in seconds.
    private var _timeoutInterval: TimeInterval = 60.0
    public var timeoutInterval: TimeInterval {
        get { _timeoutInterval }
        set {
            _timeoutInterval = newValue
            isTimeoutIntervalSet = true
        }
    }
    
    /// The main document URL associated with this load.
    /// - discussion: This URL is used for the cookie "same domain as main
    /// document" policy.
    public var mainDocumentURL: URL?
    
    /// The URLRequest.NetworkServiceType associated with this request.
    /// - discussion: This will return URLRequest.NetworkServiceType.default for requests that have
    /// not explicitly set a networkServiceType
    public var networkServiceType: NetworkServiceType = .default
    
    /// `true` if the receiver is allowed to use the built in cellular radios to
    /// satisfy the request, `false` otherwise.
    public var allowsCellularAccess: Bool = true
    
    /// The HTTP request method of the receiver.
    internal var _httpMethod: String? = "GET"
    public var httpMethod: String? {
        get { _httpMethod }
        set {
            if let method = newValue {
                ["GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT"].forEach {
                    if $0 == method.uppercased() {
                        _httpMethod = method
                        return
                    }
                }
                _httpMethod = method
            } else {
                _httpMethod = "GET"
            }
        }
    }
    
    /// A dictionary containing all the HTTP header fields of the
    /// receiver.
    public var allHTTPHeaderFields: [String : String]?

    /// The value which corresponds to the given header
    /// field. Note that, in keeping with the HTTP RFC, HTTP header field
    /// names are case-insensitive.
    /// - parameter field: the header field name to use for the lookup (case-insensitive).
    public func value(forHTTPHeaderField field: String) -> String? {
        guard let f = allHTTPHeaderFields else { return nil }
        return existingHeaderField(field, inHeaderFields: f)?.1
    }
    
    /// If a value was previously set for the given header
    /// field, that value is replaced with the given value. Note that, in
    /// keeping with the HTTP RFC, HTTP header field names are
    /// case-insensitive.
    public mutating func setValue(_ value: String?, forHTTPHeaderField field: String) {
        // Store the field name capitalized to match native Foundation
        let capitalizedFieldName = field.capitalized
        var f: [String : String] = allHTTPHeaderFields ?? [:]
        if let old = existingHeaderField(capitalizedFieldName, inHeaderFields: f) {
            f.removeValue(forKey: old.0)
        }
        f[capitalizedFieldName] = value
        allHTTPHeaderFields = f
    }
    
    /// This method provides a way to add values to header
    /// fields incrementally. If a value was previously set for the given
    /// header field, the given value is appended to the previously-existing
    /// value. The appropriate field delimiter, a comma in the case of HTTP,
    /// is added by the implementation, and should not be added to the given
    /// value by the caller. Note that, in keeping with the HTTP RFC, HTTP
    /// header field names are case-insensitive.
    public mutating func addValue(_ value: String, forHTTPHeaderField field: String) {
        let capitalizedFieldName = field.capitalized
        var f: [String : String] = allHTTPHeaderFields ?? [:]
        if let old = existingHeaderField(capitalizedFieldName, inHeaderFields: f) {
            f[old.0] = old.1 + "," + value
        } else {
            f[capitalizedFieldName] = value
        }
        allHTTPHeaderFields = f
    }

    internal enum Body {
        case data(Data)
        case stream(InputStream)
    }
    internal var _body: Body?

    /// This data is sent as the message body of the request, as
    /// in done in an HTTP POST request.
    public var httpBody: Data? {
        get {
            if let body = _body {
                switch body {
                    case .data(let data):
                        return data
                    case .stream:
                        return nil
                }
            }
            return nil
        }
        set {
            if let value = newValue {
                _body = URLRequest.Body.data(value)
            } else {
                _body = nil
            }

        }
    }

    /// The stream is returned for examination only; it is
    /// not safe for the caller to manipulate the stream in any way.  Also
    /// note that the HTTPBodyStream and HTTPBody are mutually exclusive - only
    /// one can be set on a given request.  Also note that the body stream is
    /// preserved across copies, but is LOST when the request is coded via the
    /// NSCoding protocol
    public var httpBodyStream: InputStream? {
        get {
            if let body = _body {
                switch body {
                    case .data:
                        return nil
                    case .stream(let stream):
                        return stream
                }
            }
            return nil
        }
        set {
            if let value = newValue {
                _body = URLRequest.Body.stream(value)
            } else {
                _body = nil
            }
        }
    }

    /// `true` if cookies will be sent with and set for this request; otherwise `false`.
    public var httpShouldHandleCookies: Bool = true

    /// `true` if the receiver should transmit before the previous response
    /// is received.  `false` if the receiver should wait for the previous response
    /// before transmitting.
    public var httpShouldUsePipelining: Bool = true

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(mainDocumentURL)
        hasher.combine(httpMethod)
        hasher.combine(httpBodyStream)
        hasher.combine(allowsCellularAccess)
        hasher.combine(httpShouldHandleCookies)
    }
    
    public static func ==(lhs: URLRequest, rhs: URLRequest) -> Bool {
        return (lhs.url == rhs.url
                        && lhs.mainDocumentURL == rhs.mainDocumentURL
                        && lhs.httpMethod == rhs.httpMethod
                        && lhs.cachePolicy == rhs.cachePolicy
                        && lhs.httpBodyStream == rhs.httpBodyStream
                        && lhs.allowsCellularAccess == rhs.allowsCellularAccess
                        && lhs.httpShouldHandleCookies == rhs.httpShouldHandleCookies)
    }
    
    var protocolProperties: [String: Any] = [:]
}

extension URLRequest : CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        if let u = url {
            return u.description
        } else {
            return "url: nil"
        }
    }

    public var debugDescription: String {
        return self.description
    }

    public var customMirror: Mirror {
        var c: [(label: String?, value: Any)] = []
        c.append((label: "url", value: url as Any))
        c.append((label: "cachePolicy", value: cachePolicy.rawValue))
        c.append((label: "timeoutInterval", value: timeoutInterval))
        c.append((label: "mainDocumentURL", value: mainDocumentURL as Any))
        c.append((label: "networkServiceType", value: networkServiceType))
        c.append((label: "allowsCellularAccess", value: allowsCellularAccess))
        c.append((label: "httpMethod", value: httpMethod as Any))
        c.append((label: "allHTTPHeaderFields", value: allHTTPHeaderFields as Any))
        c.append((label: "httpBody", value: httpBody as Any))
        c.append((label: "httpBodyStream", value: httpBodyStream as Any))
        c.append((label: "httpShouldHandleCookies", value: httpShouldHandleCookies))
        c.append((label: "httpShouldUsePipelining", value: httpShouldUsePipelining))
        return Mirror(self, children: c, displayStyle: .struct)
    }
}

extension URLRequest : _ObjectiveCBridgeable {
    public static func _getObjectiveCType() -> Any.Type {
        return NSURLRequest.self
    }

    @_semantics("convertToObjectiveC")
    public func _bridgeToObjectiveC() -> NSURLRequest {
        return NSURLRequest(from: self)
    }

    public static func _forceBridgeFromObjectiveC(_ input: NSURLRequest, result: inout URLRequest?) {
        result = URLRequest(_bridged: input)
    }

    public static func _conditionallyBridgeFromObjectiveC(_ input: NSURLRequest, result: inout URLRequest?) -> Bool {
        result = URLRequest(_bridged: input)
        return true
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSURLRequest?) -> URLRequest {
        var result: URLRequest? = nil
        _forceBridgeFromObjectiveC(source!, result: &result)
        return result!
    }
}
