# Android autofill

KeyTitan uses Android's Autofill Framework, not browser extensions, accessibility
scraping, etc. Web autofill and deferred saves require Android
9+; keyboard-inline suggestions require Android 11+ and a compatible keyboard.

## User experience

1. Create or download a vault in KeyTitan. Under **Settings → Android Autofill**,
   enable **Offer KeyTitan in other apps**, then select KeyTitan in Android settings.
   This is independent of the app's clipboard/password-output preference.
2. In Chrome/Brave, select the system/other-provider autofill option and restart
   the browser if requested. Tap a username or password field on HTTPS.
3. Tap **Unlock KeyTitan** in the keyboard or dropdown. A private screen shows
   the destination and lets you select a local vault and enter its master password.
   The main app does not need to be open or unlocked.
4. Choose a matching account to authorize one fill. No matching account? Use
   **Create login**, or explicitly associate an existing account with this exact
   destination. Association is confirmed and saved before filling.
5. A recognized new-password field offers creation, not existing passwords.
   The editor can generate a 24-character password; it saves the encrypted login
   before returning it to Android. Confirmation fields are not automatically filled.
6. When Android detects a submitted password form, its save prompt starts a
   private unlock/review flow. Choose a new entry or update an exact-destination
   match, review the account and destination, then confirm. KeyTitan displays
   **Login saved** only after a successful encrypted-file commit.

The private vault session expires after three minutes and is cancelled when you
leave the screen. A username-only login has a separate one-use password-step
continuation described below. Neither extends the main app's lock timer. Biometric quick unlock
is **not** implemented: this version requires the vault master password.

## Destination and release checks

