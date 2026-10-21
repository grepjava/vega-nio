# VegaNIO

SwiftNIO's `EventLoopGroup`, `EventLoop`, `Channel` and bootstraps, running on
[Vega](https://github.com/grepjava/vega). Hummingbird, Vapor and other code
written for SwiftNIO keeps its handlers, `ChannelPipeline`, `EventLoopFuture`s
and `NIOAsyncChannel`s, while Vega does the scheduling and the I/O underneath.

This package also bridges Vega to Apple's other server packages:
`VegaSwiftMetrics` reports Vega's runtime metrics through swift-metrics, and
`VegaLogging` logs slow task polls through swift-log.

```swift
dependencies: [
    .package(url: "https://github.com/grepjava/vega-nio.git", from: "1.1.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "VegaNIO", package: "vega-nio"),
        .product(name: "VegaSwiftMetrics", package: "vega-nio"),   // optional
        .product(name: "VegaLogging", package: "vega-nio"),        // optional
    ]),
]
```

## What VegaNIO is

SwiftNIO's own event loops (`MultiThreadedEventLoopGroup`, from NIOPosix) are
threads: each runs its channels and nothing else, and a channel stays on the
thread it was given. That keeps NIO simple and fast, but a busy loop can't
hand work to an idle one, and the work you do outside NIO (Swift tasks,
blocking calls, timers) runs on other threads and pools that NIO knows
nothing about.

VegaNIO puts NIO's API on top of Vega, a runtime for Swift built the way
[Tokio](https://tokio.rs) is built for Rust. A NIO app gets Vega's runtime
underneath without rewriting its handlers:

- **A work-stealing scheduler.** Each worker thread has a local queue of 256
  jobs and a LIFO slot, so a task woken by the one running now runs next, on
  a warm core. An idle worker steals half of a busy worker's queue. Work from
  outside the workers goes through a shared inject queue, which every worker
  checks regularly so it is never starved. This is Tokio's multi-threaded
  scheduler, run as a Swift `TaskExecutor`.
- **A cooperative budget.** Swift can't preempt a task, so each poll gets a
  budget of 128 operations (Tokio's figure). A task that uses it up yields at
  its next Vega call, so one busy connection can't hold a worker.
- **The I/O driver of each platform.** io_uring on Linux 6.7 and later, with
  a ring per worker; epoll on older Linux; kqueue on macOS; IOCP on Windows.
  Workers sleep in the driver, so waking on I/O costs no extra thread hop.
- **A hierarchical timer wheel,** sharded per worker, for every deadline:
  NIO's `scheduleTask`, timeouts and sleeps.
- **A blocking pool** for work that would stall a worker: Tokio's
  `spawn_blocking` as `Runtime.blocking { }`, with `Runtime.tryBlocking` to
  refuse work when the pool's queue is full, and `Runtime.blockInPlace`.
- **Tokio's toolbox** for the async code beside your handlers: `JoinSet`,
  `MPSCChannel`, `Oneshot`, `Broadcast`, `Watch`, `Notify`, `Semaphore`,
  `AsyncMutex`, `Barrier`, `Interval`, and `Runtime.timeout(for:)`.
- **Runtime metrics:** per-worker counters, steals, queue depths and poll
  times, with `Runtime.onSlowPoll` to catch a handler that blocks.

How NIO's model maps onto it:

- **A loop is a serial queue, not a thread.** Handlers on one loop run one at
  a time and in order, as NIO promises, and `inEventLoop`,
  `preconditionInEventLoop` and `assumeIsolated` hold while they run. But any
  of Vega's workers can run a loop's work, so a loop with work never waits
  behind a busy thread.
- **Each connection's reads and writes are Vega tasks,** which idle workers
  can steal.
- **One runtime for everything.** `group.runtime` is a Vega `Runtime`: spawn
  tasks on it, run blocking work in its pool, or use Vega's own sockets and
  protocols beside your NIO channels, all on the same worker threads.

VegaNIO swaps the engine under NIO, not NIO itself: the pipeline, the futures,
NIO's HTTP codec and the framework above them all stay. So an app runs at
about the same speed as on NIOPosix (see [Benchmarks](#benchmarks)). For
Vega's full speed, write against Vega's own API, or use
[Garuda](https://github.com/grepjava/garuda), the web framework built on it.

## Using it

```swift
import NIOCore
import NIOHTTP1
import VegaNIO

let group = VegaEventLoopGroup(loops: 8)
let server = try await VegaServerBootstrap(group: group)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(HelloHandler())
        }
    }
    .bind(host: "0.0.0.0", port: 8080).get()
```

`VegaEventLoopGroup(loops:)` starts a runtime of its own with a worker per
loop (the CPU count by default). `VegaEventLoopGroup(runtime:loops:)` runs the
loops on a runtime you already have.

| NIOPosix | VegaNIO |
|---|---|
| `MultiThreadedEventLoopGroup` | `VegaEventLoopGroup(loops:)`, or `VegaEventLoopGroup(runtime:loops:)` on a runtime you already have |
| `ServerBootstrap` | `VegaServerBootstrap`, including the async `bind(host:port:childChannelInitializer:)` that returns an `NIOAsyncChannel`; `bind(unixDomainSocketPath:cleanupExistingSocketFile:)` listens on a Unix domain socket |
| `ClientBootstrap` | `VegaClientBootstrap`, which is an `NIOClientTCPBootstrapProtocol`; `connect(host:port:)` races the host's addresses (Happy Eyeballs); `connect(unixDomainSocketPath:)` |
| `DatagramBootstrap` | `VegaDatagramBootstrap`: UDP channels of `AddressedEnvelope<ByteBuffer>`, bound (`bind(host:port:)`, `bind(to:)`) or connected (`connect(host:port:)`, `connect(to:)`, which also take plain `ByteBuffer` writes), with the async forms that wrap the channel in an `NIOAsyncChannel` before it goes active. Unix datagram sockets too, over Vega's `UnixDatagram`: `bind(unixDomainSocketPath:cleanupExistingSocketFile:)` and `connect(unixDomainSocketPath:)`, with envelopes addressed by `.unixDomainSocket` (Linux and macOS) |
| `NIOPipeBootstrap` | `VegaPipeBootstrap`: `takingOwnershipOfDescriptors(input:output:)`, `takingOwnershipOfDescriptor(input:)`, `(output:)` and `(inputOutput:)`, and their async forms. Regular files are refused, as on NIO. Linux and macOS |

### Hummingbird 2 and Vapor 4

Both run on VegaNIO. Each builds NIOPosix's `ServerBootstrap` itself, so each
needs a small patch that lets it take another bootstrap, as both already do
for NIOTransportServices. [docs/HUMMINGBIRD2.md](docs/HUMMINGBIRD2.md) and
[docs/VAPOR.md](docs/VAPOR.md) have the patches and how to use them, and
[Examples/](Examples) has a working app for each.

## Metrics and logging

```swift
import Logging
import Vega
import VegaSwiftMetrics
import VegaLogging

// Every 10 s, Runtime.metrics as swift-metrics counters and gauges, with
// whatever backend the process bootstrapped (Prometheus, StatsD, ...).
group.runtime.reportMetrics(every: .seconds(10), prefix: "vega")

// Each task poll that ran longer than 10 ms, logged through swift-log:
// a handler that blocks a worker shows up here.
group.runtime.logSlowPolls(to: Logger(label: "vega"), threshold: .milliseconds(10))
```

## Benchmarks

Hummingbird 2 and Vapor 4, each on SwiftNIO's NIOPosix and on VegaNIO. Each
framework is one binary, built from [Examples/](Examples) as
[the-benchmarker/web-frameworks](https://github.com/the-benchmarker/web-frameworks)
builds its entries; `VEGANIO=1` makes it serve on VegaNIO. Everything above
the event loop group is the same code in both.

Run on 2026-10-19 on Vega 1.0.0: one i5-8250U (4 cores, 8 threads) with the
clock capped at 2.4 GHz, so turbo can't favour whichever server runs first.
Server and load share the 8 threads unpinned, as the suite runs them. The four
servers took turns to go first over four rounds. Each figure is the median of
the four rounds; no run had errors.

**Ramp:** the suite's own load, `zrk -R1000:500000` for 15 s, an open-loop
ramp to 500,000 requests a second. The figure is the rate achieved.

| Requests/s | 64 connections | 256 connections | 512 connections |
|---|---:|---:|---:|
| Hummingbird on NIOPosix | 51,100 | 52,644 | 51,573 |
| Hummingbird on VegaNIO | 49,479 (0.97×) | 52,868 (1.00×) | 51,880 (1.01×) |
| Vapor on NIOPosix | 40,807 | 40,814 | 40,436 |
| Vapor on VegaNIO | 40,400 (0.99×) | 40,758 (1.00×) | 40,323 (1.00×) |

**Closed loop:** `oha -c N` for 15 s, which measures capacity.

| Requests/s, p99 | 64 connections | 256 connections | 512 connections |
|---|---:|---:|---:|
| Hummingbird on NIOPosix | 46,174, 3.8 ms | 49,712, 11.8 ms | 49,153, 22.0 ms |
| Hummingbird on VegaNIO | 43,982 (0.95×), 4.8 ms | 48,493 (0.98×), 17.5 ms | 48,406 (0.98×), 42.4 ms |
| Vapor on NIOPosix | 35,450, 4.9 ms | 35,578, 15.0 ms | 35,342, 28.5 ms |
| Vapor on VegaNIO | 35,180 (0.99×), 5.0 ms | 35,210 (0.99×), 11.7 ms | 34,921 (0.99×), 21.5 ms |

- **VegaNIO runs these frameworks at NIOPosix's speed:** 0.97–1.01× under
  the ramp and 0.95–0.99× closed loop. NIO's pipeline, its futures, its HTTP/1
  codec and the framework above them cost more than the event loop
  underneath, and VegaNIO keeps all of them.
- **Tail latency moves both ways.** Under closed load at 256 and 512
  connections, Hummingbird's p99 is higher on VegaNIO (17.5 against 11.8 ms,
  42.4 against 22.0 ms), and Vapor's is lower (11.7 against 15.0 ms, 21.5
  against 28.5 ms). Medians stay within 1.3 ms of each other, and
  Hummingbird's are lower on VegaNIO (8.5 against 9.7 ms at 512).
- **What VegaNIO buys is the runtime, not the speed:** a NIO app and native
  Vega code on the same work-stealing workers, timers and blocking pool. On
  Vega's own API the same contract ran at 2.4–2.6 times Hummingbird's rate
  in an earlier, uncapped run on this box
  ([Vega's benchmarks](https://github.com/grepjava/vega/blob/main/docs/BENCHMARKS.md)).

**Idle connections.** 20,000 keep-alive connections to Hummingbird, each
having made one request, then left open; the server's memory per connection,
on Linux (2026-10-21):

| Per idle connection | |
|---|---:|
| Hummingbird on NIOPosix | 17.2 KiB |
| Hummingbird on VegaNIO 1.0 | 27.1 KiB |
| Hummingbird on VegaNIO 1.1 | 19.7 KiB |

1.1 waits for input holding no read buffer, and starts a connection's writer
task only when a flush leaves bytes behind. Its throughput on the closed loop
above, pinned, is 0.99× 1.0's (within 1.2% at 64, 256 and 512 connections,
with the same p99).

The driver and every run's output are in
[benchmarks/2026-10-19](benchmarks/2026-10-19); the load is
[Garuda's `frameworks.sh`](https://github.com/grepjava/garuda/blob/main/benchmarks/frameworks.sh),
which follows the suite's own command flag for flag.

## How it runs

- **A loop is a serial queue, not a thread.** Handlers on one loop run one at a time and in order, as NIO promises, and `inEventLoop`, `preconditionInEventLoop` and `assumeIsolated` hold while they run. Whichever Vega worker picks up a loop's work runs it, so a loop doesn't stay on one thread from one tick to the next. NIOTransportServices' loops on Dispatch behave the same way. A group can have more loops than the runtime has workers.
- **Swift tasks isolated to a loop** (an actor whose `unownedExecutor` is `eventLoop.executor`) run on the loop, inline.
- **Each connection has a reader task, and a writer task while it has output waiting.** These are ordinary Vega tasks that any worker can steal. The reader reads when the pipeline asks for a read (`autoRead` asks after every delivery) and hands the bytes to the loop. It waits in Vega's `receive()`, which holds no buffer: the runtime lends one when bytes arrive, and takes it back once they are copied into the channel's `ByteBuffer`. When nobody else is running the loop, the reader delivers on its own task, so a quiet connection costs no hop. `flush()` sends what the socket takes there and then, as NIO's does (Vega's `tryWrite`, which never waits), and completes those write promises at once. Only what doesn't fit goes to a writer task, started for it, which sends it when the socket has room, reports back, and ends once nothing is left. While it is busy, later flushes queue behind it, so bytes always go out in order.
- **Unix sockets and pipes** run the same way, over Vega's `UnixStream` and its `PipeReader` and `PipeWriter`. A pipe has no write that never waits, so its `flush()` hands everything to the writer, and write promises complete once the writer has sent them. A pipe channel can close its input or its output on its own, and closes once neither is left.
- **A UDP channel** has a reader task that receives one datagram (up to 64 KiB, so none is cut short) whenever the pipeline asks for a read, and a writer task that sends flushed datagrams in order, completing each write's promise once its datagram has gone. A datagram the network refuses fails its own write, or comes up as an `errorCaught` while reading, and doesn't close the channel. `SO_REUSEADDR` and `SO_REUSEPORT` set as channel options apply before the socket binds. A Unix datagram channel runs the same way; one made by `connect(unixDomainSocketPath:)` is unbound, as on NIO, so its peer sees an empty path as the sender and has nowhere to answer.
- **Closing a channel** stops reading at once and fails writes that were never flushed. Flushed writes still go out, so write-then-close works as it does on NIO, but only for up to 10 seconds if the peer isn't taking them.
- **Scheduled tasks** use Vega's timer wheel. Cancelling a task from its loop before it runs means it never runs.

## Not yet

- Multicast (`MulticastChannel`), and UDP's vector reads, GSO, GRO and ECN options are not supported yet: each read takes one datagram, and `datagramVectorReadMessageCount` is accepted and ignored.
- `close(mode: .input)` works on pipe channels, not yet on sockets.
- Writing a `FileRegion` fails with `ChannelError.operationUnsupported`.
- Libraries that build `NIOPosix.ServerBootstrap` or `ClientBootstrap` themselves need a way to accept a different bootstrap, as they already do for NIOTransportServices. Hummingbird 2 and Vapor 4 each need a small patch for this; see above.
- Linux and macOS. NIO's Windows support is partial, so Windows is not covered yet. The port
  is mostly mechanical: about 30 errors in five files, from POSIX calls (`stat`, `errno`,
  `setsockopt`, `close`, `socklen_t`, the `E*` constants) that want their Winsock and ucrt
  forms, and from `UnixDatagram`, `SocketAddress(unixPath:)` and `SO_REUSEPORT`, which
  Windows lacks and which want `#if` around them.

## Testing

```sh
swift test
```

Clone the repository as `vega-nio` (its default name): the examples refer to
this package by that name. `VEGA_PATH=/path/to/vega swift test` builds against
a local Vega checkout instead of the release.

VegaNIO's suite covers event-loop ordering and serial execution, scheduled and repeated tasks, actors on a loop's executor, echo, connection refused, write-then-close, half-closure, writability and water marks, socket options, NIO's own HTTP/1 handlers, `NIOAsyncChannel` on both ends, and group shutdown; UDP echo, addressed and connected, `SO_REUSEADDR` and the async datagram bind; Unix datagram echo by path, an unbound connected sender, socket-file cleanup and the async forms; a Unix socket echo server and client, with socket-file cleanup; and pipe channels over pipe(2) and a socketpair, one way and both ways, closing input or output alone, and the refusal of regular files. It is clean under ThreadSanitizer. The adapters' tests check the metrics recorded and the slow polls logged.

## License

MIT; see [LICENSE](LICENSE).
