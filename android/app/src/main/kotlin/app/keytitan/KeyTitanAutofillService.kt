package app.keytitan

import android.annotation.TargetApi
import android.app.assist.AssistStructure
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.text.InputType
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews

@TargetApi(Build.VERSION_CODES.O)
class KeyTitanAutofillService : android.service.autofill.AutofillService() {
    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: android.os.CancellationSignal,
        callback: FillCallback,
    ) {
        val snapshot = KeyTitanAutofillCache.snapshot()
        if (!snapshot.enabled || snapshot.entries.isEmpty()) {
            callback.onSuccess(null)
            return
        }
        val structure = request.fillContexts.lastOrNull()?.structure
        if (structure == null) {
            callback.onSuccess(null)
            return
        }

        val fields = AutofillFieldParser.parse(structure)
        val passwordId = fields.passwordId
        val usernameId = fields.usernameId
        if ((passwordId == null && usernameId == null) || fields.identifiers.isEmpty()) {
            callback.onSuccess(null)
            return
        }

        val matches = snapshot.entries
            .filter { entry -> entry.matches(fields.identifiers) }
            .take(10)

        if (matches.isEmpty()) {
            callback.onSuccess(null)
            return
        }

        if (passwordId == null) {
            callback.onSuccess(buildUsernameResponse(matches, usernameId!!))
            return
        }

        if (!KeyTitanAutofillCache.consumeAttempt()) {
            callback.onSuccess(null)
            return
        }

        resolveAndReturnResponse(matches, fields, passwordId, callback, cancellationSignal)
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        callback.onSuccess()
    }

    private fun resolveAndReturnResponse(
        matches: List<KeyTitanAutofillEntry>,
        fields: AutofillFields,
        passwordId: AutofillId,
        callback: FillCallback,
        cancellationSignal: android.os.CancellationSignal,
    ) {
        val resolved = mutableListOf<ResolvedAutofillEntry>()
        var remaining = matches.size

        for (entry in matches) {
            KeyTitanAutofillBridge.resolvePassword(entry.id) { password ->
                if (cancellationSignal.isCanceled) return@resolvePassword
                if (!password.isNullOrEmpty()) {
                    resolved.add(ResolvedAutofillEntry(entry, password))
                }
                remaining -= 1
                if (remaining == 0) {
                    if (resolved.isEmpty()) {
                        callback.onSuccess(null)
                    } else {
                        callback.onSuccess(buildResponse(resolved, fields, passwordId))
                    }
                }
            }
        }
    }

    private fun buildResponse(
        resolvedEntries: List<ResolvedAutofillEntry>,
        fields: AutofillFields,
        passwordId: AutofillId,
    ): FillResponse {
        val response = FillResponse.Builder()
        for ((entry, password) in resolvedEntries) {
            val presentation = keyTitanPresentation(entry.presentationLabel("password"))

            val dataset = Dataset.Builder(presentation)
            fields.usernameId?.let { usernameId ->
                dataset.setValue(
                    usernameId,
                    AutofillValue.forText(entry.username),
                    presentation,
                )
            }
            dataset.setValue(
                passwordId,
                AutofillValue.forText(password),
                presentation,
            )
            response.addDataset(dataset.build())
        }
        return response.build()
    }

    private fun buildUsernameResponse(
        matches: List<KeyTitanAutofillEntry>,
        usernameId: AutofillId,
    ): FillResponse? {
        val response = FillResponse.Builder()
        var hasDataset = false

        for (entry in matches.filter { it.username.isNotBlank() }.take(10)) {
            val presentation = keyTitanPresentation(entry.presentationLabel("username"))
            val dataset = Dataset.Builder(presentation)
            dataset.setValue(
                usernameId,
                AutofillValue.forText(entry.username),
                presentation,
            )
            response.addDataset(dataset.build())
            hasDataset = true
        }

        return if (hasDataset) response.build() else null
    }

    private fun keyTitanPresentation(label: String): RemoteViews {
        val presentation = RemoteViews(packageName, R.layout.keytitan_autofill_dataset)
        presentation.setTextViewText(R.id.keytitan_autofill_label, label)
        presentation.setTextColor(R.id.keytitan_autofill_label, Color.rgb(32, 33, 36))
        presentation.setInt(R.id.keytitan_autofill_label, "setBackgroundColor", Color.WHITE)
        return presentation
    }
}

