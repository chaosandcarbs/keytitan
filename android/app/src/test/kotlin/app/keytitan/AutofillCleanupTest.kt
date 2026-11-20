package app.keytitan

import android.os.Looper
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AutofillCleanupTest {
    @Test fun revokesImmediatelyAndKeepsEngineUntilCleanupAcknowledgement() {
        val events = mutableListOf<String>()
        var acknowledge: (() -> Unit)? = null
        val cleanup = AutofillCleanup(
            { events.add("revoke") }, { acknowledge = it },
            { events.add("finish") }, { events.add("destroy") })
        cleanup.cancel()
        assertEquals(listOf("revoke"), events)
        cleanup.hostDestroyed()
        assertEquals(listOf("revoke"), events)
        acknowledge!!()
        assertEquals(listOf("revoke", "destroy"), events)
        cleanup.cancel()
        acknowledge!!()
        cleanup.hostDestroyed()
        assertEquals(listOf("revoke", "destroy"), events)
    }

    @Test fun cleanupFinishesHostBeforeDestroyingEngine() {
        val events = mutableListOf<String>()
        var acknowledge: (() -> Unit)? = null
        val cleanup = AutofillCleanup(
            { events.add("revoke") }, { acknowledge = it },
            { events.add("finish") }, { events.add("destroy") })
        cleanup.cancel()
        acknowledge!!()
        assertEquals(listOf("revoke", "finish"), events)
        cleanup.hostDestroyed()
        assertEquals(listOf("revoke", "finish", "destroy"), events)
    }

    @Test fun unresponsiveEngineHasBoundedLifetimeAndLateAckIsIgnored() {
        val events = mutableListOf<String>()
        var acknowledge: (() -> Unit)? = null
        val cleanup = AutofillCleanup(
            { events.add("revoke") }, { acknowledge = it },
            { events.add("finish") }, { events.add("destroy") })
        cleanup.cancel()
        cleanup.hostDestroyed()
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(5))
        assertEquals(listOf("revoke", "destroy"), events)
        acknowledge!!()
        assertEquals(listOf("revoke", "destroy"), events)
    }

    @Test fun completedReleaseDoesNotRequestAnotherCleanup() {
        val events = mutableListOf<String>()
        val cleanup = AutofillCleanup(
            { events.add("revoke") }, { events.add("cleanup") },
            { events.add("finish") }, { events.add("destroy") })
        cleanup.released()
        cleanup.hostDestroyed()
        assertEquals(listOf("finish", "destroy"), events)
    }
}
