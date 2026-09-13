# KeyTitan

A simple, cross-platform, local password manager. Primary development is focused on Windows, Linux, and Android, with some macOS/iOS scaffolding in place.

## Description

KeyTitan is a standalone local password manager. Your vault is a local `.ktn` file, and optional Google Drive sync can upload/download those encrypted files between devices. The app does not run a KeyTitan server and does not store your passwords outside your vault or Google Drive (if you so choose).

Vault files are encrypted with ChaCha20-Poly1305 using a random 256-bit vault key. Your master password is processed with Argon2id to create a separate key that wraps that vault key. This lets routine saves remain fast and durable without keeping the master password in memory for the whole unlocked session. ChaCha20-Poly1305 uses 256-bit symmetric keys and is generally considered quantum-resistant in the practical post-quantum sense; the harder real-world problem is still choosing a master password with enough entropy. Individual password values are also encrypted inside the in-memory SQLite database while a vault is open.

## Design Philosophy

I wanted to make a simple but secure password manager that can share passwords between platforms without turning into another web account you have to trust.

- No KeyTitan-hosted account or credential server.
- No unnecessary authentication; I don't care who you are.
- No network use beyond optional Google Drive authentication/sync (optional).
- No ads or bloat.

Everything is your responsibility. If you forget your vault password, the file is unrecoverable. If you lose your device or password file and have not backed it up somewhere safe, it is gone. Use at your own risk, and use a strong password you can remember.

## Current Status

KeyTitan is still in active development. Releases are not published yet ; you can build it yourself as well.

Supported or actively worked-on targets:

- Windows
- Linux
- Android

Partially scaffolded targets:

- macOS
- iOS

## Building

You will need Flutter/Dart and, if you want Google Drive sync, your own Google Cloud OAuth client IDs configured through Envied in `kt.env`.

The app also has an experimental Rust native core in `native/keytitan_core`. Its crypto entry points implement only the legacy KTN3/c20p1 format and are retained as migration and future platform-integration groundwork. Current KTN4 vault and c20p2 field encryption is implemented in Dart. Release builds intentionally do not bundle Rust artifacts; any future native integration must implement the documented KTN4 format and pass cross-language compatibility tests before it is enabled.

Useful commands:

```sh
flutter pub get
flutter test
flutter analyze

cd native/keytitan_core
cargo test --locked
```

## Storage Locations

Vault files are user-selected on desktop and stored in app-private application documents storage on Android.

The settings JSON is separate from vault files; it contains only minor user-specific settings:

- Windows: `%APPDATA%\keytitan\keytitan_settings.json`
- Linux: `$XDG_CONFIG_HOME/keytitan/keytitan_settings.json`, or `~/.config/keytitan/keytitan_settings.json`
- Android: app-private application documents storage
- macOS/iOS: the platform application support directory

## How Do I Maximize Security?

### Use A Complex Password For Your File