- The installed requester's signing identity is checked on request and again
  during the private flow. Browsers must match bundled release-certificate pins:
  Chrome stable, Brave stable/beta/nightly, Firefox stable/beta. Pins come from
  [Google's published privileged-app registry](https://www.gstatic.com/gpm-passkeys-privileged-apps/apps.json),
  reviewed 2026-09-12. This is not trust-on-first-use or a runtime network fetch.
  Unlisted/re-signed browsers fail closed pending a reviewed trust-policy update.
- A browser without a usable HTTPS origin is rejected, never converted into an
  app-wide binding. WebViews require Android-verified App Links for the reported
  host. Old manual browser/WebView approvals do not bypass these checks.
- Web matching uses exact canonical origins: IDNA ASCII host, scheme and port.
  Paths do not narrow an origin. www, sibling subdomains and non-default ports
  are separate destinations. HTTP is rejected. New entries do not invent aliases.
  Previously stored URI overrides are preserved: review **both Site and URI
  overrides** when removing an association or auditing legacy generated aliases.
- Native matches require an explicit package-and-certificate URI:
  `androidapp://com.example.app?sha256_cert=<64 SHA-256 hex digits>`.
  Package-only entries are ineligible until explicitly associated with the
  installed recipient in the unlocked picker. Mismatched pins fail closed.
  Multiple-current-signer packages are unsupported, not partially trusted.
- The parser requires one visible, enabled text-input focus, ignoring focused
  browser containers. Pairing stays in the reported form/frame; ambiguity fills
  only the focused field. OTP fields are excluded. Oversized/malformed structures
  are rejected. Frame and enclosing origins are displayed when reported.
- Random in-memory tokens bind requests to package, certificate, origin,
  field/form fingerprint and monotonic expiry. Each activity claims its token
  once. Completion, cancellation, disabling autofill and process death revoke
  its authority. Intents contain opaque tokens, not passwords or vault keys.
- Account labels appear only after master-password unlock. Only the selected
  password is decrypted. Username-only login fills also prepare that selected
  password for the short, explicitly described continuation; it is not sent to
  the username field or included in a suggestion dataset before the next tap.
  Association may decrypt/re-encrypt that selected entry to persist the new URI.
  Vault-file changes are checked before/after decryption and before release.
- The private activity is non-exported, screenshot/recents capture is blocked,
  and Android 12+ overlay hiding is enabled with the required permission.
  Password inputs disable suggestions and personalized IME learning.

## Vault persistence and plaintext boundary

Each vault-unlock activity owns a separate Flutter engine and in-memory vault.
It does not borrow a global unlocked vault or retain the vault key for later fills.
Successful fills close the private vault before returning the selected
credential to native code. Cancellation immediately revokes tokens and asks Dart
to clear controllers, drain pending work/unlocks, and dispose the vault. The
private engine stays alive through host destruction until that acknowledgement;
an unresponsive engine is forcibly destroyed after five seconds. Forced teardown
cannot guarantee that application-level overwrite routines completed.
Expiry, disabling autofill and request cancellation also notify an open private
activity to start this cleanup. Native release and cancellation have a shared
ordering point, and release rechecks the encrypted file's fingerprint.
The remembered vault path and diagnostic reason code contain no login values.

Android main-app saves, autofill saves and Drive downloads share a native commit
queue. An expected SHA-256 of the original encrypted file prevents stale sessions
from overwriting a newer file. A private sibling temporary file is flushed and
atomically renamed; failed/expired commits preserve the original. If another
session changed the vault, close and reopen before retrying: no silent merge or
last-writer-wins overwrite.

The save callback necessarily receives the submitted password from Android
before vault unlock. It remains in bounded process memory for the private save
flow, not a disk cache. After selection, a fill password crosses Dart, Kotlin and
Android Binder to the destination. Managed-runtime/OS string copies cannot be
reliably zeroized. A trusted browser/keyboard and uncompromised Android OS remain
part of the security boundary.

### Two-step login continuation

When the selected login initially has only a username field, KeyTitan keeps just
that selected credential encrypted with a fresh process-memory AES-GCM key for
60 seconds (not a sliding timeout). No master password or vault key is retained.
The next password-step suggestion says **Continue KeyTitan login**. Tapping it
launches a private native activity, verifies the new request, consumes the grant
once, and returns the password without another master-password prompt.

The grant requires the same opaque Android client-state flow, activity, frame,
verified package/certificate, exact origin and enclosing origin. It is rejected
for registration fields, device lock, vault-file changes and expiry. Disabling
autofill, cancelling pending requests, screen-off, submitting a save request,
selecting another account or process death revokes it. Key/IV/ciphertext buffers
are cleared on revocation; managed plaintext copies still have the limitations
above. An invalidated/expired grant requires a fresh unlock. This is not a general
quick-unlock cache, cross-site authorization, or a biometric-unlock feature.

Pairing treats layout wrappers as presentation, not separate login forms.
Physical forms and frame boundaries remain distinct; duplicate/ambiguous fields
do not get guessed partners. The authentication snapshot is rechecked using the
originally bound AutofillId even if focus was lost when the unlock screen opened.

The authentication AssistStructure is an Android-supplied **snapshot**, not an
independent live reading of the browser URL. KeyTitan rechecks its fingerprint
and requester identity; Android/the trusted browser must bind returned AutofillIds
to the correct live session. KeyTitan cannot protect a credential after the
authorized destination receives it or claim independent navigation detection.

## Verification and device acceptance

Automated checks:

```sh
flutter analyze --no-pub
flutter test --reporter expanded
cd android
JAVA_HOME=/usr/lib/jvm/java-21-openjdk ./gradlew :app:testDebugUnitTest
```

Native tests cover exact origins/IDNs, pin mismatch, browser provenance, focused
containers, ambiguous/hidden/cross-origin/OTP fields, registration, save focus,
bounded parsing, single-owner/expiry/revocation, cold-service fill without an open
vault, deferred save/replay, and stale/expired/private-path commit rejection.
Dart tests cover unlocking, selected decryption, durable save/reopen, stale
release/save rejection, cancellation during unlock and preference migration.

Before shipping, test Chrome and Brave on a real device with inline and dropdown UI:

- Main app closed and vault locked; one/multiple matching accounts; no match.
- Username-only, password-only, two-step login, registration, save/update and
  generated password. Verify a password-step tap within 60 seconds avoids a new
  master-password prompt only when Android preserves the verified client-state
  flow. A new Android session, origin/activity/frame change, expiry or missing
  client state requires a fresh unlock. Username capture for saving is not
  carried across separate form snapshots; enter it in save review if needed.
- Exact-host/port changes, cross-origin iframe, hidden fields and OTP forms.
- Back/Home, rotation, timeout, process death and repeated taps during unlock.
- Cancelled save, unavailable storage, concurrent main-app edit or Drive download;
  reopen the vault and confirm only acknowledged saves exist.
- Unsupported/re-signed browser, HTTP, unverified WebView, native package without
  a certificate association: all must withhold existing credentials.

Use **Check autofill status** after a failed attempt. `no_request_received`
means Android/browser has not called the service; `unsupported_or_ambiguous_fields`
means the form could not safely be parsed. No URLs or field contents are recorded.
Android/browser controls whether a suggestion or save prompt is shown; SPAs,
custom controls and private browsing modes may not supply usable events. In those
cases use **Create login** from a recognized field or save in the main app.
Do not relax origin/certificate checks to force compatibility.

Platform references: [service implementation](https://developer.android.com/identity/autofill/autofill-service),
[inline integration](https://developer.android.com/identity/autofill/ime-autofill),
[deferred save callback](https://developer.android.com/reference/android/service/autofill/SaveCallback#onSuccess(android.content.IntentSender)).
