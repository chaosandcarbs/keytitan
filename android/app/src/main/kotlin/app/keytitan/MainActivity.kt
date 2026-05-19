package app.keytitan

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.autofill.AutofillManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var autofillChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                    KeyTitanAutofillCache.configure(
                        enabled = enabled,
                        attemptWindowSeconds =
                            (args?.get("attemptWindowSeconds") as? Number)?.toLong() ?: 30L,
                    )
                    if (enabled) {
                        requestAutofillServiceEnable()
                    }
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
                        }
                    )
                    result.success(null)
                }
                "clearEntries" -> {
                    KeyTitanAutofillCache.clearEntries()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        autofillChannel?.let { KeyTitanAutofillBridge.unbind(it) }
        autofillChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
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
