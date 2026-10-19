import Hummingbird
import HummingbirdCore
import NIOCore
import VegaNIO

// VegaServerBootstrap's own bind(host:port:...) and
// bind(unixDomainSocketPath:cleanupExistingSocketFile:...) are the ones
// Hummingbird calls.
extension VegaServerBootstrap: @retroactive ServerBootstrapProtocol {}

extension ApplicationConfiguration {
    /// Serve with VegaNIO when the application's group is a
    /// `VegaEventLoopGroup`, with the options Hummingbird's own
    /// sockets bootstrap sets.
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
