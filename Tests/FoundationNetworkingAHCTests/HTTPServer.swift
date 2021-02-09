// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//


// This is a very rudimentary HTTP server written plainly for testing URLSession.
// It listens for connections and then processes each client connection in a Dispatch
// queue using async().

#if canImport(FoundationNetworkingAHC)
@testable import class FoundationNetworkingAHC.CachedURLResponse
@testable import class FoundationNetworkingAHC.HTTPCookie
@testable import struct FoundationNetworkingAHC.HTTPCookiePropertyKey
@testable import class FoundationNetworkingAHC.HTTPCookieStorage
@testable import class FoundationNetworkingAHC.HTTPURLResponse
@testable import class FoundationNetworkingAHC.NSMutableURLRequest
@testable import class FoundationNetworkingAHC.NSURLRequest
@testable import class FoundationNetworkingAHC.URLAuthenticationChallenge
@testable import protocol FoundationNetworkingAHC.URLAuthenticationChallengeSender
@testable import class FoundationNetworkingAHC.URLCache
@testable import class FoundationNetworkingAHC.URLCredential
@testable import class FoundationNetworkingAHC.URLCredentialStorage
@testable import class FoundationNetworkingAHC.URLProtectionSpace
@testable import class FoundationNetworkingAHC.URLProtocol
@testable import protocol FoundationNetworkingAHC.URLProtocolClient
@testable import struct FoundationNetworkingAHC.URLRequest
@testable import class FoundationNetworkingAHC.URLResponse
@testable import class FoundationNetworkingAHC.URLSession
@testable import class FoundationNetworkingAHC.URLSessionConfiguration
@testable import protocol FoundationNetworkingAHC.URLSessionDataDelegate
@testable import class FoundationNetworkingAHC.URLSessionDataTask
@testable import protocol FoundationNetworkingAHC.URLSessionDelegate
@testable import protocol FoundationNetworkingAHC.URLSessionDownloadDelegate
@testable import class FoundationNetworkingAHC.URLSessionDownloadTask
@testable import protocol FoundationNetworkingAHC.URLSessionStreamDelegate
@testable import class FoundationNetworkingAHC.URLSessionStreamTask
@testable import class FoundationNetworkingAHC.URLSessionTask
@testable import protocol FoundationNetworkingAHC.URLSessionTaskDelegate
@testable import class FoundationNetworkingAHC.URLSessionTaskMetrics
@testable import class FoundationNetworkingAHC.URLSessionTaskTransactionMetrics
@testable import class FoundationNetworkingAHC.URLSessionUploadTask
#endif

import Dispatch
import XCTest
import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat


private let serverDebug = (ProcessInfo.processInfo.environment["SCLF_HTTP_SERVER_DEBUG"] == "YES")

private func debugLog(_ msg: String) {
    if serverDebug {
        NSLog(msg)
    }
}

public let globalDispatchQueue = DispatchQueue.global()
public let dispatchQueueMake: (String) -> DispatchQueue = { DispatchQueue.init(label: $0) }
public let dispatchGroupMake: () -> DispatchGroup = DispatchGroup.init



struct _HTTPRequest: CustomStringConvertible {
    enum Method : String {
        case HEAD
        case GET
        case POST
        case PUT
        case DELETE
    }

    enum Error: Swift.Error {
        case invalidURI
        case invalidMethod
        case headerEndNotFound
    }

    let method: Method
    let uri: String
    private(set) var headers: [String] = []
    private(set) var parameters: [String: String] = [:]
    var messageBody: String?
    var messageData: Data?
    var description: String { return "\(method) \(uri)" }


    public init(reqHead: HTTPRequestHead) throws {
        self.headers.append("\(reqHead.method.rawValue) \(reqHead.uri) \(reqHead.version.description)")
        for header in reqHead.headers {
            self.headers.append("\(header.name): \(header.value)")
        }

        switch reqHead.method {
            case .GET: method = Method.GET
            case .PUT: method = Method.PUT
            case .HEAD: method = Method.HEAD
            case .POST: method = Method.POST
            case .DELETE: method = Method.DELETE

            default: throw Error.invalidMethod
        }

        let params = reqHead.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true)
        if params.count > 1 {
            for arg in params[1].split(separator: "&", omittingEmptySubsequences: true) {
                let keyValue = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard !keyValue.isEmpty else { continue }
                guard let key = keyValue[0].removingPercentEncoding else {
                    throw Error.invalidURI
                }
                guard let value = (keyValue.count > 1) ? keyValue[1].removingPercentEncoding : "" else {
                    throw Error.invalidURI
                }
                self.parameters[key] = value
            }
        }

