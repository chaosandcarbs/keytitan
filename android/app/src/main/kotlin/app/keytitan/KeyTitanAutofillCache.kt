package app.keytitan

import android.os.SystemClock

data class KeyTitanAutofillEntry(
    val id: String,
    val title: String,
    val site: String,
    val username: String,
    val uris: List<String>,
)

data class KeyTitanAutofillSnapshot(
    val enabled: Boolean,
    val attemptWindowMillis: Long,
    val vaultId: String,
    val sessionEpoch: String,
    val entries: List<KeyTitanAutofillEntry>,
)

object KeyTitanAutofillCache {
    @Volatile
    private var enabled: Boolean = false

    @Volatile
    private var attemptWindowMillis: Long = 30_000L

    @Volatile
    private var entries: List<KeyTitanAutofillEntry> = emptyList()

    @Volatile
    private var vaultId: String = ""

    @Volatile
    private var sessionEpoch: String = ""

    private val lastAttemptByCaller = mutableMapOf<String, Long>()

    @Synchronized
    fun configure(enabled: Boolean, attemptWindowSeconds: Long) {
        this.enabled = enabled
        attemptWindowMillis = attemptWindowSeconds.coerceAtLeast(15L) * 1000L
        if (!this.enabled) clearEntries()
    }

    @Synchronized
    fun updateEntries(
        entries: List<KeyTitanAutofillEntry>,
        vaultId: String,
        sessionEpoch: String,
    ) {
        if (!enabled || vaultId.isBlank() || sessionEpoch.isBlank()) {
            clearEntries()
            return
        }
        // Any metadata mutation invalidates in-flight authority, even within the
        // same unlocked session.
        KeyTitanCapabilityStore.clear()
        this.vaultId = vaultId
        this.sessionEpoch = sessionEpoch
        this.entries = entries.filter { it.id.isNotBlank() }
    }

    @Synchronized
    fun clearEntries() {
        entries = emptyList()
        vaultId = ""
        sessionEpoch = ""
        lastAttemptByCaller.clear()
        KeyTitanCapabilityStore.clear()
    }

    @Synchronized
    fun snapshot(): KeyTitanAutofillSnapshot {
        return KeyTitanAutofillSnapshot(
            enabled,
            attemptWindowMillis,
            vaultId,
            sessionEpoch,
            entries,
        )
    }

    @Synchronized
    fun consumeAttempt(callerKey: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        val lastAttempt = lastAttemptByCaller[callerKey]
        if (lastAttempt != null && now - lastAttempt < attemptWindowMillis) return false
        lastAttemptByCaller[callerKey] = now
        if (lastAttemptByCaller.size > 64) {
            val cutoff = now - attemptWindowMillis
            lastAttemptByCaller.entries.removeAll { it.value < cutoff }
        }
        return true
    }
}
