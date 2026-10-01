import Foundation

/// The server can be healthy while its WebKit page stops answering.
/// A native deadline must not wait for the page's JavaScript callback.
@MainActor
final class PageWatchdog {
    typealias Reply = @MainActor @Sendable (Bool) -> Void
    private let timeout: Duration
    private let probe: (@escaping Reply) -> Void
    private let recover: () -> Void
    private var deadline: Task<Void, Never>?
    private var pending: UUID?
    private var failures = 0
    var isChecking: Bool { pending != nil }

    init(timeout: Duration = .seconds(5), probe: @escaping (@escaping Reply) -> Void,
         recover: @escaping () -> Void) {
        self.timeout = timeout
        self.probe = probe
        self.recover = recover
    }

    func check() {
        guard pending == nil else { return }
        let id = UUID()
        pending = id
        deadline = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(id: id, responsive: false)
        }
        probe { [weak self] responsive in
            self?.finish(id: id, responsive: responsive)
        }
    }

    /// Navigation, hiding, and sleep invalidate any response from the previous page.
    func reset() {
        deadline?.cancel()
        deadline = nil
        pending = nil
        failures = 0
    }

    private func finish(id: UUID, responsive: Bool) {
        guard pending == id else { return }
        deadline?.cancel()
        deadline = nil
        pending = nil
        failures = responsive ? 0 : failures + 1
        guard failures >= 2 else { return }
        reset()
        recover()
    }
}
