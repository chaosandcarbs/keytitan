package app.keytitan

import android.annotation.TargetApi
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.verify.domain.DomainVerificationManager
import android.content.pm.verify.domain.DomainVerificationUserState
import android.net.Uri
import android.os.Build
import android.util.Base64
import android.view.View
import android.view.autofill.AutofillId
import android.text.InputType
import java.net.IDN
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale

internal enum class RecipientKind { NATIVE_APP, BROWSER, WEBVIEW }

internal enum class ApprovalRequirement { NONE, NATIVE_APP, BROWSER, WEBVIEW_OVERRIDE }

internal data class RecipientIdentity(
    val packageName: String,
    val currentCertificate: String,
    val certificateHistory: Set<String>,
    val origin: String?,
    val topLevelOrigin: String?,
    val kind: RecipientKind,
) {
    val allCertificates: Set<String>
        get() = certificateHistory + currentCertificate

    fun callerKey(): String = listOf(packageName, currentCertificate, origin.orEmpty()).joinToString("|")

    fun sameRecipient(other: RecipientIdentity): Boolean =
        packageName == other.packageName &&
            currentCertificate == other.currentCertificate &&
            origin == other.origin &&
            topLevelOrigin == other.topLevelOrigin &&
            kind == other.kind

    fun destinationLabel(): String {
        val target = origin ?: packageName
        return if (topLevelOrigin != null && topLevelOrigin != origin) {
            "$target (inside $topLevelOrigin)"
        } else {
            target
        }
    }
}

internal data class ParsedAutofillContext(
    val packageName: String,
    val origin: String?,
    val topLevelOrigin: String?,
    val focusedId: AutofillId,
    val usernameId: AutofillId?,
    val passwordId: AutofillId?,
    val contextFingerprint: String,
    val registration: Boolean = false,
    val activity: String = "",
    val frame: String = "",
)

internal data class MatchedEntry(
    val entry: KeyTitanAutofillEntry,
    val certificateBound: Boolean,
)

@TargetApi(Build.VERSION_CODES.O)
internal object AutofillRequestParser {
    private const val INVALID_WEB_ORIGIN = "invalid-web-origin"
    private enum class FieldKind { USERNAME, PASSWORD, NEW_PASSWORD, OTHER }

    private data class NodeRecord(
        val node: AssistStructure.ViewNode,
        val path: String,
        val parentPath: String,
        val origin: String?,
        val topLevelOrigin: String?,
        val originRootPath: String?,
        val formKey: String?,
        val safe: Boolean,
    )

    fun parse(structure: AssistStructure, expectedFocus: AutofillId? = null): ParsedAutofillContext? = try {
        parseBounded(structure, expectedFocus)
    } catch (_: RuntimeException) { null }

