// HelperCall.swift
// Shared bridge from the helper's reply-block XPC protocol to async/await — one once-only continuation resumer, one watchdog timeout, used by every privileged call site.

import Foundation

/// Wraps a `CheckedContinuation` so that exactly one of the several paths
/// that may complete a helper call actually resumes it.
///
/// A privileged call can finish three ways, and `NSXPCConnection` does not
/// promise which: the per-call reply block, the connection-level error
/// handler firing *instead of* it, or the proxy never materialising at all.
/// `CheckedContinuation` traps on a second resume, so without this guard the
/// first dropped connection mid-call would crash the app.
///
/// A class because several closures must reference it and mutate it from
/// whichever fires first; the `NSLock` covers the "two callbacks land on
/// different threads at once" race.
final class OnceResumer<Value: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var watchdog: Task<Void, Never>?

    init(continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// Resumes with `value` unless some other path already resumed, and
    /// stands the watchdog down either way.
    func resume(returning value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let timer = watchdog
        watchdog = nil
        lock.unlock()

        timer?.cancel()
        pending?.resume(returning: value)
    }

    /// Arms a timer that resumes with `value()` if nothing else has by then.
    ///
    /// The helper accepting a connection and then never replying is not
    /// hypothetical: its work queue runs `waitUntilExit()` on system tools
    /// (`periodic`, `purge`, `mdutil -E /`) that can wedge. The connection
    /// stays valid, so no error handler ever fires and the `await` would
    /// hang for the life of the process. This is the backstop — a ceiling on
    /// a stuck call, not a latency budget, so it is set generously.
    /// Captures `self` strongly on purpose. The watchdog is often the only
    /// thing still referencing the resumer — nothing else has to hold it, and
    /// a weak capture would let it deallocate before the timer fires, which
    /// silently reinstates the very hang this exists to prevent. The
    /// resumer → task → resumer cycle is broken by `resume(returning:)`
    /// clearing `watchdog`, which every path (reply, error, timeout) reaches.
    func armTimeout(_ duration: Duration, resumingWith value: @escaping @Sendable () -> Value) {
        let timer = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.resume(returning: value())
        }

        lock.lock()
        let alreadyResumed = continuation == nil
        watchdog = alreadyResumed ? nil : timer
        lock.unlock()

        // The call can resolve before the timer is stored — a helper that
        // replies synchronously does exactly that. Cancel it here rather
        // than leaving an orphan sleeping for the full duration.
        if alreadyResumed {
            timer.cancel()
        }
    }
}

/// Bridges the helper's `(reply: (Error?) -> Void)` selectors to async/await.
///
/// Every privileged call site needs the same four things: a proxy, a per-call
/// error handler, the reply block, and a guarantee that exactly one of them
/// resolves the await. This is that shape, written once. Before it existed
/// there were eight copies of the resumer alone — the same drift risk that
/// produced `UserFileRecycler`.
enum HelperCall {

    /// How long a privileged call may run before the watchdog resolves it.
    ///
    /// Ten minutes is deliberately far above any legitimate call. The
    /// longest real one is `periodic daily weekly monthly`, which is minutes
    /// on a busy machine; the point is to convert "hangs until the user
    /// force-quits" into "fails with an error the UI can show", not to
    /// second-guess how long the system tools take.
    static let defaultTimeout: Duration = .seconds(600)

    typealias HelperProvider = @Sendable (@escaping @Sendable (Error) -> Void) -> VaderCleanerHelperProtocol?

    /// Invokes one helper selector. Matches `PrivilegedTaskRunner.Invoke`:
    /// `@Sendable` because call sites hand it over from main-actor code, and
    /// the reply block is `@Sendable` because XPC delivers it on its own queue.
    typealias Invoke = @Sendable (VaderCleanerHelperProtocol, @escaping @Sendable (Error?) -> Void) -> Void

    /// Runs `body` against the helper proxy and returns the failure, if any.
    ///
    /// Returns `HelperConnectionError.unavailable` when the proxy can't be
    /// built and `.timedOut` when neither the reply nor an error arrives
    /// within `timeout`.
    static func perform(
        timeout: Duration = defaultTimeout,
        helperProvider: HelperProvider,
        _ body: Invoke
    ) async -> Error? {
        await withCheckedContinuation { continuation in
            let resumer = OnceResumer<Error?>(continuation: continuation)
            let helper = helperProvider { connectionError in
                resumer.resume(returning: connectionError)
            }
            guard let helper else {
                resumer.resume(returning: HelperConnectionError.unavailable)
                return
            }
            body(helper) { replyError in
                resumer.resume(returning: replyError)
            }
            // Armed after the call is in flight so a synchronous reply — what
            // the test doubles do — resolves first and stands it down.
            resumer.armTimeout(timeout) { HelperConnectionError.timedOut }
        }
    }
}
