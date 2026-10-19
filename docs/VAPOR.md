# Vapor on Vega

[Vapor 4](https://github.com/vapor/vapor) can run on Vega through [VegaNIO](../README.md). Routing, middleware, `Request`/`Response`, async route handlers and Vapor's NIO HTTP/1 pipeline all stay as they are. The only things that change are the event loop group and the bootstrap that listens: Vega does the scheduling and the socket I/O.

That needs one small change in Vapor, described below. A working example is in [`Examples/VaporHello`](../Examples/VaporHello).

## Why Vapor needs a patch

`HTTPServerConnection.start` (in `Sources/Vapor/HTTP/Server/HTTPServer.swift`) always builds NIOPosix's `ServerBootstrap(group:)`, and `ServerBootstrap(group:)` stops with a precondition failure for any group that isn't a NIOPosix `MultiThreadedEventLoopGroup`. NIOCore defines no protocol for server bootstraps, and Vapor offers no way to supply one. So passing `.shared(VegaEventLoopGroup())` to an unpatched Vapor crashes when the server starts.

## The patch

[`Examples/vapor-make-bootstrap.patch`](../Examples/vapor-make-bootstrap.patch) is made against Vapor `4.122.2`. It touches one file, adding 22 lines and removing 1. It doesn't mention Vega, so the same hook would work for any other transport:

- A public `HTTPServerBootstrap` protocol, with the six calls `HTTPServer` makes on a bootstrap:
  - `serverChannelOption`
  - `childChannelOption`
  - `serverChannelInitializer`
  - `childChannelInitializer`
  - `bind(host:port:)`
  - `bind(unixDomainSocketPath:)`
- `ServerBootstrap` conforms to it, with an empty extension.
- `HTTPServer.Configuration` gains `makeBootstrap: (@Sendable (any EventLoopGroup) -> (any HTTPServerBootstrap)?)?`. The default is `nil`.
- `HTTPServerConnection.start` uses `makeBootstrap?(group) ?? ServerBootstrap(group:)`. The options and initializers it sets afterwards are unchanged, so a VegaNIO server gets the same backlog, `SO_REUSEADDR`, `TCP_NODELAY`, idle-timeout and HTTP/1 handlers as a NIOPosix one.

Applications that don't set `makeBootstrap` see no change in behaviour. The patch is shaped so it could go upstream. It hasn't been proposed yet.

Vapor 5 (Vapor's `main` branch, in beta) serves through swift-server's [swift-http-server](https://github.com/swift-server/swift-http-server). That server keeps a `MultiThreadedEventLoopGroup` and builds `ServerBootstrap` itself, so it would need the same kind of hook. That work waits for Vapor 5 to settle.

## Using it

The example's `VaporVega` target holds the glue: an empty conformance and one configuration helper.

```swift
import Vapor
import VegaNIO

extension VegaServerBootstrap: @retroactive HTTPServerBootstrap {}

extension HTTPServer.Configuration {
    /// Serve with VegaNIO when the application's group is a VegaEventLoopGroup.
    public mutating func useVega() {
        makeBootstrap = { VegaServerBootstrap(validatingGroup: $0) }
    }
}
```

An application then needs two lines more than usual:

```swift
import Vapor
import VaporVega
import VegaNIO

let group = VegaEventLoopGroup()
let app = try await Application.make(.detect(), .shared(group))
app.http.server.configuration.useVega()
app.get { _ in "Hello from Vapor on Vega\n" }
try await app.execute()
try await app.asyncShutdown()
```

To build and test the example:

```sh
cd Examples/VaporHello
./setup.sh        # clones Vapor 4.122.2 into .deps/ and applies the patch
swift test
swift run         # serves on 127.0.0.1:8080
```

## What has been checked

The example's test starts a real Vapor server on a `VegaEventLoopGroup` (`app.server.start`, port 0) and talks to it with AsyncHTTPClient, which runs on NIOPosix. All of the following pass on Linux (Swift 6.3.3, io_uring driver):

- `GET /` and a route with a path parameter
- `POST /echo` with a 300 KB body, collected and echoed back
- an `async` handler that sleeps, then responds
- a 404 for an unknown route
- the server's start message reports the bound address (`http://127.0.0.1:<port>`)
- shutdown: `app.server.shutdown()` quiesces through NIOExtras' `ServerQuiescingHelper` on Vega channels, then the app and group shut down

## How it runs

- Vapor's HTTP/1 handlers run on the connection's loop, as they do on NIOPosix.
- Vapor 4 calls route handlers from those handlers. `async` handlers run as Swift tasks, and the loop moves on while they wait.
- With VegaNIO, a connection's reads and writes are Vega tasks that any worker can steal. See [VegaNIO's README](../README.md#how-it-runs) for how the loops and I/O tasks work.

## Not covered

- TLS and HTTP/2 through NIOSSL and NIOHTTP2 are pipeline handlers and should work, but they haven't been tested yet.
- `app.client` (AsyncHTTPClient) on the application's event loop group would need the same kind of hook in AsyncHTTPClient, which picks NIOPosix's `ClientBootstrap` or NIOTransportServices'. Give the client its own NIOPosix group meanwhile.
- `app.fileio` (`NonBlockingFileIO`) uses NIOPosix's thread pool, not the group, so it works unchanged.

## Performance

Vapor on VegaNIO runs at Vapor on NIOPosix's speed. On 2026-10-19, on Vega
1.0.0, under the-benchmarker's load with the clock capped (median of four
rounds, [README](../README.md#benchmarks)):

| Requests/s | 64 connections | 256 connections | 512 connections |
|---|---:|---:|---:|
| NIOPosix, ramp | 40,807 | 40,814 | 40,436 |
| VegaNIO, ramp | 40,400 (0.99×) | 40,758 (1.00×) | 40,323 (1.00×) |
| NIOPosix, closed loop | 35,450 | 35,578 | 35,342 |
| VegaNIO, closed loop | 35,180 (0.99×) | 35,210 (0.99×) | 34,921 (0.99×) |

Vapor, NIO's pipeline and NIO's HTTP/1 codec cost more than the event loop
does, so swapping the event loop alone doesn't make it faster. Under closed
load at 256 and 512 connections its p99 is lower on VegaNIO (11.7 against
15.0 ms, 21.5 against 28.5 ms).

In an earlier, uncapped run, Vega's own HTTP/1 server, with no NIO and no
framework, served the same requests at about 3.3× Vapor's rate on NIOPosix at
512 connections ([Vega's BENCHMARKS.md](https://github.com/grepjava/vega/blob/main/docs/BENCHMARKS.md#hummingbird-and-vapor-on-veganio-and-native-vegahttp1-2026-101314)).
