import Foundation

final class RecentItemCache<Value> {
    private let lock = NSLock()
    private var order: [UUID] = []
    private var storage: [UUID: Value] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for id: UUID) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func insert(_ value: Value, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if storage[id] == nil {
            order.append(id)
            if order.count > capacity {
                let evicted = order.removeFirst()
                storage.removeValue(forKey: evicted)
            }
        } else {
            order.removeAll { $0 == id }
            order.append(id)
        }
        storage[id] = value
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        order.removeAll()
        storage.removeAll()
    }
}
