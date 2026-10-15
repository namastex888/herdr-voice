import Foundation

/// One connection's WebSocket, as `Realtime` uses it: `URLSessionWebSocketTask` in the apps. Tests hand the session a
/// fake (`Realtime(socket:)`) to see every frame that would leave the Mac and to play the provider's side.
public protocol SessionSocket: AnyObject, Sendable {
    func resume()
    func send(text: String, completion: @escaping @Sendable ((any Error)?) -> Void)
    func receive(completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void)
    func ping(completion: @escaping @Sendable ((any Error)?) -> Void)
    func close(_ code: URLSessionWebSocketTask.CloseCode)
    /// What the provider said when it closed the connection, if anything.
    var closeReason: Data? { get }
}

extension URLSessionWebSocketTask: SessionSocket {
    public func send(text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        send(.string(text), completionHandler: completion)
    }

    public func receive(completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void) {
        receive(completionHandler: completion)
    }

    public func ping(completion: @escaping @Sendable ((any Error)?) -> Void) {
        sendPing(pongReceiveHandler: completion)
    }

    public func close(_ code: URLSessionWebSocketTask.CloseCode) {
        cancel(with: code, reason: nil)
    }
}
