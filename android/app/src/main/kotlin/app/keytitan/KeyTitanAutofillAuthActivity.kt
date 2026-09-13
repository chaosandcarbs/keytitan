package app.keytitan

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Separate engine/short-lived vault session; cold-starts without the main activity. */
class KeyTitanAutofillAuthActivity : FlutterActivity() {
    private var session: AutofillSession? = null
    private val handler = Handler(Looper.getMainLooper())
    private val expire = Runnable { cancel() }
    private var released = false
    private var eligible = emptySet<String>()
    private var contextDelivered = false
    override fun getDartEntrypointFunctionName() = "autofillMain"
    override fun shouldDestroyEngineWithHost() = true
    override fun onCreate(savedInstanceState: Bundle?) {
        session = AutofillSessions.claim(intent.getStringExtra("token").orEmpty())
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) window.setHideOverlayWindows(true)
        if (savedInstanceState != null || !valid()) { cancel(); return }
        handler.postDelayed(expire, 180_000)
    }
    private fun valid(): Boolean {
        val current = session ?: return false
        if (released || !AutofillSessions.valid(this, current)) return false
        if (current.save) return true
        @Suppress("DEPRECATION")
        val structure = intent.getParcelableExtra<android.app.assist.AssistStructure>(AutofillManager.EXTRA_ASSIST_STRUCTURE)
            ?: return false
        val parsed = AutofillRequestParser.parse(structure, current.parsed.focusedId) ?: return false
        return parsed.contextFingerprint == current.parsed.contextFingerprint
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.keytitan/vault_commit")
            .setMethodCallHandler { call, result ->
                if (call.method != "commit" || !valid()) result.error("expired", "Request expired", null)
                else VaultCommit.run(this, call.arguments as Map<*, *>, result) {
                    session?.let { AutofillSessions.valid(this, it) } == true
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.keytitan/autofill_session")
            .setMethodCallHandler { call, result ->
                if (call.method == "cancel") { result.success(null); cancel(); return@setMethodCallHandler }
                if (!valid()) { result.error("expired", "Request expired. Tap the field again.", null); cancel(); return@setMethodCallHandler }
                val current = session!!
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                when (call.method) {
                    "context" -> {
                        if (contextDelivered) { result.error("replay", "Context already delivered", null); return@setMethodCallHandler }
                        contextDelivered = true
                        result.success(mapOf(
                        "destination" to current.recipient.destinationLabel(),
                        "binding" to AutofillSessions.binding(current.recipient),
                        "vault" to AutofillPreferences.vault(this),
                        "save" to current.save,
                        "registration" to current.parsed.registration,
                        "needsPassword" to (!current.save && !current.parsed.registration || current.parsed.passwordId != null),
                        "username" to current.username,
                        "password" to current.password,
                        ))
                        current.username = ""
                        current.password = ""
                    }
                    "remember" -> {
                        try {
                            val path = VaultCommit.file(this, args["path"] as String).path
                            AutofillPreferences.remember(this, path)
                            result.success(null)
                        } catch (_: Exception) { result.error("path", "Select a vault in KeyTitan app storage.", null) }
                    }
                    "matches" -> {
                        val entries = (args["entries"] as? List<*>).orEmpty().mapNotNull { raw ->
                            val e = raw as? Map<*, *> ?: return@mapNotNull null
                            KeyTitanAutofillEntry(e["id"].toString(), "", e["site"].toString(), "",
                                (e["uris"] as? List<*>)?.map { it.toString() }.orEmpty())
                        }
                        eligible = AutofillEntryMatcher.matches(entries, current.recipient)
                            .filter { current.recipient.kind != RecipientKind.NATIVE_APP || it.certificateBound }
                            .map { it.entry.id }.toSet()
                        result.success(eligible.toList())
                    }
                    "validate" -> result.success(true)
                    "finish" -> {
                        if (!current.save && args["id"].toString() !in eligible) {
                            result.error("origin", "This login is not associated with this destination.", null)
                            return@setMethodCallHandler
                        }
                        if (current.save) {
                            released = true
                            AutofillSessions.remove(current.token)
                            result.success(null)
                            finish()
                        } else {
                            val username = args["username"] as? String ?: ""
                            val password = args["password"] as? String
                            if (current.parsed.passwordId != null && password == null) {
                                result.error("password", "No password available", null)
                                return@setMethodCallHandler
                            }
                            val presentation = RemoteViews(packageName, R.layout.keytitan_autofill_dataset).apply {
                                setTextViewText(R.id.keytitan_autofill_label, "KeyTitan")
                            }
                            val dataset = android.service.autofill.Dataset.Builder(presentation)
                            current.parsed.usernameId?.let { dataset.setValue(it, AutofillValue.forText(username)) }
                            current.parsed.passwordId?.let { dataset.setValue(it, AutofillValue.forText(password!!)) }
                            val reply = Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset.build())
                            AutofillContinuation.clear()
                            if (current.parsed.passwordId == null && !current.parsed.registration && password != null) {
                                // Keep only the selected credential for this Android flow,
                                // never the master password or unlocked vault key.
                                runCatching {
                                    AutofillContinuation.remember(this, current,
                                        args["vaultPath"] as String, args["vaultDigest"] as String, username, password)
                                }
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                                reply.putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT_EPHEMERAL_DATASET, true)
                            released = true
                            AutofillSessions.remove(current.token)
                            setResult(RESULT_OK, reply)
                            result.success(null)
                            finish()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
    private fun cancel() {
        session?.let { AutofillContinuation.remove(it.flow); AutofillSessions.remove(it.token) }
        setResult(RESULT_CANCELED)
        finish()
    }
    override fun onStop() {
        super.onStop()
        // Leaving the auth screen cancels its authority; never auto-resume a release.
        if (!released && !isChangingConfigurations) cancel()
    }
    override fun onDestroy() {
        handler.removeCallbacks(expire)
        session?.let { AutofillSessions.remove(it.token) }
        session = null
        super.onDestroy()
    }
}
