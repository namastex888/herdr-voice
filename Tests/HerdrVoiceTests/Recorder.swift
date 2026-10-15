import Foundation

/// What a fake records from closures the code under test may call on any thread. It reads like an array
/// (`count`, `isEmpty`, `last`, `filter`, `==`), so tests check it the way they would a local `var`.
final class Recorder<Element>: @unchecked Sendable, RandomAccessCollection { // every access holds `lock`
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) { lock.withLock { items.append(item) } }

    var startIndex: Int { 0 }
    var endIndex: Int { lock.withLock { items.count } }
    subscript(position: Int) -> Element { lock.withLock { items[position] } }
}

extension Recorder where Element: Equatable {
    static func == (lhs: Recorder, rhs: [Element]) -> Bool { Array(lhs) == rhs }
}