    private fun parseBounded(structure: AssistStructure, expectedFocus: AutofillId?): ParsedAutofillContext? {
        val packageName = structure.activityComponent?.packageName
            ?.trim()
            ?.lowercase(Locale.ROOT)
            ?.takeIf { it.isNotEmpty() }
            ?: return null

        val records = mutableListOf<NodeRecord>()
        if (structure.windowNodeCount > 16) return null
        for (windowIndex in 0 until structure.windowNodeCount) {
            visit(
                structure.getWindowNodeAt(windowIndex).rootViewNode,
                path = "w$windowIndex",
                parentPath = "",
                inheritedOrigin = null,
                inheritedTopLevelOrigin = null,
                inheritedOriginRoot = null,
                inheritedFormKey = null,
                ancestorsSafe = true,
                output = records,
            )
        }
        if (records.size >= 4096) return null

        // Browser containers and their virtual text input can both be focused.
        val focused = records.filter {
            it.node.autofillType == View.AUTOFILL_TYPE_TEXT &&
                (if (expectedFocus != null) it.node.autofillId == expectedFocus else it.node.isFocused)
        }
        if (focused.size != 1) return null
        val focus = focused.single()
        if (
            !focus.safe ||
            focus.node.autofillId == null ||
            focus.origin == INVALID_WEB_ORIGIN
        ) return null
        val focusKind = focus.node.fieldKind()
        if (focusKind == FieldKind.OTHER) return null

        val partitionRoot = focus.originRootPath ?: focus.parentPath
        val partition = records.filter { record ->
            record.safe &&
                record.path.isInPartition(partitionRoot) &&
                record.origin == focus.origin && record.originRootPath == focus.originRootPath &&
                record.isInFocusedForm(focus) &&
                record.node.autofillId != null &&
                record.node.autofillType == View.AUTOFILL_TYPE_TEXT
        }

        val usernameCandidates = partition.filter { it.node.fieldKind() == FieldKind.USERNAME }
        val registration = partition.any { it.node.fieldKind() == FieldKind.NEW_PASSWORD }
        val passwordCandidates = partition.filter {
            it.node.fieldKind() == if (registration) FieldKind.NEW_PASSWORD else FieldKind.PASSWORD
        }
        // Never place an existing password into an account creation/change form.
        if (registration && focusKind == FieldKind.PASSWORD) return null
        val focusedId = focus.node.autofillId ?: return null

        val usernameId: AutofillId?
        val passwordId: AutofillId?
        when (focusKind) {
            FieldKind.USERNAME -> {
                usernameId = focusedId
                passwordId = if (usernameCandidates.size == 1) passwordCandidates.singleOrNull()?.node?.autofillId else null
            }
            FieldKind.PASSWORD, FieldKind.NEW_PASSWORD -> {
                passwordId = focusedId
                usernameId = if (passwordCandidates.size == 1) usernameCandidates.singleOrNull()?.node?.autofillId else null
            }
            FieldKind.OTHER -> return null
        }

        val fingerprintMaterial = listOf(
            packageName,
            structure.activityComponent.flattenToString(),
            focus.origin.orEmpty(),
            focus.topLevelOrigin.orEmpty(),
            partitionRoot,
            focus.formKey.orEmpty(),
            focus.path,
            focus.node.stableFieldLabel(),
            focusedId.toString(),
            usernameId?.toString().orEmpty(),
            passwordId?.toString().orEmpty(),
            registration.toString(),
        ).joinToString("\u0000")

        return ParsedAutofillContext(
            packageName = packageName,
            origin = focus.origin,
            topLevelOrigin = focus.topLevelOrigin,
            focusedId = focusedId,
            usernameId = usernameId,
            passwordId = passwordId,
            contextFingerprint = sha256Hex(fingerprintMaterial.toByteArray()),
            registration = registration,
            activity = structure.activityComponent.flattenToString(),
            frame = focus.originRootPath ?: "w${focus.path.substringAfter('w').substringBefore('/')}",
        )
    }

    private fun visit(
        node: AssistStructure.ViewNode,
        path: String,
        parentPath: String,
        inheritedOrigin: String?,
        inheritedTopLevelOrigin: String?,
        inheritedOriginRoot: String?,
        inheritedFormKey: String?,
        ancestorsSafe: Boolean,
        output: MutableList<NodeRecord>,
    ) {
        // Reject the whole structure rather than making security decisions on a
        // partially traversed tree supplied by the requesting application.
        require(output.size < 4096 && path.count { it == '/' } < 64 && node.childCount <= 4096)
        val reportsWebDomain = !node.webDomain.isNullOrBlank()
        val tag = node.htmlInfo?.tag?.lowercase(Locale.ROOT)
        val documentBoundary = tag in setOf("html", "iframe") || node.className?.endsWith("WebView") == true
        val ownOrigin = if (reportsWebDomain) canonicalRequestOrigin(node) else null
        val origin = when {
            reportsWebDomain -> ownOrigin ?: INVALID_WEB_ORIGIN
            tag == "iframe" -> INVALID_WEB_ORIGIN
            else -> inheritedOrigin
        }
        val topLevelOrigin = inheritedTopLevelOrigin ?: if (reportsWebDomain) origin else null
        val originRoot = if (documentBoundary || reportsWebDomain &&
            (origin != inheritedOrigin || inheritedOriginRoot == null)) path else inheritedOriginRoot
        val attributes = node.htmlInfo?.attributes.orEmpty().associate { it.first to it.second }
        val explicitForm = attributes["form"]?.takeIf { it.isNotBlank() }
        val opensForm = node.htmlInfo?.tag?.equals("form", ignoreCase = true) == true
        // Physical form paths cannot collide when a page reuses a form ID/name.
        val formKey = explicitForm?.let { "explicit:$it" } ?: if (opensForm) path else {
            inheritedFormKey
        }
        val hierarchySafe = ancestorsSafe &&
            node.visibility == View.VISIBLE &&
            node.isEnabled &&
            node.alpha > 0.01f
        val safe = hierarchySafe &&
            node.width > 1 &&
            node.height > 1

        output.add(
            NodeRecord(
                node,
                path,
                parentPath,
                origin,
                topLevelOrigin,
                originRoot,
                formKey,
                safe,
            ),
        )
        for (childIndex in 0 until node.childCount) {
            visit(
                node.getChildAt(childIndex),
                path = "$path/$childIndex",
                parentPath = path,
                inheritedOrigin = origin,
                inheritedTopLevelOrigin = topLevelOrigin,
                inheritedOriginRoot = originRoot,
                inheritedFormKey = formKey,
                ancestorsSafe = hierarchySafe,
                output = output,
            )
        }
    }

