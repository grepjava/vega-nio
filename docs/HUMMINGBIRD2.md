# Hummingbird 2 on Vega

[Hummingbird 2](https://github.com/hummingbird-project/hummingbird) can run on Vega through [VegaNIO](../README.md). Its router, middleware, request and response types, and NIO's HTTP/1 handlers underneath all stay as they are. The only things that change are the event loop group and the bootstrap that listens: Vega does the scheduling and the socket I/O.

That needs one small change in Hummingbird, described below. A working example is in [`Examples/HummingbirdHello`](../Examples/HummingbirdHello).

## Why Hummingbird needs a patch

`HummingbirdCore.Server.makeServer` chooses its bootstrap itself:

- `NIOTSListenerBootstrap` when the group is a `NIOTSEventLoopGroup`
- otherwise NIOPosix's `ServerBootstrap(group:)`

`ServerBootstrap(group:)` stops with a precondition failure for any group that isn't a NIOPosix `MultiThreadedEventLoopGroup`. NIOCore defines no protocol for server bootstraps (its universal-bootstrap protocol covers clients only), and Hummingbird's own `ServerBootstrapProtocol` is internal. So handing a `VegaEventLoopGroup` to an unpatched Hummingbird crashes when the server starts, and nothing outside Hummingbird can prevent that.

## The patch

[`Examples/hummingbird-make-bootstrap.patch`](../Examples/hummingbird-make-bootstrap.patch) is made against Hummingbird `13c924d` (main, October 2026). It touches 3 files, adding 51 lines and removing 27. It doesn't mention Vega, so the same hook would work for any other transport:

- `ServerBootstrapProtocol` becomes `public`, and so does `Server.swift`'s import of NIOTransportServices, whose listener bootstrap conforms to it on Apple platforms.
- `ServerConfiguration` and `ApplicationConfiguration` gain `makeBootstrap: (@Sendable (any EventLoopGroup) -> (any ServerBootstrapProtocol)?)?`.
  - The default is `nil`.
  - `ApplicationConfiguration.with(...)` carries it over.
- `makeServer` asks `makeBootstrap` first. If it is nil, or returns nil, the existing NIOTransportServices/NIOPosix choice runs exactly as before.
- Two files change `import NIOCore` to `public import NIOCore`, because Hummingbird builds with `InternalImportsByDefault` and the new property names `EventLoopGroup`.

Applications that don't set `makeBootstrap` see no change in behaviour. The patch is shaped so it could go upstream. It hasn't been proposed yet.

## Using it

The example's `HummingbirdVega` target holds the glue: a conformance and one configuration helper.

```swift
import Hummingbird
import HummingbirdCore
import NIOCore
import VegaNIO

// VegaServerBootstrap's own bind(host:port:...) and
// bind(unixDomainSocketPath:cleanupExistingSocketFile:...) are the ones
// Hummingbird calls.
extension VegaServerBootstrap: @retroactive ServerBootstrapProtocol {}

extension ApplicationConfiguration {
    /// Serve with VegaNIO when the group is a VegaEventLoopGroup, with the
    /// options Hummingbird's own sockets bootstrap sets.
    public mutating func useVega() {
        let backlog = Int32(self.backlog)
        let reuseAddress: SocketOptionValue = self.reuseAddress ? 1 : 0
        makeBootstrap = { group in
            VegaServerBootstrap(validatingGroup: group)?
                .serverChannelOption(.backlog, value: backlog)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: reuseAddress)
                .childChannelOption(.allowRemoteHalfClosure, value: true)
        }
    }
}
```

An application then needs two lines more than usual: the group, and `useVega()`.

```swift
import Hummingbird
import HummingbirdVega
import VegaNIO

let group = VegaEventLoopGroup()
let router = Router()
router.get("/") { _, _ in "Hello from Hummingbird on Vega\n" }

var configuration = ApplicationConfiguration(address: .hostname("127.0.0.1", port: 8080))
configuration.useVega()
let app = Application(router: router, configuration: configuration, eventLoopGroupProvider: .shared(group))
try await app.runService()
```

To build and test the example:

```sh
cd Examples/HummingbirdHello
./setup.sh        # clones Hummingbird at 13c924d into .deps/ and applies the patch
swift test
swift run         # serves on 127.0.0.1:8080
```

## What has been checked

The example's test uses Hummingbird's own live test framework (`app.test(.live)`). That framework starts the real server through `ServiceGroup`, and its client is the NIOPosix-based `TestClient`. All of the following pass on Linux (Swift 6.3.3, io_uring driver):

- `GET /` and a route with a path parameter
- `POST /echo` with a 300 KB body, which is collected in full and echoed back
- an async handler that sleeps, then responds
- a 404 for an unknown route
- graceful shutdown through `ServiceGroup`, with the quiescing helper on Vega channels

## How it runs

- NIO's HTTP/1 handlers run on the connection's loop, as they do on NIOPosix.
- Route handlers run as ordinary Swift tasks, because Hummingbird hands requests to them through `NIOAsyncChannel`. With VegaNIO, a connection's reads and writes are Vega tasks that any worker can steal, so one busy connection doesn't hold up the others on its loop.
- See [VegaNIO's README](../README.md#how-it-runs) for how the loops and I/O tasks work.

## Not covered

- TLS through `HummingbirdTLS` (NIOSSL handlers in the pipeline) should work, since it is just pipeline handlers, but it hasn't been tested yet.
- Hummingbird's `.live` test client and `HummingbirdTesting` still run on NIOPosix. Only the server under test is on Vega.

## Performance

Hummingbird on VegaNIO runs at Hummingbird on NIOPosix's speed. On
2026-10-19, on Vega 1.0.0, under the-benchmarker's load with the clock capped
(median of four rounds, [README](../README.md#benchmarks)):

| Requests/s | 64 connections | 256 connections | 512 connections |
|---|---:|---:|---:|
| NIOPosix, ramp | 51,100 | 52,644 | 51,573 |
| VegaNIO, ramp | 49,479 (0.97×) | 52,868 (1.00×) | 51,880 (1.01×) |
| NIOPosix, closed loop | 46,174 | 49,712 | 49,153 |
| VegaNIO, closed loop | 43,982 (0.95×) | 48,493 (0.98×) | 48,406 (0.98×) |

Its router, NIO's pipeline and NIO's HTTP/1 codec cost more than the event
loop does, so swapping the event loop alone doesn't make it faster. Under
closed load at 256 and 512 connections its p99 is higher on VegaNIO (17.5
against 11.8 ms, 42.4 against 22.0 ms) and its median lower (8.5 against
9.7 ms at 512).

In an earlier, uncapped run, Vega's own HTTP/1 server, with no NIO and no
framework, served the same requests at 2.4–2.6× Hummingbird's rate on
NIOPosix at 512 connections ([Vega's BENCHMARKS.md](https://github.com/grepjava/vega/blob/main/docs/BENCHMARKS.md#hummingbird-and-vapor-on-veganio-and-native-vegahttp1-2026-101314)).