An old [XKCD comic](https://xkcd.com/936/) comes to mind. Generally, length is better than complexity, though you ideally want both. Avoid keyboard walks; they were innovative 20 years ago, and now they are probably on every password cracking list. For a vault password, prefer a long passphrase or a high-entropy password; 16+ characters is a much better floor than 10-12, and more is better.

### Clipboard Or Autofill?

Many things in security are a tradeoff. KeyTitan supports clipboard output and security-gated Android autofill. Desktop browser/plugin autofill is not implemented. The iOS credential-provider scaffold does not return passwords.

The pro of the clipboard is that it is simple and has little OS integration. The downside is that background apps on desktop, and foreground apps on Android 10+, can observe clipboard contents. KeyTitan can clear the clipboard after a timer, but clipboard history and other apps are ultimately controlled by the OS.

Android autofill initially returns one generic authenticated suggestion and no credential values. After selection, KeyTitan shows the exact package, signing-certificate digest, and web origin; requires explicit approval for an unverified destination; requires biometric or device-lock authentication; and only then shows the account choices inside KeyTitan. After one account is selected and confirmed, only that password is decrypted. Approvals bind to the package certificate and, for WebViews, the exact origin. Exact origins are matched conservatively: schemes, subdomains, and non-default ports are not treated as interchangeable. Native app associations can be made explicit with `androidapp://com.example.app?sha256_cert=<SHA-256>`.

Autofill currently requires the vault to already be open. KeyTitan does not create or sync a device wrapper for the KTN4 vault key, so device authentication authorizes one release but is not a second way to unlock the vault. A future opt-in quick-unlock feature can add a local Android Keystore wrapper without changing the portable master-password wrapper.

The complete request, trust, partitioning, capability, and plaintext-boundary invariants are documented in [ANDROID_AUTOFILL_SECURITY.md](ANDROID_AUTOFILL_SECURITY.md).

The OS still controls the final credential handoff, and autofill systems have had real-world bugs and leakage risks (for example, [autospill](https://www.bleepingcomputer.com/news/security/autospill-attack-steals-credentials-from-android-password-managers/)). If there is already malware or root/kernel-level compromise on your device, both approaches are in a bad neighborhood.

### If Using The Clipboard, Guard Your Clipboard

The app defaults to clipboard use. I strongly recommend enabling the setting that clears copied passwords after a timer. Modern operating systems may also keep clipboard history; consider disabling it:

- Windows: Settings -> System -> Clipboard -> Clipboard history off
- Android: clipboard history is usually controlled by your keyboard app or Android settings
   - Samsung Keyboard: open the keyboard clipboard and delete stored items
   - Gboard: disable clipboard history in Gboard settings

### Should I Use Google Drive?

Drive sync is optional. KeyTitan uploads/downloads encrypted `.ktn` files from a `KeyTitanBackup` folder in your Google Drive. An attacker would need access to your Google account or local synced copy and would still need to attack the strong vault encryption. I use Drive because it makes syncing easier, but the risk tradeoff is yours.

## How Does It Keep Passwords Secure?

### In Plain English

Passwords are stored in an encrypted `.ktn` vault file. When you unlock a vault, KeyTitan decrypts the SQLite database into memory. Password fields remain in a second layer of encryption inside that in-memory database and are decrypted only when needed for copy, edit, or a selected and authenticated Android autofill request.

Credential changes are encrypted and saved immediately. Pending changes are also retried when the app backgrounds, the window loses focus, the vault auto-locks, or you choose "Save & Close". A failed save leaves the vault open in memory and reports an error instead of silently locking or closing. "Close without saving" discards only changes that are still pending after a failed save; it cannot undo changes that were already auto-saved.

### For The Nerds Among Us

The current vault format is KTN4:

- A random 32-byte data-encryption key (DEK) encrypts the SQLite payload with ChaCha20-Poly1305.
- Argon2id (64 MiB memory, parallelism 2, iterations 3) derives a key-encryption key (KEK) from the master password and a random salt.
- The KEK wraps only the DEK. Routine saves reuse that wrapped DEK, increment an authenticated revision, and encrypt with a fresh 12-byte payload nonce.
- Changing the master password verifies the old password, generates a replacement DEK, rekeys the password fields, and wraps the replacement with a fresh salt and nonce. This prevents a DEK recovered from an older vault copy from decrypting future versions.
- Password fields use a second ChaCha20-Poly1305 layer keyed from the random DEK (`c20p2`).
- Header parameters, the wrapped key, revision, and payload are authenticated. Header salts, nonces, the random vault ID, and the wrapped key are intentionally not secret.
- SQLite is opened through an in-memory virtual filesystem; decrypted and exported database byte buffers are wiped after use where possible.

Legacy KTN3 vaults and their `c20p1` fields remain readable. The first successful save silently converts the in-memory fields and writes KTN4. Migration is one-way: older KeyTitan builds cannot open the upgraded file. The precise byte layout and compatibility rules are in [VAULT_FORMAT.md](VAULT_FORMAT.md).

Memory protection is defense-in-depth:

- The master password byte buffer is used to unwrap a KTN4 vault key and is then zeroed. It is retained temporarily only while creating a new vault envelope or migrating an unlocked KTN3 vault.
- The random vault DEK remains in process memory only while the vault is unlocked and is zeroed when the vault is disposed.
- Argon2id-derived KEKs, field-encryption keys, decrypted vault byte buffers, and exported SQLite bytes are zeroed after use where the code has direct byte-buffer access.
- The legacy Rust native core uses `zeroize` for derived keys and wipes buffers returned through the FFI boundary when Dart calls back into `ktn_free`. Dart-owned FFI input copies are also wiped before being freed.
- The in-memory SQLite database stores password fields as ciphertext. Titles, sites, usernames, categories, and URI metadata are not separately encrypted while the vault is open.
- Plaintext passwords are only produced for immediate copy, edit, or one selected and authenticated Android autofill action. Dialog controllers are cleared promptly, and clipboard clearing is configurable, but Dart/Kotlin `String` objects, OS clipboards, and the final Android autofill handoff are managed by their runtimes/platforms and cannot be guaranteed to zero memory.

In other words: KeyTitan tries not to keep plaintext around longer than needed, but it is not a defense against a hostile process, memory scraper, root/kernel compromise, or malicious OS component.

The current KTN4 crypto and conservative URI-normalization paths are Dart-only. The legacy Rust core's KTN3/c20p1 crypto APIs are not called by the current vault implementation. Release builds do not package manually built or prebuilt native libraries.

Cloud sync uses Google OAuth. I do not personally collect data, but authenticating with Google means the application can access the Drive files needed for KeyTitan backup/sync.

#### Why ChaCha20?

[ChaCha20-Poly1305](https://en.wikipedia.org/wiki/ChaCha20-Poly1305) is fast and widely used in modern secure protocols such as TLS 1.3, SSH, and WireGuard. It performs well on devices without AES acceleration and has a clean authenticated-encryption construction. As symmetric cryptography, its 256-bit key size is generally considered resistant to known practical quantum attacks; Grover-style search would still leave a very large security margin. Also, yes, it is fun to say.

## License

This project is licensed under the Apache 2.0 license. See `LICENSE.md` for details, or go to http://www.apache.org/licenses/LICENSE-2.0.
