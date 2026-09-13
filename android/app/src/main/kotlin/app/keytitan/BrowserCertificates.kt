package app.keytitan

/** Release fingerprints from https://www.gstatic.com/gpm-passkeys-privileged-apps/apps.json
 * Reviewed 2026-09-12. No debug keys, remote trust updates, or package-name-only trust.
 */
internal object BrowserCertificates {
    private val chrome = "F0FD6C5B410F25CB25C3B53346C8972FAE30F8EE7411DF910480AD6B2D60DB83"
    private val brave = "9C2DB70513515FDBFBBC585B3EDF3D7123D4DC67C94FFD306361C1D79BBF18AC"
    private val firefox = "A78B62A5165B4494B2FEAD9E76A280D22D937FEE6251AECE599446B2EA319B04"
    private val pins = mapOf(
        "com.android.chrome" to setOf(chrome),
        "com.brave.browser" to setOf(brave),
        "com.brave.browser_beta" to setOf(brave),
        "com.brave.browser_nightly" to setOf(brave),
        "org.mozilla.firefox" to setOf(firefox),
        "org.mozilla.firefox_beta" to setOf(firefox),
    )
    fun trusted(packageName: String, certificates: Set<String>): Boolean {
        // Multiple current signers are represented by '+': don't trust a subset.
        if (certificates.any { '+' in it }) return false
        return certificates.any { it in pins[packageName].orEmpty() }
    }
}