        self.uri = String(params[0])
    }

    public func getCommaSeparatedHeaders() -> String {
        var allHeaders = ""
        for header in headers {
            allHeaders += header + ","
        }
        return allHeaders
    }

    public func getHeader(for key: String) -> String? {
        let lookup = key.lowercased()
        for header in headers {
            let parts = header.components(separatedBy: ":")
            if parts[0].lowercased() == lookup {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            }
        }
        return nil
    }

    public func headersAsJSON() throws -> Data {
        var headerDict: [String: String] = [:]
        for header in headers {
            if header.hasPrefix(method.rawValue) {
                headerDict["uri"] = header
                continue
            }
            let parts = header.components(separatedBy: ":")
            if parts.count > 1 {
                headerDict[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            }
        }

        // Include the body as a Base64 Encoded entry
        if let bodyData = messageData ?? messageBody?.data(using: .utf8) {
            headerDict["x-base64-body"] = bodyData.base64EncodedString()
        }
        return try JSONSerialization.data(withJSONObject: headerDict, options: .sortedKeys)
    }
}


struct _HTTPResponse: CustomStringConvertible {
    enum Response: Int {
        case OK = 200
        case FOUND = 302
        case BAD_REQUEST = 400
        case NOT_FOUND = 404
        case METHOD_NOT_ALLOWED = 405
        case SERVER_ERROR = 500

        func asNIO() -> HTTPResponseStatus {
            switch self {
                case .OK: return .ok
                case .FOUND: return .found
                case .BAD_REQUEST: return .badRequest
                case .NOT_FOUND: return .notFound
                case .METHOD_NOT_ALLOWED: return .methodNotAllowed
                case .SERVER_ERROR: return .internalServerError
            }
        }
    }

    let response: HTTPResponseStatus
    private(set) var headers: [String]
    public let bodyData: Data
    var description: String {
        let _h = headers.joined(separator: "\n")
        return "\(response.code) \(_h)"
    }

    public init(response: Response, headers: [String] = [], bodyData: Data) {
        self.response = HTTPResponseStatus(statusCode: response.rawValue)
        self.headers = headers
        self.bodyData = bodyData

        for header in headers {
            if header.lowercased().hasPrefix("content-length") {
                return
            }
        }
        self.headers.append("Content-Length: \(bodyData.count)")
    }

    public init(responseCode: Int, headers: [String] = [], bodyData: Data = Data()) {
        self.response = HTTPResponseStatus(statusCode: responseCode)
        self.headers = headers
        self.bodyData = bodyData
        for header in headers {
            if header.lowercased().hasPrefix("content-length") {
                return
            }
        }
        self.headers.append("Content-Length: \(bodyData.count)")
    }

    public init(response: Response, headers: String, bodyData: Data) {
        let headers = headers.split(separator: "\r\n").map { String($0) }
        self.init(response: response, headers: headers, bodyData: bodyData)
    }

    public init(response: Response, body: String) throws {
        guard let data = body.data(using: .utf8) else {
            throw InternalServerError.badBody
        }
        self.init(response: response, bodyData: data)
    }

    public init(response: Response, headers: [String] = [], body: String = "") throws {
        guard let data = body.data(using: .utf8) else {
            throw InternalServerError.badBody
        }
        self.init(response: response, headers: headers, bodyData: data)
    }

    public var header: String {
        let responseCodeName = HTTPURLResponse.localizedString(forStatusCode: Int(response.code))
        let statusLine = "HTTP/1.1 \(response.code) \(responseCodeName)"
        let header = headers.joined(separator: "\r\n")
        return statusLine + (header != "" ? "\r\n\(header)" : "") + "\r\n\r\n"
    }