private data class ResolvedAutofillEntry(
    val entry: KeyTitanAutofillEntry,
    val password: String,
)

private fun KeyTitanAutofillEntry.presentationLabel(kind: String): String {
    val accountLabel = listOf(title, username)
        .map { it.trim() }
        .filter { it.isNotBlank() }
        .joinToString(" - ")
    return if (accountLabel.isBlank()) {
        "Use $kind from KeyTitan"
    } else {
        "Use $accountLabel from KeyTitan"
    }
}

private data class AutofillFields(
    var usernameId: AutofillId? = null,
    var passwordId: AutofillId? = null,
    val identifiers: MutableSet<String> = mutableSetOf(),
)

@TargetApi(Build.VERSION_CODES.O)
private object AutofillFieldParser {
    fun parse(structure: AssistStructure): AutofillFields {
        val fields = AutofillFields()
        structure.activityComponent?.packageName
            ?.lowercase()
            ?.let { fields.identifiers.add(it) }

        for (i in 0 until structure.windowNodeCount) {
            visit(structure.getWindowNodeAt(i).rootViewNode, fields)
        }
        return fields
    }

    private fun visit(node: AssistStructure.ViewNode, fields: AutofillFields) {
        node.webDomain
            ?.lowercase()
            ?.takeIf { it.isNotBlank() }
            ?.let { domain ->
                fields.identifiers.add(domain)
                fields.identifiers.add(domain.removePrefix("www."))
            }

        val autofillId = node.autofillId
        if (autofillId != null && node.autofillType != View.AUTOFILL_TYPE_NONE) {
            if (fields.passwordId == null && node.looksLikePassword()) {
                fields.passwordId = autofillId
            } else if (fields.usernameId == null && node.looksLikeUsername()) {
                fields.usernameId = autofillId
            }
        }

        for (i in 0 until node.childCount) {
            visit(node.getChildAt(i), fields)
        }
    }

    private fun AssistStructure.ViewNode.searchText(): String {
        return listOfNotNull(
            autofillHints?.joinToString(" "),
            idEntry,
            hint,
            className,
            text?.toString(),
        ).joinToString(" ").lowercase()
    }

    private fun AssistStructure.ViewNode.looksLikePassword(): Boolean {
        val text = searchText()
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return text.contains("password") ||
            text.contains("pass") ||
            variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
            variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
    }

    private fun AssistStructure.ViewNode.looksLikeUsername(): Boolean {
        val text = searchText()
        return text.contains("username") ||
            text.contains("user") ||
            text.contains("email") ||
            text.contains("login")
    }
}

private fun KeyTitanAutofillEntry.matches(identifiers: Set<String>): Boolean {
    val entryIdentifiers = mutableSetOf<String>()
    entryIdentifiers.addAll(normalizedIdentifiers(site))
    for (uri in uris) {
        entryIdentifiers.addAll(normalizedIdentifiers(uri))
    }
    return entryIdentifiers.any { it in identifiers }
}

private fun normalizedIdentifiers(value: String): Set<String> {
    val raw = value.trim().lowercase()
    if (raw.isBlank()) return emptySet()

    val identifiers = mutableSetOf(raw)
    val parsed = if (raw.contains("://")) Uri.parse(raw) else null
    val host = parsed?.host?.lowercase()
        ?: raw
            .removePrefix("https://")
            .removePrefix("http://")
            .substringBefore("/")

    if (host.isNotBlank()) {
        identifiers.add(host)
        identifiers.add(host.removePrefix("www."))
    }

    if (raw.startsWith("androidapp://") || raw.startsWith("app://")) {
        identifiers.add(raw.substringAfter("://").substringBefore("/"))
    }

    return identifiers
}
