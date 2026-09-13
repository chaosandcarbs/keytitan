package app.keytitan

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.json.JSONObject
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** One selected login, one password-step tap, same Android client-state flow.
 * No vault keys/master password and no persisted quick-unlock authority.
 */
internal object AutofillContinuation {
    private data class Grant(val recipient: RecipientIdentity, val activity: String, val frame: String,
        val path: String, val digest: String, val expires: Long,
        val key: ByteArray, val iv: ByteArray, val ciphertext: ByteArray)
    data class Login(val username: String, val password: String)
    private val grants = LinkedHashMap<String, Grant>()
    private val handler = Handler(Looper.getMainLooper())
    private var receiverRegistered = false

    @Synchronized fun remember(context: Context, session: AutofillSession, path: String,
        digest: String, username: String, password: String) {
        if (session.save || session.continuation || session.flow.isEmpty() || session.parsed.registration ||
            session.parsed.usernameId == null || session.parsed.passwordId != null || password.isEmpty()) return
        if (sha256Hex(VaultCommit.file(context, path).readBytes()) != digest) return
        if (!receiverRegistered) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) { clear() }
            }
            if (Build.VERSION.SDK_INT >= 33) context.applicationContext.registerReceiver(receiver,
                IntentFilter(Intent.ACTION_SCREEN_OFF), Context.RECEIVER_NOT_EXPORTED)
            else context.applicationContext.registerReceiver(receiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
            receiverRegistered = true
        }
        clear() // A newly selected account revokes any earlier login continuation.
        val key = ByteArray(32).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
        val plain = JSONObject().put("username", username).put("password", password).toString().toByteArray(Charsets.UTF_8)
        try {
            grants[session.flow] = Grant(session.recipient, session.parsed.activity, session.parsed.frame,
                path, digest, SystemClock.elapsedRealtime() + 60_000, key, cipher.iv, cipher.doFinal(plain))
            handler.postAtTime({ remove(session.flow) }, session.flow, SystemClock.uptimeMillis() + 60_000)
        } finally { plain.fill(0) }
    }

    @Synchronized fun available(context: Context, flow: String, parsed: ParsedAutofillContext,
        recipient: RecipientIdentity): Boolean {
        val grant = grants[flow] ?: return false
        val valid = SystemClock.elapsedRealtime() < grant.expires &&
            AutofillPreferences.enabled(context) &&
            context.getSystemService(KeyguardManager::class.java)?.isDeviceLocked != true &&
            parsed.passwordId != null && !parsed.registration &&
            grant.recipient.sameRecipient(recipient) && grant.activity == parsed.activity && grant.frame == parsed.frame &&
            runCatching { sha256Hex(VaultCommit.file(context, grant.path).readBytes()) == grant.digest }.getOrDefault(false)
        if (!valid) remove(flow)
        return valid
    }

    @Synchronized fun consume(context: Context, session: AutofillSession): Login? {
        if (!session.continuation || !available(context, session.flow, session.parsed, session.recipient)) return null
        val grant = grants[session.flow] ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(grant.key, "AES"), GCMParameterSpec(128, grant.iv))
            val bytes = cipher.doFinal(grant.ciphertext)
            try {
                val json = JSONObject(String(bytes, Charsets.UTF_8))
                Login(json.getString("username"), json.getString("password"))
            } finally { bytes.fill(0) }
        } catch (_: Exception) {
            null
        } finally { remove(session.flow) }
    }
    @Synchronized fun remove(flow: String) {
        val registeredToken = grants.keys.firstOrNull { it == flow } ?: return
        grants.remove(flow)?.let { it.key.fill(0); it.iv.fill(0); it.ciphertext.fill(0) }
        handler.removeCallbacksAndMessages(registeredToken)
    }
    @Synchronized fun clear() { grants.keys.toList().forEach(::remove) }
}
