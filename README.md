# foundation-networking-ahc


This package is a development version of the FoundationNetworking part of
[swift-corelibs-foundation](https://github.com/apple/swift-corelibs-foundation)
for ease of porting the `URLSession` subsystem to SwiftNIO's
[async-http-client](https://github.com/swift-server/async-http-client) as proposed
[here.](https://forums.swift.org/t/proposal-swift-corelibs-foundation-replace-libcurl-with-swiftnio-and-asynchttpclient/44543/6)

As more parts are implmeneted, there will be code drops into the main `swift-corelibs-foundation` repository.

DO NOT USE THIS AS A PACKAGE IN YOUR PROJECTS. There will be no version numbers applied and once most of the port is complete this
repository will be archived and no further work done on it.

The basic idea is to replace the libcurl backend for http with `async-http-client` and drop the FTP support. If an FTP client using
NIO is ever developed in the future, it may possibly be used to restore the FTP support.

The development work mostly involves enhancing `async-http-client` and its `HTTPClientResponseDelegate` and then mapping the
delegate calls to those used by `URLSession` and its related classes.