    mutating func addHeader(_ header: String) {
        headers.append(header)
    }
}

internal final class TestURLSessionServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    var request: _HTTPRequest!

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
            case .head(let header):
                print(header.uri)
                request = try! _HTTPRequest(reqHead: header)

            case .body(var buffer):
                if let data = buffer.readData(length: buffer.readableBytes) {
                    if request.messageData == nil {
                        request.messageData = data
                    } else {
                        request.messageData?.append(data)
                    }
                }

            case .end:
                let response = try! getResponse(request: request)
                let channel = context.channel

                let headers: [(String, String)] = response.headers.reduce(into: []) { target, header in
                    let parts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    target.append((parts[0].trimmingCharacters(in: CharacterSet.whitespaces), parts[1].trimmingCharacters(in: CharacterSet.whitespaces)))
                }

                let head = HTTPResponseHead(version: .init(major: 1, minor: 1), // header.version,
                                            status: response.response,
                                            headers: HTTPHeaders(headers))
                _ = channel.write(HTTPServerResponsePart.head(head))

                let buffer = channel.allocator.buffer(data: response.bodyData)
                _ = channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))

                let endpart = HTTPServerResponsePart.end(nil)
                _ = channel.writeAndFlush(endpart).flatMap {
                    channel.close()
                }
        }
    }

    let capitals: [String:String] = ["Nepal": "Kathmandu",
                                     "Peru": "Lima",
                                     "Italy": "Rome",
                                     "USA": "Washington, D.C.",
                                     "UnitedStates": "USA",
                                     "UnitedKingdom": "UK",
                                     "UK": "London",
                                     "country.txt": "A country is a region that is identified as a distinct national entity in political geography"]

    #if false // FIXME
    func respondWithBrokenResponses(uri: String) throws {
        let responseData: Data
        switch uri {
            case "/LandOfTheLostCities/Pompeii":
                /* this is an example of what you get if you connect to an HTTP2
                 server using HTTP/1.1. Curl interprets that as a HTTP/0.9
                 simple-response and therefore sends this back as a response
                 body. Go figure! */
                responseData = Data([
                    0x00, 0x00, 0x18, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x01, 0x00, 0x00, 0x10, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
                    0x01, 0x00, 0x05, 0x00, 0x00, 0x40, 0x00, 0x00, 0x06, 0x00,
                    0x00, 0x1f, 0x40, 0x00, 0x00, 0x86, 0x07, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
                    0x48, 0x54, 0x54, 0x50, 0x2f, 0x32, 0x20, 0x63, 0x6c, 0x69,
                    0x65, 0x6e, 0x74, 0x20, 0x70, 0x72, 0x65, 0x66, 0x61, 0x63,
                    0x65, 0x20, 0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x20, 0x6d,
                    0x69, 0x73, 0x73, 0x69, 0x6e, 0x67, 0x20, 0x6f, 0x72, 0x20,
                    0x63, 0x6f, 0x72, 0x72, 0x75, 0x70, 0x74, 0x2e, 0x20, 0x48,
                    0x65, 0x78, 0x20, 0x64, 0x75, 0x6d, 0x70, 0x20, 0x66, 0x6f,
                    0x72, 0x20, 0x72, 0x65, 0x63, 0x65, 0x69, 0x76, 0x65, 0x64,
                    0x20, 0x62, 0x79, 0x74, 0x65, 0x73, 0x3a, 0x20, 0x34, 0x37,
                    0x34, 0x35, 0x35, 0x34, 0x32, 0x30, 0x32, 0x66, 0x33, 0x33,
                    0x32, 0x66, 0x36, 0x34, 0x36, 0x35, 0x37, 0x36, 0x36, 0x39,
                    0x36, 0x33, 0x36, 0x35, 0x32, 0x66, 0x33, 0x31, 0x33, 0x32,
                    0x33, 0x33, 0x33, 0x34, 0x33, 0x35, 0x33, 0x36, 0x33, 0x37,
                    0x33, 0x38, 0x33, 0x39, 0x33, 0x30])
            case "/LandOfTheLostCities/Sodom":
                /* a technically valid HTTP/0.9 simple-response */
                responseData = ("technically, this is a valid HTTP/0.9 " +
                    "simple-response. I know it's odd but CURL supports it " +
                    "still...\r\nFind out more in those URLs:\r\n " +
                    " - https://www.w3.org/Protocols/HTTP/1.0/spec.html#Message-Types\r\n" +
                    " - https://github.com/curl/curl/issues/467\r\n").data(using: .utf8)!
            case "/LandOfTheLostCities/Gomorrah":
                /* just broken, hope that's not officially HTTP/0.9 :p */
                responseData = "HTTP/1.1\r\n\r\n\r\n".data(using: .utf8)!
            case "/LandOfTheLostCities/Myndus":
                responseData = ("HTTP/1.1 200 OK\r\n" +
                               "\r\n" +
                               "this is a body that isn't legal as it's " +
                               "neither chunked encoding nor any Content-Length\r\n").data(using: .utf8)!
            case "/LandOfTheLostCities/Kameiros":
                responseData = ("HTTP/1.1 999 Wrong Code\r\n" +
                               "illegal: status code (too large)\r\n" +
                               "\r\n").data(using: .utf8)!
            case "/LandOfTheLostCities/Dinavar":
                responseData = ("HTTP/1.1 20 Too Few Digits\r\n" +
                               "illegal: status code (too few digits)\r\n" +
                               "\r\n").data(using: .utf8)!
            case "/LandOfTheLostCities/Kuhikugu":
                responseData = ("HTTP/1.1 2000 Too Many Digits\r\n" +
                               "illegal: status code (too many digits)\r\n" +
                               "\r\n").data(using: .utf8)!
            default:
                responseData = ("HTTP/1.1 500 Internal Server Error\r\n" +
                               "case-missing-in: TestFoundation/HTTPServer.swift\r\n" +
                               "\r\n").data(using: .utf8)!
        }
        try tcpSocket.writeRawData(responseData)
    }

    func respondWithAuthResponse(request: _HTTPRequest) throws {
        let responseData: Data
        if let auth = request.getHeader(for: "authorization"),
            auth == "Basic dXNlcjpwYXNzd2Q=" {
                responseData = ("HTTP/1.1 200 OK \r\n" +
                "Content-Length: 37\r\n" +
                "Content-Type: application/json\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Access-Control-Allow-Credentials: true\r\n" +
                "Via: 1.1 vegur\r\n" +
                "Cache-Control: proxy-revalidate\r\n" +
                "Connection: keep-Alive\r\n" +
                "\r\n" +
                "{\"authenticated\":true,\"user\":\"user\"}\n").data(using: .utf8)!
        } else {
            responseData = ("HTTP/1.1 401 UNAUTHORIZED \r\n" +
                        "Content-Length: 0\r\n" +
                        "WWW-Authenticate: Basic realm=\"Fake Relam\"\r\n" +
                        "Access-Control-Allow-Origin: *\r\n" +
                        "Access-Control-Allow-Credentials: true\r\n" +
                        "Via: 1.1 vegur\r\n" +
                        "Cache-Control: proxy-revalidate\r\n" +
                        "Connection: keep-Alive\r\n" +
                        "\r\n").data(using: .utf8)!
        }
        try tcpSocket.writeRawData(responseData)
    }

    func respondWithUnauthorizedHeader() throws{
        let responseData = ("HTTP/1.1 401 UNAUTHORIZED \r\n" +
                "Content-Length: 0\r\n" +
                "Connection: keep-Alive\r\n" +
                "\r\n").data(using: .utf8)!
        try tcpSocket.writeRawData(responseData)
    }

    public func readAndRespond() throws {
        let req = try httpServer.request()
        debugLog("request: \(req)")
        if let value = req.getHeader(for: "x-pause") {
            if let wait = Double(value), wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            }
        }

        if req.uri.hasPrefix("/LandOfTheLostCities/") {
            /* these are all misbehaving servers */
            try httpServer.respondWithBrokenResponses(uri: req.uri)
        } else if req.uri == "/NSString-ISO-8859-1-data.txt" {
            // Serve this directly as binary data to avoid any String encoding conversions.
            let content = Data([0x54, 0x68, 0x69, 0x73, 0x20, 0x66, 0x69, 0x6c, 0x65, 0x20, 0x69, 0x73, 0x20, 0x65, 0x6e, 0x63,
                             0x6f, 0x64, 0x65, 0x64, 0x20, 0x61, 0x73, 0x20, 0x49, 0x53, 0x4f, 0x2d, 0x38, 0x38, 0x35, 0x39,
                             0x2d, 0x31, 0x0a, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xff, 0x0a, 0xb1, 0x0a])

            var responseData = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=ISO-8859-1\r\nContent-Length: \(content.count)\r\n\r\n".data(using: .ascii)!
            responseData.append(content)
            try httpServer.tcpSocket.writeRawData(responseData)
        } else if req.uri.hasPrefix("/auth") {
            try httpServer.respondWithAuthResponse(request: req)
        } else if req.uri.hasPrefix("/unauthorized") {
            try httpServer.respondWithUnauthorizedHeader()
        } else {
            let response = try getResponse(request: req)
            try httpServer.respond(with: response)
            debugLog("response: \(response)")
        }
    }

    #endif

    func getResponse(request: _HTTPRequest) throws -> _HTTPResponse {

        func headersAsJSONResponse() throws -> _HTTPResponse {
            return try _HTTPResponse(response: .OK, headers: ["Content-Type: application/json"], bodyData: request.headersAsJSON())
        }

        let uri = request.uri
        if uri == "/jsonBody" {
            return try headersAsJSONResponse()
        }

        if uri == "/head" {
            guard request.method == .HEAD else { return try _HTTPResponse(response: .METHOD_NOT_ALLOWED, body: "Method not allowed") }
            return try headersAsJSONResponse()
        }

        if uri == "/get" {
            guard request.method == .GET else { return try _HTTPResponse(response: .METHOD_NOT_ALLOWED, body: "Method not allowed") }
            return try headersAsJSONResponse()
        }

        if uri == "/put" {
            guard request.method == .PUT else { return try _HTTPResponse(response: .METHOD_NOT_ALLOWED, body: "Method not allowed") }
            return try headersAsJSONResponse()
        }

        if uri == "/post" {
            guard request.method == .POST else { return try _HTTPResponse(response: .METHOD_NOT_ALLOWED, body: "Method not allowed") }
            return try headersAsJSONResponse()
        }

        if uri == "/delete" {
            guard request.method == .DELETE else { return try _HTTPResponse(response: .METHOD_NOT_ALLOWED, body: "Method not allowed") }
            return try headersAsJSONResponse()
        }

        if uri.hasPrefix("/redirect/") {
            let components = uri.components(separatedBy: "/")
            if components.count >= 3, let count = Int(components[2]) {
                let newLocation = (count <= 1) ? "/jsonBody" : "/redirect/\(count - 1)"
                return try _HTTPResponse(response: .FOUND, headers: ["Location: \(newLocation)"], body: "Redirecting to \(newLocation)")
            }
        }

        if uri == "/upload" {
            if let contentLength = request.getHeader(for: "content-length") {
                let text = "Upload completed!, Content-Length: \(contentLength)"
                return try _HTTPResponse(response: .OK, body: text)
            }
            if let te = request.getHeader(for: "transfer-encoding"), te == "chunked" {
                return try _HTTPResponse(response: .OK, body: "Received Chunked request")
            } else {
                return try _HTTPResponse(response: .BAD_REQUEST, body: "Missing Content-Length")
            }
        }

        if uri == "/country.txt" {
            let text = capitals[String(uri.dropFirst())]!
            return try _HTTPResponse(response: .OK, body: text)
        }

        if uri == "/requestHeaders" {
            let text = request.getCommaSeparatedHeaders()
            return try _HTTPResponse(response: .OK, body: text)
        }

        if uri == "/emptyPost" {
            if request.getHeader(for: "Content-Type") == nil {
                return try _HTTPResponse(response: .OK, body: "")
            }
            return try _HTTPResponse(response: .NOT_FOUND, body: "")
        }

        if uri == "/requestCookies" {
            return try _HTTPResponse(response: .OK, headers: ["Set-Cookie: fr=anjd&232; Max-Age=7776000; path=/", "Set-Cookie: nm=sddf&232; Max-Age=7776000; path=/; domain=.swift.org; secure; httponly"], body: "")
        }

        if uri == "/echoHeaders" {
            let text = request.getCommaSeparatedHeaders()
            return try _HTTPResponse(response: .OK, headers: ["Content-Length: \(text.data(using: .utf8)!.count)"], body: text)
        }
        
        if uri == "/redirectToEchoHeaders" {
            return try _HTTPResponse(response: .FOUND, headers: ["location: /echoHeaders", "Set-Cookie: redirect=true; Max-Age=7776000; path=/"], body: "")
        }

        if uri == "/UnitedStates" {
            let value = capitals[String(uri.dropFirst())]!
            let text = request.getCommaSeparatedHeaders()
            let host = request.headers[1].components(separatedBy: " ")[1]
            let ip = host.components(separatedBy: ":")[0]
            let port = host.components(separatedBy: ":")[1]
            let newPort = Int(port)! + 1
            let newHost = ip + ":" + String(newPort)
            let httpResponse = try _HTTPResponse(response: .FOUND, headers: ["Location: http://\(newHost)/\(value)"], body: text)
            return httpResponse 
        }

        if uri == "/DTDs/PropertyList-1.0.dtd" {
            let dtd = """
    <!ENTITY % plistObject "(array | data | date | dict | real | integer | string | true | false )" >
    <!ELEMENT plist %plistObject;>
    <!ATTLIST plist version CDATA "1.0" >

    <!-- Collections -->
    <!ELEMENT array (%plistObject;)*>
    <!ELEMENT dict (key, %plistObject;)*>
    <!ELEMENT key (#PCDATA)>

    <!--- Primitive types -->
    <!ELEMENT string (#PCDATA)>
    <!ELEMENT data (#PCDATA)> <!-- Contents interpreted as Base-64 encoded -->
    <!ELEMENT date (#PCDATA)> <!-- Contents should conform to a subset of ISO 8601 (in particular, YYYY '-' MM '-' DD 'T' HH ':' MM ':' SS 'Z'.  Smaller units may be omitted with a loss of precision) -->

    <!-- Numerical primitives -->
    <!ELEMENT true EMPTY>  <!-- Boolean constant true -->
    <!ELEMENT false EMPTY> <!-- Boolean constant false -->
    <!ELEMENT real (#PCDATA)> <!-- Contents should represent a floating point number matching ("+" | "-")? d+ ("."d*)? ("E" ("+" | "-") d+)? where d is a digit 0-9.  -->
    <!ELEMENT integer (#PCDATA)> <!-- Contents should represent a (possibly signed) integer number in base 10 -->
"""
            return try _HTTPResponse(response: .OK, body: dtd)
        }

        if uri == "/UnitedKingdom" {
            let value = capitals[String(uri.dropFirst())]!
            let text = request.getCommaSeparatedHeaders()
            //Response header with only path to the location to redirect.
            let httpResponse = try _HTTPResponse(response: .FOUND, headers: ["Location: \(value)"], body: text)
            return httpResponse
        }
        
        if uri == "/echo" {
            return try _HTTPResponse(response: .OK, body: request.messageBody ?? "")
        }
        
        if uri == "/redirect-with-default-port" {
            let text = request.getCommaSeparatedHeaders()
            let host = request.headers[1].components(separatedBy: " ")[1]
            let ip = host.components(separatedBy: ":")[0]
            let httpResponse = try _HTTPResponse(response: .FOUND, headers: ["Location: http://\(ip)/redirected-with-default-port"], body: text)
            return httpResponse

        }

        if uri == "/gzipped-response" {
            // This is "Hello World!" gzipped.
            let helloWorld = Data([0x1f, 0x8b, 0x08, 0x00, 0x6d, 0xca, 0xb2, 0x5c,
                                   0x00, 0x03, 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
                                   0x08, 0xcf, 0x2f, 0xca, 0x49, 0x51, 0x04, 0x00,
                                   0xa3, 0x1c, 0x29, 0x1c, 0x0c, 0x00, 0x00, 0x00])
            return _HTTPResponse(response: .OK,
                                 headers: ["Content-Length: \(helloWorld.count)",
                                           "Content-Encoding: gzip"].joined(separator: "\r\n"),
                                 bodyData: helloWorld)
        }
        
        if uri == "/echo-query" {
            let body = request.parameters.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            return try _HTTPResponse(response: .OK, body: body)
        }

        // Look for /xxx where xxx is a 3digit HTTP code
        if uri.hasPrefix("/") && uri.count == 4, let code = Int(String(uri.dropFirst())), code > 0 && code < 1000 {
            return try statusCodeResponse(forRequest: request, statusCode: code)
        }

        guard let capital = capitals[String(uri.dropFirst())] else {
            return try _HTTPResponse(response: .NOT_FOUND)
        }
        return try _HTTPResponse(response: .OK, body: capital)
    }

    private func statusCodeResponse(forRequest request: _HTTPRequest, statusCode: Int) throws -> _HTTPResponse {
        guard let bodyData = try? request.headersAsJSON() else {
            return try _HTTPResponse(response: .SERVER_ERROR, body: "Cant convert headers to JSON object")
        }

        var response: _HTTPResponse
        switch statusCode {
            case 300...303, 305...308:
                let location = request.parameters["location"] ?? "/" + request.method.rawValue.lowercased()
                let body = "Redirecting to \(request.method) \(location)".data(using: .utf8)!
                let headers = ["Content-Type: test/plain", "Location: \(location)"]
                response = _HTTPResponse(responseCode: statusCode, headers: headers, bodyData: body)

            case 401:
                let headers = ["Content-Type: application/json", "Content-Length: \(bodyData.count)"]
                response = _HTTPResponse(responseCode: statusCode, headers: headers, bodyData: bodyData)
                response.addHeader("WWW-Authenticate: Basic realm=\"Fake Relam\"")

            default:
                let headers = ["Content-Type: application/json", "Content-Length: \(bodyData.count)"]
                response = _HTTPResponse(responseCode: statusCode, headers: headers, bodyData: bodyData)
                break
        }

        return response
    }
}


