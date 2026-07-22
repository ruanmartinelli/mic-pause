import Foundation

/// Single-slot cancellable delayed action. Scheduling replaces any pending action.
public final class Debouncer {
    private var workItem: DispatchWorkItem?

    public init() {}

    public func schedule(after delay: TimeInterval, on queue: DispatchQueue = .main,
                         _ action: @escaping () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
