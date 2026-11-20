package app.keytitan

import android.os.Handler
import android.os.Looper

/** Keeps the private engine alive until Dart acknowledges key cleanup. */
internal class AutofillCleanup(
    private val revoke: () -> Unit,
    private val requestCleanup: (acknowledge: () -> Unit) -> Unit,
    private val finishHost: () -> Unit,
    private val destroyEngine: () -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) {
    private var started = false
    private var complete = false
    private var hostDestroyed = false
    private var engineDestroyed = false
    private val timeout = Runnable { finishCleanup() }

    fun cancel() {
        if (started || complete) return
        started = true
        revoke()
        // An unresponsive isolate must not retain a private engine indefinitely.
        handler.postDelayed(timeout, 5_000)
        retry()
    }

    fun retry() {
        if (started && !complete) requestCleanup { finishCleanup() }
    }

    /** Dart has already closed the vault before completing a successful fill. */
    fun released() = finishCleanup()

    fun hostDestroyed() {
        hostDestroyed = true
        if (complete) destroyOnce() else cancel()
    }

    private fun finishCleanup() {
        if (complete) return
        complete = true
        handler.removeCallbacks(timeout)
        if (hostDestroyed) destroyOnce() else finishHost()
    }

    private fun destroyOnce() {
        if (engineDestroyed) return
        engineDestroyed = true
        destroyEngine()
    }
}
