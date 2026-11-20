package app.keytitan

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import android.view.WindowManager

internal object SensitiveUi {
    fun protect(activity: Activity) {
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) activity.window.setHideOverlayWindows(true)
    }

    fun copy(context: Context, text: String, clearAfterMillis: Long? = null) {
        val clip = if (clearAfterMillis != null) {
            ClipData.newUri(context.contentResolver, "KeyTitan password",
                SensitiveClipboardContent.create(context, text, clearAfterMillis))
        } else {
            SensitiveClipboardContent.clear()
            ClipData.newPlainText("KeyTitan password", text)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean("android.content.extra.IS_SENSITIVE", true)
            }
        }
        try {
            (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
        } catch (error: Exception) { SensitiveClipboardContent.clear(); throw error }
    }
}
