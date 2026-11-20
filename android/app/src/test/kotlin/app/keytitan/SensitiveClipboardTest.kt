package app.keytitan

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Looper
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.Mockito.*
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import org.robolectric.shadows.ShadowSystemClock
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SensitiveClipboardTest {
    private val context get() = RuntimeEnvironment.getApplication()
    @After fun cleanup() { SensitiveClipboardContent.clear() }

    @Test fun timedCopyUsesStandardTextCoercionWithoutPuttingPlaintextOnClipboard() {
        val provider = Robolectric.buildContentProvider(SensitiveClipboardProvider::class.java).create().get()
        ShadowContentResolver.registerProviderInternal("${context.packageName}.sensitive_clipboard", provider)
        SensitiveUi.copy(context, "synthetic-password", 15_000)
        val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip!!
        assertNull(clip.getItemAt(0).text)
        assertEquals("synthetic-password", clip.getItemAt(0).coerceToText(context).toString())
        assertTrue(clip.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(15))
        assertEquals("", clip.getItemAt(0).coerceToText(context).toString())
    }

    @Test fun expiryRevokesPasswordEvenWhenClipboardReadsAreDenied() {
        val clipboard = mock(ClipboardManager::class.java)
        `when`(clipboard.primaryClip).thenThrow(SecurityException("Not focused"))
        val background = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getSystemService(name: String): Any? =
                if (name == Context.CLIPBOARD_SERVICE) clipboard else super.getSystemService(name)
        }
        SensitiveUi.copy(background, "synthetic-password", 1_000)
        val clip = ArgumentCaptor.forClass(ClipData::class.java)
        verify(clipboard).setPrimaryClip(clip.capture())
        val uri = clip.value.getItemAt(0).uri!!
        assertEquals("synthetic-password", String(SensitiveClipboardContent.read(uri), Charsets.UTF_8))
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertArrayEquals(byteArrayOf(), SensitiveClipboardContent.read(uri))
        verify(clipboard, never()).clearPrimaryClip()
    }

    @Test fun expiryNeverErasesAnInterveningCopy() {
        SensitiveUi.copy(context, "synthetic-password", 1_000)
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val oldUri = clipboard.primaryClip!!.getItemAt(0).uri!!
        clipboard.setPrimaryClip(ClipData.newPlainText("Other app", "unrelated text"))
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertArrayEquals(byteArrayOf(), SensitiveClipboardContent.read(oldUri))
        assertEquals("unrelated text", clipboard.primaryClip!!.getItemAt(0).text)
    }

    @Test fun deadlineIsCheckedEvenBeforeTheExpiryCallbackRuns() {
        val uri = SensitiveClipboardContent.create(context, "synthetic-password", 1_000)
        ShadowSystemClock.advanceBy(Duration.ofSeconds(2))
        assertArrayEquals(byteArrayOf(), SensitiveClipboardContent.read(uri))
    }

    @Test fun screenOffAndReplacementRevokeTheOldClip() {
        val first = SensitiveClipboardContent.create(context, "first", 15_000)
        val second = SensitiveClipboardContent.create(context, "second", 15_000)
        assertArrayEquals(byteArrayOf(), SensitiveClipboardContent.read(first))
        context.sendBroadcast(Intent(Intent.ACTION_SCREEN_OFF))
        Shadows.shadowOf(Looper.getMainLooper()).idle()
        assertArrayEquals(byteArrayOf(), SensitiveClipboardContent.read(second))
    }

    @Test fun clipboardProviderIsPrivateAndUsesExplicitUriGrants() {
        val info = context.packageManager.resolveContentProvider("${context.packageName}.sensitive_clipboard", 0)!!
        assertFalse(info.exported)
        assertTrue(info.grantUriPermissions)
    }
}
