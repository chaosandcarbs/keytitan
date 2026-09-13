package app.keytitan

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/** One process-wide commit queue shared by the main and autofill Flutter engines. */
internal object VaultCommit {
    private val executor = Executors.newSingleThreadExecutor()
    fun file(context: Context, path: String): File {
        val file = File(path).canonicalFile
        val documents = File(context.applicationInfo.dataDir, "app_flutter").canonicalFile
        require(file.parentFile == documents && file.name.endsWith(".ktn", true)) { "Invalid vault location" }
        return file
    }
    fun commit(context: Context, args: Map<*, *>, valid: () -> Boolean = { true }) {
        check(valid()) { "Request expired" }
        val target = file(context, args["path"] as String)
        val bytes = args["bytes"] as ByteArray
        val expected = args["expected"] as? String
        val current = if (target.exists()) sha256Hex(target.readBytes()) else null
        check(current == expected) { "Vault changed in another session. Reopen it before saving." }
        val temp = File.createTempFile(".vault-", ".tmp", target.parentFile)
        try {
            FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
            // Cancellation/disable and the final rename have one ordering point.
            synchronized(AutofillSessions) {
                check(valid()) { "Request expired" }
                check(temp.renameTo(target)) { "Could not commit vault" }
            }
        } finally { if (temp.exists()) temp.delete() }
    }
    fun run(context: Context, args: Map<*, *>, result: MethodChannel.Result, valid: () -> Boolean = { true }) {
        executor.execute {
            try {
                commit(context, args, valid)
                Handler(Looper.getMainLooper()).post { result.success(null) }
            } catch (_: Exception) {
                Handler(Looper.getMainLooper()).post {
                    result.error("vault_conflict", "Vault changed or could not be saved. Reopen it and retry.", null)
                }
            }
        }
    }
}
