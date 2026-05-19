package app.keytitan

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
    private var lastAttemptAtMillis: Long = 0L

    @Synchronized
    fun configure(enabled: Boolean, attemptWindowSeconds: Long) {
        this.enabled = enabled
        attemptWindowMillis = attemptWindowSeconds.coerceAtLeast(15L) * 1000L
        if (!enabled) entries = emptyList()
    }

    @Synchronized
    fun updateEntries(entries: List<KeyTitanAutofillEntry>) {
        this.entries = entries
    }

    @Synchronized
    fun clearEntries() {
        entries = emptyList()
        lastAttemptAtMillis = 0L
    }

    fun snapshot(): KeyTitanAutofillSnapshot {
        return KeyTitanAutofillSnapshot(enabled, attemptWindowMillis, entries)
    }

    @Synchronized
    fun consumeAttempt(): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastAttemptAtMillis < attemptWindowMillis) return false
        lastAttemptAtMillis = now
        return true
    }
}
