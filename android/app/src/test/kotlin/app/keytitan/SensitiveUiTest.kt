package app.keytitan

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.view.WindowManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SensitiveUiTest {
    @Before fun grantOverlayHidingPermission() {
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(android.Manifest.permission.HIDE_OVERLAY_WINDOWS)
    }
    @Test fun sensitiveWindowsBlockCapture() {
        val activity = Robolectric.buildActivity(Activity::class.java).create()
        try {
            SensitiveUi.protect(activity.get())
            assertTrue(activity.get().window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        } finally { activity.destroy() }
    }

    @Test fun copiedPasswordsAreMarkedSensitive() {
        val context = RuntimeEnvironment.getApplication()
        SensitiveUi.copy(context, "test-secret")
        val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip!!
        assertEquals("test-secret", clip.getItemAt(0).text)
        assertTrue(clip.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
    }
}
