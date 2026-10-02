import Foundation

/// Native deadline independent of WebKit's network timeout and health-check cadence.
@MainActor
final class NavigationDeadline {
    private var task: Task<Void, Never>?
    let timeout: Duration

    init(timeout: Duration = .seconds(20)) { self.timeout = timeout }

    func start(expired: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { [timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled else { return }
            expired()
        }
    }

    func cancel() { task?.cancel(); task = nil }
}
