package app.keytitan

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

object KeyTitanAutofillBridge {
    @Volatile
    private var channel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun bind(channel: MethodChannel) {
        this.channel = channel
    }

    fun unbind(channel: MethodChannel) {
        if (this.channel == channel) {
            this.channel = null
        }
    }

    fun resolvePassword(entryId: String, callback: (String?) -> Unit) {
        val boundChannel = channel
        if (boundChannel == null) {
            callback(null)
            return
        }

        mainHandler.post {
            boundChannel.invokeMethod(
                "resolvePassword",
                mapOf("id" to entryId),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        callback(result as? String)
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        callback(null)
                    }

                    override fun notImplemented() {
                        callback(null)
                    }
                },
            )
        }
    }
}
