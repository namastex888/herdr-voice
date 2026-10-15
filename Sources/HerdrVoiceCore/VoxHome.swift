import Foundation

/// Where Vox keeps what she stores beyond her configuration: the conversations (until the user deletes them) and a
/// small local aggregate of the day's numbers. `~/.vox/` for the app; a scratch folder for the self-test.
public struct VoxHome: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var user: VoxHome {
        VoxHome(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vox", isDirectory: true))
    }

    public var conversations: URL { root.appendingPathComponent("conversations", isDirectory: true) }
    public var metrics: URL { root.appendingPathComponent("metrics.json") }
}