    private fun canonicalRequestOrigin(node: AssistStructure.ViewNode): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        val scheme = node.webScheme?.lowercase(Locale.ROOT) ?: return null
        val domain = node.webDomain ?: return null
        return canonicalOrigin("$scheme://$domain", assumeHttps = false)
    }

    private fun String.isInPartition(root: String): Boolean =
        root.isEmpty() || this == root || startsWith("$root/")

    private fun NodeRecord.isInFocusedForm(focus: NodeRecord): Boolean {
        if (focus.origin == null) return true
        val focusedForm = focus.formKey
        return if (focusedForm != null) {
            formKey == focusedForm
        } else {
            // Layout wrappers aren't form boundaries. Candidate uniqueness below
            // still prevents pairing ambiguous forms without HTML form metadata.
            formKey == null && originRootPath == focus.originRootPath
        }
    }

    private fun AssistStructure.ViewNode.fieldKind(): FieldKind {
        if (autofillType != View.AUTOFILL_TYPE_TEXT) return FieldKind.OTHER
        val hints = autofillHints.orEmpty().map { it.lowercase(Locale.ROOT) }.toSet()
        val label = stableFieldLabel()
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        val inputClass = inputType and InputType.TYPE_MASK_CLASS
        val attributes = htmlInfo?.attributes.orEmpty().associate { it.first.lowercase(Locale.ROOT) to it.second.lowercase(Locale.ROOT) }
        // Never release an existing password into registration or OTP fields.
        val autocomplete = attributes["autocomplete"].orEmpty().split(' ') + hints
        if ("one-time-code" in autocomplete || "smsotpcode" in autocomplete) return FieldKind.OTHER
        if ("new-password" in autocomplete || "newpassword" in autocomplete) return FieldKind.NEW_PASSWORD
        if (
            hints.any { it == "password" || it == "current-password" } ||
            attributes["type"] == "password" ||
            (inputClass == InputType.TYPE_CLASS_TEXT && variation in setOf(
                InputType.TYPE_TEXT_VARIATION_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)) ||
            (inputClass == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD) ||
            Regex("(^|[^a-z])(password|passwd)([^a-z]|$)").containsMatchIn(label)
        ) {
            return FieldKind.PASSWORD
        }
        if (
            hints.any { it == "username" || it == "emailaddress" } ||
            (inputClass == InputType.TYPE_CLASS_TEXT && variation in setOf(
                InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS)) ||
            Regex("(^|[^a-z])(username|user|email|login)([^a-z]|$)").containsMatchIn(label)
        ) {
            return FieldKind.USERNAME
        }
        return FieldKind.OTHER
    }

    private fun AssistStructure.ViewNode.stableFieldLabel(): String = listOfNotNull(
        autofillHints?.joinToString(" "),
        idEntry,
        hint,
        className,
        htmlInfo?.attributes?.joinToString(" ") { "${it.first}=${it.second}" },
    ).joinToString(" ").lowercase(Locale.ROOT)
}

