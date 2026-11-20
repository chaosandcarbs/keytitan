package app.keytitan

import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Base64
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.security.SecureRandom

/** Timed clips contain only an opaque URI. Password bytes never go on disk. */
internal object SensitiveClipboardContent {
    private data class Entry(val uri: Uri, val bytes: ByteArray, val expires: Long)
    private var entry: Entry? = null
    private val handler = Handler(Looper.getMainLooper())
    private var receiverContext: Context? = null
    private var expiry: Runnable? = null

    @Synchronized fun create(context: Context, text: String, lifetimeMillis: Long): Uri {
        require(lifetimeMillis in 1..60_000)
        clear()
        val app = context.applicationContext
        if (receiverContext !== app) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) { clear() }
            }
            if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver,
                IntentFilter(Intent.ACTION_SCREEN_OFF), Context.RECEIVER_NOT_EXPORTED)
            else app.registerReceiver(receiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
            receiverContext = app
        }
        val token = Base64.encodeToString(ByteArray(32).also(SecureRandom()::nextBytes),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val uri = Uri.Builder().scheme("content").authority("${app.packageName}.sensitive_clipboard")
            .appendPath("clip").appendPath(token).build()
        entry = Entry(uri, text.toByteArray(Charsets.UTF_8), SystemClock.elapsedRealtime() + lifetimeMillis)
        expiry = Runnable { synchronized(this) { if (entry?.uri == uri) clear() } }
            .also { handler.postDelayed(it, lifetimeMillis) }
        return uri
    }

    @Synchronized fun read(uri: Uri): ByteArray {
        val current = entry ?: return byteArrayOf()
        if (SystemClock.elapsedRealtime() >= current.expires) { clear(); return byteArrayOf() }
        return if (current.uri == uri) current.bytes.copyOf() else byteArrayOf()
    }

    @Synchronized fun clear() {
        expiry?.let(handler::removeCallbacks)
        expiry = null
        entry?.bytes?.fill(0)
        entry = null
    }

    @Synchronized fun expireIfNeeded() {
        entry?.let { if (SystemClock.elapsedRealtime() >= it.expires) clear() }
    }
}

/** Non-exported; Android grants readers access only through the clipboard URI. */
class SensitiveClipboardProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = "text/plain"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?,
        selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r" || uri.authority != "${context!!.packageName}.sensitive_clipboard" ||
            uri.pathSegments.size != 2 || uri.pathSegments[0] != "clip") throw FileNotFoundException()
        val bytes = SensitiveClipboardContent.read(uri)
        return try {
            openPipeHelper(uri, "text/plain", null, bytes) { output, _, _, _, value ->
                val content = value ?: byteArrayOf()
                try { FileOutputStream(output.fileDescriptor).use { it.write(content) } }
                finally { content.fill(0) }
            }
        } catch (error: Exception) { bytes.fill(0); throw error }
    }
}