enum InternalServerError : Error {
    case socketAlreadyClosed
    case requestTooShort
    case badBody
}


class LoopbackServerTest : XCTestCase {
    private static let staticSyncQ = DispatchQueue(label: "org.swift.TestFoundation.HTTPServer.StaticSyncQ")

    private static var _serverPort: Int = -1
    private static var loopGroup: MultiThreadedEventLoopGroup?

    static var serverPort: Int {
        get {
            return staticSyncQ.sync { _serverPort }
        }
        set {
            staticSyncQ.sync { _serverPort = newValue }
        }
    }

    override class func setUp() {
        super.setUp()

        let dispatchGroup = DispatchGroup()
        var _serverPort = 0

        func runServer() throws {
            loopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let reuseAddrOpt = ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR)

            let bootstrap = ServerBootstrap(group: loopGroup!)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(reuseAddrOpt, value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(TestURLSessionServer())
                    }
                }
                .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .childChannelOption(reuseAddrOpt, value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

            do {
                let addr = try SocketAddress(ipAddress: "127.0.0.1", port: _serverPort)
                let serverChannel = try bootstrap.bind(to: addr).wait()
                _serverPort = serverChannel.localAddress?.port ?? -1
                debugLog("Server running on: \(serverChannel.localAddress!))")
                dispatchGroup.leave()
                try serverChannel.closeFuture.wait() // runs forever
                debugLog("Server finished runing")
            }
        }

        dispatchGroup.enter()
        globalDispatchQueue.async {
            do {
                try runServer()
            } catch {
                NSLog("runServer: \(error)")
            }
        }
        let timeout = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        guard dispatchGroup.wait(timeout: timeout) == .success, _serverPort > 0 else {
            fatalError("Timedout waiting for server to be ready")
        }
        serverPort = _serverPort
    }

    override class func tearDown() {
        serverPort = -2
        try? loopGroup?.syncShutdownGracefully()
        super.tearDown()
    }
}
