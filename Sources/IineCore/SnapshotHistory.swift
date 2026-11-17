import Foundation

public struct SnapshotHistory<State> {
    private struct Entry {
        let state: State
        let cost: Int
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private let capacity: Int
    private let maximumCost: Int
    private let estimateCost: (State) -> Int

    /// Each direction keeps its nearest states within the budget, including at least one state when capacity is positive.
    public init(capacity: Int = 200, maximumCost: Int = .max, estimateCost: @escaping (State) -> Int = { _ in 1 }) {
        self.capacity = max(0, capacity)
        self.maximumCost = max(0, maximumCost)
        self.estimateCost = estimateCost
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ state: State) {
        undoStack.append(Entry(state: state, cost: max(0, estimateCost(state))))
        redoStack.removeAll()
        Self.trim(&undoStack, capacity: capacity, maximumCost: maximumCost)
    }

    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(Entry(state: current, cost: max(0, estimateCost(current))))
        Self.trim(&redoStack, capacity: capacity, maximumCost: maximumCost)
        return previous.state
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(Entry(state: current, cost: max(0, estimateCost(current))))
        Self.trim(&undoStack, capacity: capacity, maximumCost: maximumCost)
        return next.state
    }

    public mutating func discardRedo() { redoStack.removeAll() }

    public mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private static func trim(_ stack: inout [Entry], capacity: Int, maximumCost: Int) {
        if stack.count > capacity { stack.removeFirst(stack.count - capacity) }
        var total = stack.reduce(0) { $0 + $1.cost }
        while total > maximumCost && stack.count > 1 {
            total -= stack.removeFirst().cost
        }
    }
}