internal object AutofillRecipientVerifier {
    fun identify(context: Context, parsed: ParsedAutofillContext): RecipientIdentity? {
        val certificates = signingCertificates(context.packageManager, parsed.packageName)
            ?: return null
        val current = certificates.first
        val history = certificates.second
        val kind = when {
            AutofillTrustStore.isTrustedBrowser(
                context,
                parsed.packageName,
                history + current,
            ) ->
                RecipientKind.BROWSER
            isBrowserCandidate(context, parsed.packageName) -> RecipientKind.BROWSER
            parsed.origin == null -> RecipientKind.NATIVE_APP
            else -> RecipientKind.WEBVIEW
        }
        return RecipientIdentity(
            packageName = parsed.packageName,
            currentCertificate = current,
            certificateHistory = history,
            origin = parsed.origin,
            topLevelOrigin = parsed.topLevelOrigin,
            kind = kind,
        )
    }

    fun approvalRequirement(context: Context, recipient: RecipientIdentity): ApprovalRequirement {
        return when (recipient.kind) {
            RecipientKind.NATIVE_APP -> if (
                AutofillTrustStore.isTrustedNativeApp(context, recipient)
            ) ApprovalRequirement.NONE else ApprovalRequirement.NATIVE_APP
            RecipientKind.BROWSER -> if (
                AutofillTrustStore.isTrustedBrowser(
                    context,
                    recipient.packageName,
                    recipient.allCertificates,
                )
            ) ApprovalRequirement.NONE else ApprovalRequirement.BROWSER
            RecipientKind.WEBVIEW -> if (
                isVerifiedAppLink(context, recipient)
            ) ApprovalRequirement.NONE else ApprovalRequirement.WEBVIEW_OVERRIDE
        }
    }

    private fun signingCertificates(
        packageManager: PackageManager,
        packageName: String,
    ): Pair<String, Set<String>>? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = packageManager.getPackageInfo(
                    packageName,
                    PackageManager.GET_SIGNING_CERTIFICATES,
                )
                val signingInfo = info.signingInfo ?: return null
                val currentDigests = signingInfo.apkContentsSigners.orEmpty()
                    .map { sha256Hex(it.toByteArray()) }
                    .sorted()
                val current = currentDigests.joinToString("+")
                if (current.isBlank()) return null
                val historySignatures = if (signingInfo.hasMultipleSigners()) {
                    signingInfo.apkContentsSigners
                } else {
                    signingInfo.signingCertificateHistory
                }
                val history = historySignatures.orEmpty()
                    .map { sha256Hex(it.toByteArray()) }
                    .toSet() + currentDigests
                current to history
            } else {
                @Suppress("DEPRECATION")
                val info = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                @Suppress("DEPRECATION")
                val digests = info.signatures.orEmpty().map { sha256Hex(it.toByteArray()) }.sorted()
                val current = digests.joinToString("+")
                if (current.isBlank()) null else current to digests.toSet()
            }
        } catch (_: PackageManager.NameNotFoundException) {
            null
        } catch (_: SecurityException) {
            null
        }
    }

    private fun isBrowserCandidate(context: Context, packageName: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://keytitan.invalid/"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
        return context.packageManager
            .queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            .any { it.activityInfo?.packageName == packageName }
    }

    private fun isVerifiedAppLink(context: Context, recipient: RecipientIdentity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        val host = try {
            URI(recipient.origin ?: return false).host?.let { IDN.toASCII(it).lowercase(Locale.ROOT) }
        } catch (_: Exception) {
            null
        } ?: return false
        return try {
            val manager = context.getSystemService(DomainVerificationManager::class.java)
                ?: return false
            val state = manager.getDomainVerificationUserState(recipient.packageName) ?: return false
            state.hostToStateMap[host] == DomainVerificationUserState.DOMAIN_STATE_VERIFIED
        } catch (_: PackageManager.NameNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }
}

internal object AutofillEntryMatcher {
    fun matches(entries: List<KeyTitanAutofillEntry>, recipient: RecipientIdentity): List<MatchedEntry> {
        return if (recipient.origin != null) {
            entries.mapNotNull { entry ->
                val origins = (listOf(entry.site) + entry.uris)
                    .mapNotNull { canonicalOrigin(it, assumeHttps = true) }
                    .toSet()
                if (recipient.origin in origins) MatchedEntry(entry, false) else null
            }
        } else {
            entries.mapNotNull { entry ->
                val bindings = (listOf(entry.site) + entry.uris)
                    .mapNotNull(::parseAndroidAppBinding)
                val packageBindings = bindings.filter { it.packageName == recipient.packageName }
                if (packageBindings.isEmpty()) return@mapNotNull null
                val certificateBound = packageBindings.any { binding ->
                    binding.certificate != null &&
                        recipient.allCertificates.any { normalizeCertificate(it) == binding.certificate }
                }
                // A supplied but mismatched pin must never degrade to TOFU.
                if (!certificateBound && packageBindings.none { it.certificate == null }) null
                else MatchedEntry(entry, certificateBound)
            }
        }
    }

