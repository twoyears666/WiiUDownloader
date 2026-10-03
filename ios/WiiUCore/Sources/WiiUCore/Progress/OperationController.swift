import Foundation

/// Thread-safe cancellation and pause state shared between the UI and the
/// long-running download/decrypt workers.
public final class OperationController: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelledFlag = false
    private var pausedFlag = false

    public init() {}

    public func cancel() {
        condition.lock()
        cancelledFlag = true
        condition.broadcast()
        condition.unlock()
    }

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelledFlag
    }

    public func pause() {
        condition.lock()
        pausedFlag = true
        condition.unlock()
    }

    public func resume() {
        condition.lock()
        pausedFlag = false
        condition.broadcast()
        condition.unlock()
    }

    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return pausedFlag
    }

    /// Blocks while paused. Throws `WiiUError.cancelled` if cancellation is
    /// requested while waiting.
    public func waitIfPaused() throws {
        condition.lock()
        defer { condition.unlock() }
        while pausedFlag && !cancelledFlag {
            condition.wait()
        }
        if cancelledFlag { throw WiiUError.cancelled }
    }

    /// Sleeps for `interval` seconds in a cancellation-aware way. Returns false
    /// when the operation was cancelled instead of sleeping the full duration.
    @discardableResult
    public func sleep(_ interval: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(interval)
        condition.lock()
        defer { condition.unlock() }
        while !cancelledFlag {
            if Date() >= deadline { return true }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
        return false
    }
}

/// Convenience state snapshot for UI bindings.
public struct OperationState: Sendable, Equatable {
    public var isCancelled: Bool
    public var isPaused: Bool

    public init(isCancelled: Bool = false, isPaused: Bool = false) {
        self.isCancelled = isCancelled
        self.isPaused = isPaused
    }
}
