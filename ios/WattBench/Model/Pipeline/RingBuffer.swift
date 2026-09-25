import Foundation

/// Fixed-capacity FIFO. Appending past capacity drops the oldest element in
/// O(1); index 0 is always the oldest retained element.
struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0          // index of the oldest element
    private(set) var count = 0

    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer needs a positive capacity")
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }

    var last: Element? {
        guard count > 0 else { return nil }
        return storage[(head + count - 1) % capacity]
    }

    mutating func append(_ e: Element) {
        if count < capacity {
            storage[(head + count) % capacity] = e
            count += 1
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    /// Elements oldest first.
    func array() -> [Element] {
        var out: [Element] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if let e = storage[(head + i) % capacity] { out.append(e) }
        }
        return out
    }

    subscript(i: Int) -> Element {
        precondition(i >= 0 && i < count, "RingBuffer index out of range")
        // The slot is always populated for i < count.
        guard let e = storage[(head + i) % capacity] else {
            preconditionFailure("RingBuffer slot \(i) unexpectedly empty")
        }
        return e
    }

    mutating func removeAll() {
        for i in storage.indices { storage[i] = nil }
        head = 0
        count = 0
    }
}