    private data class AndroidAppBinding(val packageName: String, val certificate: String?)

    private fun parseAndroidAppBinding(value: String): AndroidAppBinding? {
        val raw = value.trim()
        val uri = try {
            Uri.parse(raw)
        } catch (_: Exception) {
            return null
        }
        if (uri.scheme?.lowercase(Locale.ROOT) !in setOf("androidapp", "app")) return null
        val packageName = uri.host?.lowercase(Locale.ROOT)?.takeIf { it.isNotBlank() } ?: return null
        val certificate = uri.getQueryParameter("sha256_cert")
            ?.let(::normalizeCertificate)
        if (certificate != null && !Regex("[0-9A-F]{64}").matches(certificate)) return null
        return AndroidAppBinding(packageName, certificate)
    }
}

internal object AutofillTrustStore {
    private const val PREFS = "keytitan_autofill_trust_v1"
    private const val TRUSTED = "trusted_bindings"

    fun isTrustedNativeApp(context: Context, recipient: RecipientIdentity): Boolean =
        recipient.allCertificates.any { contains(context, "native", recipient.packageName, it) }

    fun isTrustedBrowser(
        context: Context,
        packageName: String,
        certificates: Set<String>,
    ): Boolean = BrowserCertificates.trusted(packageName, certificates)

    fun isTrustedWebView(context: Context, recipient: RecipientIdentity): Boolean =
        recipient.allCertificates.any { certificate ->
            contains(
                context,
                "webview",
                recipient.packageName,
                certificate,
                recipient.origin.orEmpty(),
            )
        }

    fun approve(context: Context, recipient: RecipientIdentity, requirement: ApprovalRequirement) {
        val key = when (requirement) {
            ApprovalRequirement.NATIVE_APP -> key(
                "native",
                recipient.packageName,
                recipient.currentCertificate,
            )
            ApprovalRequirement.BROWSER -> key(
                "browser",
                recipient.packageName,
                recipient.currentCertificate,
            )
            ApprovalRequirement.WEBVIEW_OVERRIDE -> key(
                "webview",
                recipient.packageName,
                recipient.currentCertificate,
                recipient.origin.orEmpty(),
            )
            ApprovalRequirement.NONE -> return
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val values = prefs.getStringSet(TRUSTED, emptySet()).orEmpty().toMutableSet()
        values.add(key)
        prefs.edit().putStringSet(TRUSTED, values).apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        KeyTitanCapabilityStore.clear()
    }

    private fun contains(context: Context, vararg parts: String): Boolean {
        val values = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(TRUSTED, emptySet())
            .orEmpty()
        return key(*parts) in values
    }

    private fun key(vararg parts: String): String = parts.joinToString("|")
}

internal fun canonicalOrigin(value: String, assumeHttps: Boolean): String? {
    val raw = value.trim()
    if (raw.isEmpty() || raw.startsWith("androidapp://", true) || raw.startsWith("app://", true)) {
        return null
    }
    val candidate = if (raw.contains("://")) raw else if (assumeHttps) "https://$raw" else return null
    return try {
        val uri = URI(candidate)
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
        if (scheme != "https" && scheme != "http") return null
        if (uri.userInfo != null) return null
        val authority = uri.rawAuthority ?: return null
        if ('@' in authority || '%' in authority || '\\' in authority) return null
        // Parse Unicode DNS names before IDNA conversion; never guess an IPv6 authority.
        val rawHost = uri.host ?: authority.substringBefore(':').takeIf {
            authority.count { char -> char == ':' } <= 1
        } ?: return null
        val host = if (rawHost.startsWith('[')) rawHost.lowercase(Locale.ROOT)
            else IDN.toASCII(rawHost, IDN.USE_STD3_ASCII_RULES).lowercase(Locale.ROOT)
        if (host.isBlank() || host.endsWith('.')) return null
        val port = if (uri.host == null && ':' in authority)
            authority.substringAfter(':').toIntOrNull() ?: return null else uri.port
        if (authority.endsWith(':')) return null
        if (port !in -1..65535 || port == 0) return null
        val defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        "$scheme://$host${if (port != -1 && !defaultPort) ":$port" else ""}"
    } catch (_: Exception) {
        null
    }
}

internal fun normalizeCertificate(value: String): String =
    value.replace(":", "").trim().uppercase(Locale.ROOT)

internal fun sha256Hex(bytes: ByteArray): String = MessageDigest
    .getInstance("SHA-256")
    .digest(bytes)
    .joinToString("") { "%02X".format(it) }

internal data class AutofillRequestCapability(
    val token: String,
    val vaultId: String,
    val sessionEpoch: String,
    val eligibleEntryIds: Set<String>,
    val recipient: RecipientIdentity,
    val focusedId: AutofillId,
    val usernameId: AutofillId?,
    val passwordId: AutofillId?,
    val contextFingerprint: String,
    val approvalRequirement: ApprovalRequirement,
    val createdAtMillis: Long,
    val expiresAtMillis: Long,
    val selectedEntryId: String? = null,
)

internal object KeyTitanCapabilityStore {
    private const val MAX_CAPABILITIES = 32
    private const val CAPABILITY_LIFETIME_MILLIS = 60_000L
    private val random = SecureRandom()
    private val capabilities = LinkedHashMap<String, AutofillRequestCapability>()

