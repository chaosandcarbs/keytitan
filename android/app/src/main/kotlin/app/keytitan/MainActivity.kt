package app.keytitan

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.autofill.AutofillManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var autofillChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SensitiveUi.protect(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.keytitan/security")
            .setMethodCallHandler { call, result ->
                if (call.method == "copySensitive") {
                    val text = call.argument<String>("text")
                    if (text == null) result.error("invalid", "No clipboard text", null)
                    else {
                        try {
                            SensitiveUi.copy(this, text, call.argument<Number>("clearAfterMs")?.toLong())
                            result.success(null)
                        } catch (_: Exception) { result.error("clipboard", "Could not copy password", null) }
                    }
                } else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.keytitan/vault_commit")
            .setMethodCallHandler { call, result ->
                if (call.method == "commit") VaultCommit.run(this, call.arguments as Map<*, *>, result)
                else result.notImplemented()
            }
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.keytitan/autofill"
        )
        autofillChannel = channel
        KeyTitanAutofillBridge.bind(channel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "configure" -> {
                    val args = call.arguments as? Map<*, *>
                    val enabled = args?.get("enabled") as? Boolean ?: false
                    AutofillPreferences.configure(this, enabled)
                    KeyTitanAutofillCache.configure(
                        enabled = enabled,
                        attemptWindowSeconds =
                            (args?.get("attemptWindowSeconds") as? Number)?.toLong() ?: 30L,
                    )
                    // Opening settings must not unexpectedly launch a system dialog.
                    // Selection is an explicit action via enableService.
                    result.success(null)
                }
                "updateEntries" -> {
                    val args = call.arguments as? Map<*, *>
                    val entries = args?.get("entries") as? List<*> ?: emptyList<Any>()
                    KeyTitanAutofillCache.configure(
                        enabled = true,
                        attemptWindowSeconds =
                            (args?.get("attemptWindowSeconds") as? Number)?.toLong() ?: 30L,
                    )
                    KeyTitanAutofillCache.updateEntries(
                        entries.mapNotNull { raw ->
                            val entry = raw as? Map<*, *> ?: return@mapNotNull null
                            KeyTitanAutofillEntry(
                                id = entry["id"]?.toString().orEmpty(),
                                title = entry["title"]?.toString().orEmpty(),
                                site = entry["site"]?.toString().orEmpty(),
                                username = entry["username"]?.toString().orEmpty(),
                                uris = (entry["uris"] as? List<*>)
                                    ?.map { it.toString() }
                                    ?: emptyList(),
                            )
                        },
                        vaultId = args?.get("vaultId")?.toString().orEmpty(),
                        sessionEpoch = args?.get("sessionEpoch")?.toString().orEmpty(),
                    )
                    result.success(null)
                }
                "clearEntries" -> {
                    KeyTitanAutofillCache.clearEntries()
                    result.success(null)
                }
                "clearTrust" -> {
                    AutofillTrustStore.clear(this)
                    AutofillSessions.clear()
                    result.success(null)
                }
                "rememberVault" -> {
                    val path = call.argument<String>("path").orEmpty()
                    try {
                        AutofillPreferences.remember(this, VaultCommit.file(this, path).path)
                        result.success(null)
                    } catch (_: Exception) { result.error("path", "Invalid vault path", null) }
                }
                "status" -> result.success(mapOf(
                    "enabled" to AutofillPreferences.enabled(this),
                    "selected" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        getSystemService(AutofillManager::class.java)?.hasEnabledAutofillServices() == true),
                    "lastResult" to AutofillPreferences.diagnostic(this),
                ))
                "enableService" -> { requestAutofillServiceEnable(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        autofillChannel?.let { KeyTitanAutofillBridge.unbind(it) }
        autofillChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) SensitiveClipboardContent.expireIfNeeded()
    }

    private fun requestAutofillServiceEnable() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val autofillManager = getSystemService(AutofillManager::class.java) ?: return
        if (!autofillManager.isAutofillSupported ||
            autofillManager.hasEnabledAutofillServices()
        ) {
            return
        }

        val intent = Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE).apply {
            data = Uri.parse("package:$packageName")
        }
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            startActivity(Intent(Settings.ACTION_SETTINGS))
        }
    }
}
