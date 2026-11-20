package app.keytitan

import android.app.assist.AssistStructure
import android.content.Context
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.autofill.AutofillId
import java.security.SecureRandom

internal data class AutofillSession(
    val token: String,
    val parsed: ParsedAutofillContext,
    val recipient: RecipientIdentity,
    val expires: Long,
    val save: Boolean = false,
    var username: String = "",
    var password: String = "",
    val flow: String = "",
    val continuation: Boolean = false,
)

/** Opaque, bounded authority. No secrets in intents, logs, or disk caches. */
internal object AutofillSessions {
    private val pending = LinkedHashMap<String, AutofillSession>()
    private val claimed = mutableSetOf<String>()
    private val revocationListeners = mutableMapOf<String, () -> Unit>()
    private val expiryHandler = Handler(Looper.getMainLooper())
    @Synchronized fun create(
        parsed: ParsedAutofillContext, recipient: RecipientIdentity,
        save: Boolean = false, username: String = "", password: String = "",
        flow: String = "", continuation: Boolean = false,
    ): AutofillSession {
        pending.values.filter { SystemClock.elapsedRealtime() >= it.expires }.forEach { remove(it.token) }
        while (pending.size >= 32) remove(pending.keys.first())
        val token = Base64.encodeToString(ByteArray(32).also(SecureRandom()::nextBytes), Base64.NO_WRAP or Base64.URL_SAFE)
        return AutofillSession(token, parsed, recipient, SystemClock.elapsedRealtime() + 180_000,
            save, username, password, flow, continuation).also {
                pending[token] = it
                expiryHandler.postAtTime({ remove(token) }, token, SystemClock.uptimeMillis() + 180_000)
            }
    }
    @Synchronized fun get(token: String): AutofillSession? = pending[token]?.takeIf {
        SystemClock.elapsedRealtime() < it.expires
    }
    @Synchronized fun claim(token: String): AutofillSession? {
        val session = get(token) ?: return null
        return if (claimed.add(token)) session else null
    }
    @Synchronized fun remove(token: String) {
        pending.remove(token)?.let {
            expiryHandler.removeCallbacksAndMessages(it.token)
            it.username = ""; it.password = ""
        }
        claimed.remove(token)
        revocationListeners.remove(token)?.let { callback -> expiryHandler.post { callback() } }
    }
    @Synchronized fun onRevoked(token: String, callback: () -> Unit) {
        if (get(token) == null) expiryHandler.post { callback() }
        else revocationListeners[token] = callback
    }
    @Synchronized fun clear() {
        pending.keys.toList().forEach(::remove)
        AutofillContinuation.clear()
    }
    fun valid(context: Context, session: AutofillSession): Boolean {
        if (get(session.token) !== session || !AutofillPreferences.enabled(context)) return false
        val current = AutofillRecipientVerifier.identify(context, session.parsed) ?: return false
        return current.sameRecipient(session.recipient) && allowed(context, current)
    }
    fun allowed(context: Context, recipient: RecipientIdentity): Boolean =
        '+' !in recipient.currentCertificate && when (recipient.kind) {
        RecipientKind.BROWSER -> recipient.origin?.startsWith("https://") == true &&
            BrowserCertificates.trusted(recipient.packageName, recipient.allCertificates)
        RecipientKind.WEBVIEW -> recipient.origin?.startsWith("https://") == true &&
            AutofillRecipientVerifier.approvalRequirement(context, recipient) == ApprovalRequirement.NONE
        RecipientKind.NATIVE_APP -> true // Fill requires exact package+certificate binding.
    }
    fun binding(recipient: RecipientIdentity): String = recipient.origin ?:
        "androidapp://${recipient.packageName}?sha256_cert=${recipient.currentCertificate}"
    fun value(structure: AssistStructure, id: AutofillId?): String? {
        if (id == null) return null
        fun visit(node: AssistStructure.ViewNode): String? {
            if (node.autofillId == id) return node.autofillValue?.takeIf { it.isText }?.textValue?.toString()
            for (i in 0 until node.childCount) visit(node.getChildAt(i))?.let { return it }
            return null
        }
        for (i in 0 until structure.windowNodeCount) visit(structure.getWindowNodeAt(i).rootViewNode)?.let { return it }
        return null
    }
}

internal object AutofillPreferences {
    private fun prefs(context: Context) = context.getSharedPreferences("autofill_config_v2", Context.MODE_PRIVATE)
    fun enabled(context: Context) = prefs(context).getBoolean("enabled", true)
    fun configure(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean("enabled", enabled).apply()
        if (!enabled) AutofillSessions.clear()
    }
    fun remember(context: Context, path: String) { prefs(context).edit().putString("vault", path).apply() }
    fun vault(context: Context): String = prefs(context).getString("vault", "").orEmpty()
    // Only reason codes; never domains, accounts, form values, or tokens.
    fun diagnostic(context: Context, reason: String) { prefs(context).edit().putString("last_result", reason).apply() }
    fun diagnostic(context: Context) = prefs(context).getString("last_result", "no_request_received")
}
