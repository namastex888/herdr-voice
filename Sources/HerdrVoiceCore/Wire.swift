import Foundation

/// What the session asks a provider for, independent of the provider's wire protocol. `Realtime` only speaks
/// in these commands and in `ServerEvent`s; a `Wire` turns them into and out of that provider's messages.
public enum WireCommand: Sendable {
    /// The first message on a connection. `resumeHandle` resumes a previous session where supported. `tools`
    /// defaults to every Herdr tool.
    case setup(instructions: String, voice: String, resumeHandle: String?, tools: ToolList? = nil)
    /// Replaces the session's tools mid-session (only where `capabilities.dynamicTools`).
    case updateTools(ToolList)
    /// Replaces the session's standing instructions mid-session (OpenAI and Grok; the others take them only at setup,
    /// so `Realtime` renews their connection instead).
    case updateInstructions(String)
    /// A locally verified microphone onset. Cloud providers continue to use server VAD and ignore this command.
    case inputStarted(utteranceID: String)
    /// 20 ms of mic audio, base64 PCM16 24 kHz mono.
    case appendAudio(String)
    /// Muting: drop what the provider buffered of your speech (only where `capabilities.clearsInput`; elsewhere
    /// nothing is sent, and the mic just stops).
    case clearInput
    /// The speech gate closed: the mic stream pauses here (lets a provider end the turn without trailing audio).
    case audioPaused
    /// Text from the developer's side (an agent report, a recap, a policy note). `expectsReply` says whether it
    /// should get a spoken answer.
    case userText(String, expectsReply: Bool)
    /// Results of tool calls.
    case toolOutputs([ToolOutput])
    /// Ask for a spoken reply now.
    case requestReply
    /// Stop generating the current reply.
    case cancelReply
    /// Only the first `audioEndMs` of item `itemID` was heard (barge-in).
    case truncate(itemID: String, audioEndMs: Int)
    /// Sent right after `setup` by a session that takes its own turns (only where `capabilities.deferredReplies`):
    /// `true` keeps the provider from answering a finished spoken turn by itself, so the reply waits for
    /// `requestReply`; `false` goes back to the provider answering on its own (what `setup` sets up). The provider's
    /// speech detection still ends each turn either way.
    case deferReplies(Bool)
}

public struct ToolOutput: Equatable, Sendable {
    public let callID: String
    public let name: String
    public let output: String
    /// Local turn identity. Cloud wires ignore it; LocalWire keeps late results bound to their original call.
    public let epoch: Int?

    public init(callID: String, name: String, output: String, epoch: Int? = nil) {
        self.callID = callID
        self.name = name
        self.output = output
        self.epoch = epoch
    }
}

/// How a provider's protocol differs in ways the session has to act on. `Realtime` branches on these, not on which
/// provider it talks to; WireConformanceTests holds every wire to what it declares, and docs/providers.md lists them.
/// The defaults describe a cloud provider: server VAD, a session that is up on its first event, billed by use.
public struct WireCapabilities: Equatable, Sendable {
    /// The session drives replies: it asks for one (`requestReply`), stops one (`cancelReply`) and says how much of
    /// one was heard (`truncate`). Without it the provider answers by itself after a completed user turn or a tool
    /// response, so the session sends those only when a reply is wanted, and a reply can only be stopped locally.
    public let explicitReplies: Bool
    /// The provider resumes a session from a handle with its context intact, so no recap is needed.
    public let nativeResumption: Bool
    /// Tools and instructions can be replaced mid-session (`updateTools`, `updateInstructions`); otherwise a session
    /// keeps the tools it was set up with, and new instructions need a new connection.
    public var dynamicTools = false
    /// The provider detects no speech itself: the session's speech gate does. The session marks each utterance's
    /// start (`inputStarted`) and end (`audioPaused`), streams audio only inside one, reports speech started and
    /// stopped itself, and asks for the reply to each finished utterance.
    public var explicitSpeechOnsets = false
    /// Every utterance onset and every `clearInput` starts a new epoch, and the provider drops all work from older
    /// epochs (replies, audio, tool calls) without finishing it. Tool calls and their results carry their epoch.
    public var turnEpochs = false
    /// The session is up only once the provider acknowledges the setup (`sessionReady`), and an error before that means
    /// the setup was refused. Without it, the first event on a socket means the session is up.
    public var setupHandshake = false
    /// Use is billed, so a session nobody has talked to for a while is closed, and reopened when you next speak.
    public var metered = true
    /// The provider can hold the reply to a spoken turn until the session asks for it (`deferReplies`), while its own
    /// speech detection still ends the turn, so the session decides when to answer. Off by default: a session that
    /// doesn't ask behaves as before.
    public var deferredReplies = false
    /// The provider can drop what it buffered of the user's speech (`clearInput`), so a mute leaves nothing of it to
    /// answer. Without it (Gemini) nothing is sent: the only way to stop its input, end of stream, answers what it
    /// heard.
    public var clearsInput = true
}

public extension WireCapabilities {
    /// Every flag by name, in declaration order. Read by reflection, so a new flag reaches docs/providers.md by itself.
    var flags: [(name: String, value: Bool)] {
        Mirror(reflecting: self).children.compactMap { child in
            guard let name = child.label, let value = child.value as? Bool else { return nil }
            return (name, value)
        }
    }

    /// What each flag means, for the legend under the provider table.
    static let meanings: [String: String] = [
        "explicitReplies": "the session requests, cancels and truncates replies; otherwise the provider answers by itself",
        "nativeResumption": "a session resumes from a handle with its context, so no recap is sent",
        "dynamicTools": "tools and instructions can be replaced mid-session; otherwise only at setup",
        "explicitSpeechOnsets": "no server VAD: the session marks each utterance's start and end and asks for its reply",
        "turnEpochs": "each onset or clear starts an epoch, and work from older epochs is dropped",
        "setupHandshake": "the session is up only once the setup is acknowledged (sessionReady)",
        "metered": "billed by use, so a quiet session is closed until you speak",
        "deferredReplies": "the session can hold the reply to a spoken turn until it asks for one (deferReplies)",
        "clearsInput": "a mute drops what the provider buffered of your speech; otherwise the mic just stops",
    ]
}

/// One provider's wire protocol. A new instance is made per connection; `decode` may keep state across messages.
/// Shared between the main queue (decode, most commands) and the mic queue (audio commands).
public protocol Wire: AnyObject, Sendable {
    var capabilities: WireCapabilities { get }
    func encode(_ command: WireCommand) -> [[String: Any]]
    func decode(_ text: String) -> [ServerEvent]
    /// Whether work from `epoch` still belongs to the current turn (see `WireCapabilities.turnEpochs`).
    func isCurrent(epoch: Int) -> Bool
}

public extension Wire {
    /// Without epochs, nothing is ever superseded.
    func isCurrent(epoch: Int) -> Bool { true }
}

/// WebSocket frames to text. OpenAI and xAI send JSON as text frames; Gemini Live sends it as binary frames, which
/// were silently dropped before (the session connected, then never heard a transcript or reply).
public enum WireFrame {
    public static func text(_ data: Data) -> String? { String(data: data, encoding: .utf8) }
}
