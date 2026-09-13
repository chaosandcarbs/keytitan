package app.keytitan

import android.app.assist.AssistStructure
import android.content.ComponentName
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.Signature
import android.content.pm.SigningInfo
import android.os.CancellationSignal
import android.os.Looper
import android.service.autofill.*
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import org.junit.Assert.*
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.*
import org.mockito.ArgumentCaptor
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers
import java.io.File
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AutofillSecurityTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val cert = "A".repeat(64)
    private fun recipient(origin: String? = "https://example.com", kind: RecipientKind = RecipientKind.BROWSER) =
        RecipientIdentity("com.example.app", cert, setOf(cert), origin, origin, kind)
    private fun entry(uri: String) = KeyTitanAutofillEntry("1", "Title", uri, "alice", listOf(uri))
    private fun node(hint: String? = null, focused: Boolean = false): AssistStructure.ViewNode {
        val node = mock(AssistStructure.ViewNode::class.java)
        `when`(node.autofillId).thenReturn(mock(AutofillId::class.java))
        `when`(node.autofillType).thenReturn(if (hint == null) View.AUTOFILL_TYPE_NONE else View.AUTOFILL_TYPE_TEXT)
        `when`(node.autofillHints).thenReturn(hint?.let { arrayOf(it) })
        `when`(node.isFocused).thenReturn(focused)
        `when`(node.isEnabled).thenReturn(true)
        `when`(node.alpha).thenReturn(1f)
        `when`(node.width).thenReturn(100)
        `when`(node.height).thenReturn(40)
        return node
    }
    private fun structure(vararg fields: AssistStructure.ViewNode): AssistStructure {
        val root = node(focused = true) // Browser container and its virtual input both focused.
        `when`(root.webDomain).thenReturn("example.com")
        `when`(root.webScheme).thenReturn("https")
        `when`(root.childCount).thenReturn(fields.size)
        fields.forEachIndexed { i, field -> `when`(root.getChildAt(i)).thenReturn(field) }
        val window = mock(AssistStructure.WindowNode::class.java)
        `when`(window.rootViewNode).thenReturn(root)
        return mock(AssistStructure::class.java).also {
            `when`(it.activityComponent).thenReturn(ComponentName("com.example.app", "Login"))
            `when`(it.windowNodeCount).thenReturn(1)
            `when`(it.getWindowNodeAt(0)).thenReturn(window)
        }
    }

    @After fun cleanup() { AutofillSessions.clear() }

    @Test fun canonicalOriginsAreExactAndIdnaAware() {
        assertEquals("https://example.com", canonicalOrigin("HTTPS://Example.com:443/login", false))
        assertEquals("https://xn--bcher-kva.example", canonicalOrigin("https://bücher.example/login", false))
        assertEquals("https://example.com:8443", canonicalOrigin("example.com:8443/login", true))
        for (bad in listOf("https://user@example.com", "https://example.com:0", "https://example.com:65536",
            "https://example.com:", "https://example.com:invalid", "https://example.com.",
            "https://example.com%2fevil.com", "javascript:alert(1)", "https://evil.com\\@example.com")) {
            assertNull(bad, canonicalOrigin(bad, false))
        }
    }

    @Test fun webMatchingDoesNotWidenHostSchemeOrPort() {
        for (uri in listOf("https://www.example.com", "https://evil.example.com", "http://example.com",
            "https://example.com:8443", "https://example.com.evil.test")) {
            assertTrue(AutofillEntryMatcher.matches(listOf(entry(uri)), recipient()).isEmpty())
        }
        assertEquals(1, AutofillEntryMatcher.matches(listOf(entry("https://example.com/login")), recipient()).size)
    }

    @Test fun nativePinsCannotDegradeToUnverifiedMatches() {
        val native = recipient(null, RecipientKind.NATIVE_APP)
        assertTrue(AutofillEntryMatcher.matches(listOf(entry("androidapp://com.example.app?sha256_cert=${"B".repeat(64)}")), native).isEmpty())
        assertTrue(AutofillEntryMatcher.matches(listOf(entry("androidapp://com.example.app?sha256_cert=malformed")), native).isEmpty())
        assertTrue(AutofillEntryMatcher.matches(listOf(entry("androidapp://com.example.app?sha256_cert=$cert")), native).single().certificateBound)
        assertFalse(AutofillEntryMatcher.matches(listOf(entry("androidapp://com.example.app")), native).single().certificateBound)
    }

    @Test fun browsersRequirePinnedCertificatesAndHttpsOrigin() {
        val chrome = "F0FD6C5B410F25CB25C3B53346C8972FAE30F8EE7411DF910480AD6B2D60DB83"
        assertTrue(BrowserCertificates.trusted("com.android.chrome", setOf(chrome)))
        assertFalse(BrowserCertificates.trusted("com.android.chrome", setOf(cert)))
        assertFalse(BrowserCertificates.trusted("com.evil.browser", setOf(chrome)))
        assertFalse(BrowserCertificates.trusted("com.android.chrome", setOf(chrome, "$chrome+$cert")))
        val trusted = recipient().copy(packageName = "com.android.chrome", currentCertificate = chrome, certificateHistory = setOf(chrome))
        assertTrue(AutofillSessions.allowed(context, trusted))
        assertFalse(AutofillSessions.allowed(context, trusted.copy(origin = null)))
        assertFalse(AutofillSessions.allowed(context, trusted.copy(origin = "http://example.com")))
    }

    @Test fun focusedBrowserContainerDoesNotSuppressVirtualLoginField() {
        val user = node("username")
        val password = node("password", true)
        val parsed = AutofillRequestParser.parse(structure(user, password))!!
        assertEquals(password.autofillId, parsed.passwordId)
        assertEquals(user.autofillId, parsed.usernameId)
        assertEquals("https://example.com", parsed.origin)
    }

    private fun children(parent: AssistStructure.ViewNode, vararg nodes: AssistStructure.ViewNode) {
        `when`(parent.childCount).thenReturn(nodes.size)
        nodes.forEachIndexed { index, child -> `when`(parent.getChildAt(index)).thenReturn(child) }
    }
    private fun html(node: AssistStructure.ViewNode, tag: String, vararg attributes: Pair<String, String>) {
        val info = mock(android.view.ViewStructure.HtmlInfo::class.java)
        `when`(info.tag).thenReturn(tag)
        `when`(info.attributes).thenReturn(attributes.map { android.util.Pair(it.first, it.second) })
        `when`(node.htmlInfo).thenReturn(info)
    }

    @Test fun layoutWrappersAndRepeatedFieldDomainsDoNotSplitOneLogin() {
        val user = node("username", true)
        val password = node("password")
        for (field in listOf(user, password)) {
            `when`(field.webDomain).thenReturn("example.com")
            `when`(field.webScheme).thenReturn("https")
        }
        val left = node().also { children(it, user) }
        val right = node().also { children(it, password) }
        val tree = structure(left, right)
        val parsed = AutofillRequestParser.parse(tree)!!
        assertEquals(user.autofillId, parsed.usernameId)
        assertEquals(password.autofillId, parsed.passwordId)
        `when`(user.isFocused).thenReturn(false)
        assertEquals(parsed.contextFingerprint, AutofillRequestParser.parse(tree, user.autofillId)!!.contextFingerprint)
    }

    @Test fun separateFormsWithDuplicateNamesAndSameOriginFramesStaySeparate() {
        val user = node("username", true)
        val password = node("password")
        val first = node().also { html(it, "form", "id" to "login"); children(it, user) }
        val second = node().also { html(it, "form", "id" to "login"); children(it, password) }
        assertNull(AutofillRequestParser.parse(structure(first, second))!!.passwordId)
        val frame = node().also {
            html(it, "iframe")
            `when`(it.webDomain).thenReturn("example.com")
            `when`(it.webScheme).thenReturn("https")
            children(it, password)
        }
        assertNull(AutofillRequestParser.parse(structure(user, frame))!!.passwordId)
        `when`(frame.webDomain).thenReturn(null)
        assertNull(AutofillRequestParser.parse(structure(user, frame))!!.passwordId)
    }

    private fun withContinuation(action: (AutofillSession, ParsedAutofillContext, File) -> Unit) {
        AutofillPreferences.configure(context, true)
        val dir = File(context.applicationInfo.dataDir, "app_flutter").apply { mkdirs() }
        val file = File(dir, "continuation.ktn").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val first = AutofillRequestParser.parse(structure(node("username", true)))!!
        val next = AutofillRequestParser.parse(structure(node("password", true)))!!
        val session = AutofillSessions.create(first, recipient(), flow = "opaque-android-session")
        try {
            AutofillContinuation.remember(context, session, file.path, sha256Hex(file.readBytes()), "alice", "selected-secret")
            action(session, next, file)
        } finally { AutofillSessions.clear(); file.delete() }
    }

    @Test fun sameAndroidLoginCanContinueOnceWithoutRetainingVaultKeys() = withContinuation { first, next, _ ->
        assertFalse(AutofillContinuation.available(context, "another-flow", next, recipient()))
        assertTrue(AutofillContinuation.available(context, first.flow, next, recipient()))
        val step = AutofillSessions.create(next, recipient(), flow = first.flow, continuation = true)
        assertEquals(AutofillContinuation.Login("alice", "selected-secret"), AutofillContinuation.consume(context, step))
        assertNull(AutofillContinuation.consume(context, step))
    }

    @Test fun continuationRejectsChangedOriginCertificateActivityFrameAndRegistration() {
        val variants = listOf<(ParsedAutofillContext) -> ParsedAutofillContext>(
            { it.copy(activity = "other/activity") }, { it.copy(frame = "other/frame") }, { it.copy(registration = true) })
        for (change in variants) withContinuation { first, next, _ ->
            assertFalse(AutofillContinuation.available(context, first.flow, change(next), recipient()))
        }
        for (identity in listOf(recipient("https://evil.example"), recipient().copy(currentCertificate = "B".repeat(64)))) {
            withContinuation { first, next, _ -> assertFalse(AutofillContinuation.available(context, first.flow, next, identity)) }
        }
    }

    @Test fun continuationRejectsVaultChangesTimeoutDisableAndScreenLock() {
        withContinuation { first, next, file ->
            file.writeBytes(byteArrayOf(9))
            assertFalse(AutofillContinuation.available(context, first.flow, next, recipient()))
        }
        withContinuation { first, next, _ ->
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(61))
            assertFalse(AutofillContinuation.available(context, first.flow, next, recipient()))
        }
        withContinuation { first, next, _ ->
            AutofillPreferences.configure(context, false)
            assertFalse(AutofillContinuation.available(context, first.flow, next, recipient()))
        }
        withContinuation { first, next, _ ->
            context.sendBroadcast(android.content.Intent(android.content.Intent.ACTION_SCREEN_OFF))
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertFalse(AutofillContinuation.available(context, first.flow, next, recipient()))
        }
    }

    @Test fun ambiguousPairingOnlyFillsFocusedField() {
        val password = node("password", true)
        val parsed = AutofillRequestParser.parse(structure(node("username"), node("username"), password))!!
        assertNull(parsed.usernameId)
        assertEquals(password.autofillId, parsed.passwordId)
        assertNull(AutofillRequestParser.parse(structure(node("username", true), password)))
    }

    @Test fun hiddenDisabledAndOtpFieldsAreRejected() {
        val password = node("password", true)
        `when`(password.visibility).thenReturn(View.INVISIBLE)
        assertNull(AutofillRequestParser.parse(structure(password)))
        `when`(password.visibility).thenReturn(View.VISIBLE)
        `when`(password.isEnabled).thenReturn(false)
        assertNull(AutofillRequestParser.parse(structure(password)))
        assertNull(AutofillRequestParser.parse(structure(node("one-time-code", true))))
    }

    @Test fun crossOriginFieldsAreNotPaired() {
        val username = node("username")
        `when`(username.webDomain).thenReturn("evil.example")
        `when`(username.webScheme).thenReturn("https")
        val parsed = AutofillRequestParser.parse(structure(username, node("password", true)))!!
        assertNull(parsed.usernameId)
    }

    @Test fun registrationHasDistinctFingerprintAndCreateOnlyMode() {
        val password = node("password", true)
        val tree = structure(password)
        val login = AutofillRequestParser.parse(tree)!!
        `when`(password.autofillHints).thenReturn(arrayOf("newPassword"))
        val registration = AutofillRequestParser.parse(tree)!!
        assertTrue(registration.registration)
        assertNotEquals(login.contextFingerprint, registration.contextFingerprint)
    }

    @Test fun saveCanRevalidateOriginalFieldAfterItLosesFocus() {
        val password = node("password", true)
        val tree = structure(password)
        val original = AutofillRequestParser.parse(tree)!!
        `when`(password.isFocused).thenReturn(false)
        assertNull(AutofillRequestParser.parse(tree))
        assertEquals(original.contextFingerprint, AutofillRequestParser.parse(tree, password.autofillId)!!.contextFingerprint)
    }

    @Test fun oversizedStructuresFailClosed() {
        val tree = structure(node("password", true))
        `when`(tree.getWindowNodeAt(0).rootViewNode.childCount).thenReturn(4097)
        assertNull(AutofillRequestParser.parse(tree))
    }

    private fun nativeRequest(password: AssistStructure.ViewNode): AssistStructure {
        val tree = structure(node("username"), password)
        `when`(tree.getWindowNodeAt(0).rootViewNode.webDomain).thenReturn(null)
        val signing = ReflectionHelpers.newInstance(SigningInfo::class.java)
        val signature = Signature("01020304")
        Shadows.shadowOf(signing).setSignatures(arrayOf(signature))
        Shadows.shadowOf(signing).setPastSigningCertificates(arrayOf(signature))
        val info = PackageInfo().apply {
            packageName = "com.example.app"
            applicationInfo = ApplicationInfo().apply { packageName = "com.example.app" }
            signingInfo = signing
        }
        Shadows.shadowOf(context.packageManager).installPackage(info)
        AutofillPreferences.configure(context, true)
        return tree
    }

    private fun requestFill(service: KeyTitanAutofillService, tree: AssistStructure, state: android.os.Bundle? = null): FillResponse {
        val fillContext = mock(FillContext::class.java)
        `when`(fillContext.structure).thenReturn(tree)
        val request = mock(FillRequest::class.java)
        `when`(request.fillContexts).thenReturn(listOf(fillContext))
        `when`(request.clientState).thenReturn(state)
        val callback = mock(FillCallback::class.java)
        service.onFillRequest(request, CancellationSignal(), callback)
        val response = ArgumentCaptor.forClass(FillResponse::class.java)
        verify(callback).onSuccess(response.capture())
        assertNotNull(AutofillPreferences.diagnostic(context), response.value)
        return response.value
    }

    @Test fun serviceOffersAuthenticatedDatasetAndSaveWithoutAnUnlockedVault() {
        val tree = nativeRequest(node("password", true))
        val controller = Robolectric.buildService(KeyTitanAutofillService::class.java).create()
        try {
            val response = requestFill(controller.get(), tree)
            val datasets = ReflectionHelpers.callInstanceMethod<List<Dataset>>(response, "getDatasets")
            assertNotNull(ReflectionHelpers.callInstanceMethod<android.content.IntentSender>(datasets.single(), "getAuthentication"))
            val values = ReflectionHelpers.callInstanceMethod<List<AutofillValue?>>(datasets.single(), "getFieldValues")
            assertTrue(values.all { it == null })
            assertNotNull(ReflectionHelpers.callInstanceMethod<SaveInfo>(response, "getSaveInfo"))
            assertNotNull(ReflectionHelpers.callInstanceMethod<android.os.Bundle>(response, "getClientState").getString("save"))
            // A second ordinary focus request is not throttled by the previous one.
            assertNotNull(requestFill(controller.get(), tree))
        } finally { controller.destroy() }
    }

    @Test fun passwordStepUsesPrivateContinuationActivityAndCannotReplay() {
        nativeRequest(node("password", true)) // Install the signed native test requester.
        val tree = structure(node("username", true))
        `when`(tree.getWindowNodeAt(0).rootViewNode.webDomain).thenReturn(null)
        val controller = Robolectric.buildService(KeyTitanAutofillService::class.java).create()
        val dir = File(context.applicationInfo.dataDir, "app_flutter").apply { mkdirs() }
        val file = File(dir, "step.ktn").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        try {
            val response = requestFill(controller.get(), tree)
            val state = ReflectionHelpers.callInstanceMethod<android.os.Bundle>(response, "getClientState")
            val parsed = AutofillRequestParser.parse(tree)!!
            val identity = AutofillRecipientVerifier.identify(context, parsed)!!
            val chosen = AutofillSessions.create(parsed, identity, flow = state.getString("flow")!!)
            AutofillContinuation.remember(context, chosen, file.path, sha256Hex(file.readBytes()), "alice", "selected-secret")
            val nextTree = nativeRequest(node("password", true))
            val nextResponse = requestFill(controller.get(), nextTree, state)
            assertEquals("continuation_offered", AutofillPreferences.diagnostic(context))
            val nextState = ReflectionHelpers.callInstanceMethod<android.os.Bundle>(nextResponse, "getClientState")
            assertEquals(chosen.flow, nextState.getString("flow"))
            val nextParsed = AutofillRequestParser.parse(nextTree)!!
            val step = AutofillSessions.create(nextParsed, identity, flow = chosen.flow, continuation = true)
            val intent = android.content.Intent(context, KeyTitanAutofillContinueActivity::class.java)
                .putExtra("token", step.token)
                .putExtra(android.view.autofill.AutofillManager.EXTRA_ASSIST_STRUCTURE, nextTree)
            val activity = Robolectric.buildActivity(KeyTitanAutofillContinueActivity::class.java, intent).create()
            assertEquals(android.app.Activity.RESULT_OK, Shadows.shadowOf(activity.get()).resultCode)
            @Suppress("DEPRECATION")
            val result = Shadows.shadowOf(activity.get()).resultIntent.getParcelableExtra<Dataset>(android.view.autofill.AutofillManager.EXTRA_AUTHENTICATION_RESULT)!!
            val values = ReflectionHelpers.callInstanceMethod<List<AutofillValue>>(result, "getFieldValues")
            assertTrue(values.any { it.textValue == "selected-secret" })
            activity.destroy()
            val replay = Robolectric.buildActivity(KeyTitanAutofillContinueActivity::class.java, intent).create()
            assertEquals(android.app.Activity.RESULT_CANCELED, Shadows.shadowOf(replay.get()).resultCode)
            replay.destroy()
        } finally { controller.destroy(); file.delete() }
    }

    @Test fun saveRequestDefersToPrivateActivityAndRejectsReplay() {
        val password = node("password", true)
        val tree = nativeRequest(password)
        val controller = Robolectric.buildService(KeyTitanAutofillService::class.java).create()
        try {
            val response = requestFill(controller.get(), tree)
            `when`(password.isFocused).thenReturn(false)
            `when`(password.autofillValue).thenReturn(AutofillValue.forText("typed-secret"))
            val fillContext = mock(FillContext::class.java)
            `when`(fillContext.structure).thenReturn(tree)
            val request = mock(SaveRequest::class.java)
            `when`(request.clientState).thenReturn(ReflectionHelpers.callInstanceMethod<android.os.Bundle>(response, "getClientState"))
            `when`(request.fillContexts).thenReturn(listOf(fillContext))
            val callback = mock(SaveCallback::class.java)
            controller.get().onSaveRequest(request, callback)
            verify(callback).onSuccess(any(android.content.IntentSender::class.java))
            val replay = mock(SaveCallback::class.java)
            controller.get().onSaveRequest(request, replay)
            verify(replay).onFailure(any(CharSequence::class.java))
        } finally { controller.destroy() }
    }

    @Test fun sessionTokensAreSingleOwnerExpiringAndRevocable() {
        val parsed = AutofillRequestParser.parse(structure(node("password", true)))!!
        val session = AutofillSessions.create(parsed, recipient(), true, "alice", "temporary-secret")
        assertSame(session, AutofillSessions.claim(session.token))
        assertNull(AutofillSessions.claim(session.token))
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(4))
        assertNull(AutofillSessions.get(session.token))
        assertEquals("", session.password)
        val next = AutofillSessions.create(parsed, recipient())
        AutofillSessions.clear()
        assertNull(AutofillSessions.claim(next.token))
    }

    @Test fun commitsRejectStaleWritesExpiredRequestsAndOutsidePaths() {
        val dir = File(context.applicationInfo.dataDir, "app_flutter").apply { mkdirs() }
        val target = File(dir, "test.ktn")
        target.delete()
        try {
            val first = byteArrayOf(1, 2, 3)
            VaultCommit.commit(context, mapOf("path" to target.path, "expected" to null, "bytes" to first))
            assertArrayEquals(first, target.readBytes())
            assertThrows(IllegalStateException::class.java) {
                VaultCommit.commit(context, mapOf("path" to target.path, "expected" to null, "bytes" to byteArrayOf(9)))
            }
            val next = mapOf("path" to target.path, "expected" to sha256Hex(first), "bytes" to byteArrayOf(4, 5))
            var validations = 0
            assertThrows(IllegalStateException::class.java) {
                VaultCommit.commit(context, next) { ++validations == 1 }
            }
            assertArrayEquals(first, target.readBytes())
            assertEquals(listOf("test.ktn"), dir.list()!!.toList())
            VaultCommit.commit(context, next)
            assertArrayEquals(byteArrayOf(4, 5), target.readBytes())
            assertThrows(IllegalArgumentException::class.java) { VaultCommit.file(context, File(dir, "../outside.ktn").path) }
        } finally { target.delete() }
    }
}