    @Synchronized
    fun create(
        snapshot: KeyTitanAutofillSnapshot,
        eligibleEntryIds: Set<String>,
        recipient: RecipientIdentity,
        parsed: ParsedAutofillContext,
        approvalRequirement: ApprovalRequirement,
    ): AutofillRequestCapability {
        pruneExpired()
        while (capabilities.size >= MAX_CAPABILITIES) {
            capabilities.remove(capabilities.keys.first())
        }
        val tokenBytes = ByteArray(32).also(random::nextBytes)
        val token = Base64.encodeToString(
            tokenBytes,
            Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE,
        )
        tokenBytes.fill(0)
        val now = android.os.SystemClock.elapsedRealtime()
        return AutofillRequestCapability(
            token = token,
            vaultId = snapshot.vaultId,
            sessionEpoch = snapshot.sessionEpoch,
            eligibleEntryIds = eligibleEntryIds,
            recipient = recipient,
            focusedId = parsed.focusedId,
            usernameId = parsed.usernameId,
            passwordId = parsed.passwordId,
            contextFingerprint = parsed.contextFingerprint,
            approvalRequirement = approvalRequirement,
            createdAtMillis = now,
            expiresAtMillis = now + CAPABILITY_LIFETIME_MILLIS,
        ).also { capabilities[token] = it }
    }

    @Synchronized
    fun peek(token: String): AutofillRequestCapability? {
        pruneExpired()
        return capabilities[token]
    }

    @Synchronized
    fun select(token: String, entryId: String): Boolean {
        pruneExpired()
        val capability = capabilities[token] ?: return false
        if (entryId !in capability.eligibleEntryIds || capability.selectedEntryId != null) return false
        capabilities[token] = capability.copy(selectedEntryId = entryId)
        return true
    }

    @Synchronized
    fun consume(
        token: String,
        snapshot: KeyTitanAutofillSnapshot,
        parsed: ParsedAutofillContext,
        recipient: RecipientIdentity,
    ): AutofillRequestCapability? {
        val capability = capabilities.remove(token) ?: return null
        val now = android.os.SystemClock.elapsedRealtime()
        if (
            now > capability.expiresAtMillis ||
            capability.selectedEntryId == null ||
            capability.vaultId != snapshot.vaultId ||
            capability.sessionEpoch != snapshot.sessionEpoch ||
            capability.contextFingerprint != parsed.contextFingerprint ||
            !capability.recipient.sameRecipient(recipient)
        ) {
            return null
        }
        return capability
    }

    @Synchronized
    fun invalidate(token: String) {
        capabilities.remove(token)
    }

    @Synchronized
    fun clear() {
        capabilities.clear()
    }

    private fun pruneExpired() {
        val now = android.os.SystemClock.elapsedRealtime()
        capabilities.entries.removeAll { now > it.value.expiresAtMillis }
    }
}
