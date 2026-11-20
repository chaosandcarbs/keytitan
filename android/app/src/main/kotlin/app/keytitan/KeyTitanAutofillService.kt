package app.keytitan

import android.annotation.TargetApi
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.service.autofill.*
import android.widget.RemoteViews
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.v1.InlineSuggestionUi
import java.util.concurrent.atomic.AtomicInteger
import java.util.UUID

@TargetApi(Build.VERSION_CODES.O)
class KeyTitanAutofillService : AutofillService() {
    override fun onFillRequest(request: FillRequest, cancellationSignal: CancellationSignal, callback: FillCallback) {
        fun reject(reason: String) {
            request.clientState?.getString("flow")?.let(AutofillContinuation::remove)
            AutofillPreferences.diagnostic(this, reason)
            callback.onSuccess(null)
        }
        if (!AutofillPreferences.enabled(this)) return reject("disabled")
        if (cancellationSignal.isCanceled) return reject("cancelled")
        val structure = request.fillContexts.lastOrNull()?.structure ?: return reject("no_structure")
        val parsed = AutofillRequestParser.parse(structure) ?: return reject("unsupported_or_ambiguous_fields")
        if (parsed.packageName == packageName) return reject("keytitan_fields_excluded")
        val recipient = AutofillRecipientVerifier.identify(this, parsed) ?: return reject("unverified_package")
        if (recipient.origin?.startsWith("http://") == true) return reject("insecure_http")
        if (!AutofillSessions.allowed(this, recipient)) return reject("unverified_browser_or_webview")
        val priorFlow = request.clientState?.getString("flow").orEmpty()
        val continuing = AutofillContinuation.available(this, priorFlow, parsed, recipient)
        val flow = if (continuing) priorFlow else UUID.randomUUID().toString()
        val session = AutofillSessions.create(parsed, recipient, flow = flow, continuation = continuing)
        val cancellation = AutofillRequestCancellation(flow)
        cancellation.track(session.token)
        cancellationSignal.setOnCancelListener { cancellation.cancel() }
        val sender = authenticationIntent(session.token, continuing).intentSender
        val label = if (continuing) "Continue KeyTitan login" else if (parsed.registration) "Create login with KeyTitan" else "Unlock KeyTitan"
        val presentation = RemoteViews(packageName, R.layout.keytitan_autofill_dataset).apply {
            setTextViewText(R.id.keytitan_autofill_label, label)
        }
        val dataset = Dataset.Builder(presentation).setAuthentication(sender)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val inline = request.inlineSuggestionsRequest
            val spec = inline?.inlinePresentationSpecs?.firstOrNull {
                UiVersions.INLINE_UI_VERSION_1 in UiVersions.getVersions(it.style)
            }
            if (spec != null && inline.maxSuggestionCount > 0) {
                // Long press opens the main app, never consumes the authentication token.
                val attribution = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val content = InlineSuggestionUi.newContentBuilder(attribution)
                    .setTitle(label).setContentDescription(label).build()
                dataset.setInlinePresentation(InlinePresentation(content.slice, spec, false))
            }
        }
        parsed.usernameId?.let { dataset.setValue(it, null, presentation) }
        parsed.passwordId?.let { dataset.setValue(it, null, presentation) }
        val response = FillResponse.Builder().addDataset(dataset.build())
        val clientState = Bundle().apply { putString("flow", flow) }
        if (parsed.passwordId != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val saveContext = AutofillSessions.create(parsed, recipient, save = true)
            cancellation.track(saveContext.token)
            val info = SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_PASSWORD, arrayOf(parsed.passwordId))
            parsed.usernameId?.let { info.setOptionalIds(arrayOf(it)) }
            response.setSaveInfo(info.build())
            clientState.putString("save", saveContext.token)
        }
        response.setClientState(clientState)
        if (cancellationSignal.isCanceled) {
            cancellation.cancel()
            return reject("cancelled")
        }
        AutofillPreferences.diagnostic(this, if (continuing) "continuation_offered" else "unlock_offered")
        callback.onSuccess(response.build())
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        request.clientState?.getString("flow")?.let(AutofillContinuation::remove)
        val previous = AutofillSessions.get(request.clientState?.getString("save").orEmpty())
        if (previous == null || !previous.save || !AutofillSessions.valid(this, previous)) {
            callback.onFailure("Save request expired. Use Create login in KeyTitan.")
            return
        }
        AutofillSessions.remove(previous.token)
        val structure = request.fillContexts.lastOrNull()?.structure
        val parsed = structure?.let { AutofillRequestParser.parse(it, previous.parsed.focusedId) }
        if (parsed == null || parsed.contextFingerprint != previous.parsed.contextFingerprint) {
            callback.onFailure("The destination changed. Please retry.")
            return
        }
        val username = AutofillSessions.value(structure, parsed.usernameId).orEmpty()
        val password = AutofillSessions.value(structure, parsed.passwordId).orEmpty()
        if (password.isEmpty() || password.length > 4096 || username.length > 4096) {
            callback.onFailure("Unsupported login fields.")
            return
        }
        val session = AutofillSessions.create(parsed, previous.recipient, true, username, password)
        // Documented deferred-save flow. Only the activity reports a durable save.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) callback.onSuccess(authenticationIntent(session.token).intentSender)
        else callback.onFailure("Open KeyTitan to save this login.")
    }

    private fun authenticationIntent(token: String, continuing: Boolean = false): PendingIntent = PendingIntent.getActivity(
        this, requestCodes.incrementAndGet(),
        Intent(this, if (continuing) KeyTitanAutofillContinueActivity::class.java else KeyTitanAutofillAuthActivity::class.java).putExtra("token", token),
        PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_ONE_SHOT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0,
    )
    private companion object { val requestCodes = AtomicInteger(10000) }
}

/** Includes tokens created concurrently with a cancellation notification. */
internal class AutofillRequestCancellation(private val flow: String) {
    private var cancelled = false
    private val tokens = mutableListOf<String>()
    @Synchronized fun track(token: String) {
        if (cancelled) AutofillSessions.remove(token) else tokens.add(token)
    }
    @Synchronized fun cancel() {
        if (cancelled) return
        cancelled = true
        tokens.forEach(AutofillSessions::remove)
        tokens.clear()
        AutofillContinuation.remove(flow)
    }
}
