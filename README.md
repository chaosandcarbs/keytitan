# KeyTitan

A simple, cross-platform, local password manager. Primary development is focused on Windows, Linux, and Android, with some macOS/iOS scaffolding in place.

## Description

KeyTitan is a standalone local password manager. Your vault is a local `.ktn` file, and optional Google Drive sync can upload/download those encrypted files between devices. The app does not run a KeyTitan server and does not store your passwords outside your vault or Google Drive (if you so choose).

Vault files are encrypted with ChaCha20-Poly1305 using a key derived from your vault password with Argon2id. ChaCha20-Poly1305 uses 256-bit symmetric keys and is generally considered quantum-resistant in the practical post-quantum sense; the harder real-world problem is still choosing a vault password with enough entropy. Individual password values are also encrypted inside the in-memory SQLite database while a vault is open.

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

The app also has a Rust native core in `native/keytitan_core`. It handles the same vault and field encryption format as the Dart fallback, and is used when the native library is available. This keeps the crypto boundary available for future platform integrations, including Apple credential/keychain-related work, without making the Dart implementation unusable during development.

Useful commands:

```sh
flutter pub get
flutter test
flutter analyze

cd native/keytitan_core
cargo test
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

Many things in security are a tradeoff. KeyTitan supports clipboard output and Android autofill. Desktop browser/plugin autofill is not implemented.

The pro of the clipboard is that it is simple and has little OS integration. The downside is that background apps on desktop, and foreground apps on Android 10+, can observe clipboard contents. KeyTitan can clear the clipboard after a timer, but clipboard history and other apps are ultimately controlled by the OS.

The pro of autofill is that it is built into the operating system and can match credentials to app/site identifiers. In most cases, there is some security built in as well, though that varies by OS and possibly browser. The downside is that the OS controls the credential handoff, and autofill systems have had real-world bugs and leakage risks (for example, [autospill](https://www.bleepingcomputer.com/news/security/autospill-attack-steals-credentials-from-android-password-managers/)). If there is already malware or root/kernel-level compromise on your device, both approaches are in a bad neighborhood.

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

Passwords are stored in an encrypted `.ktn` vault file. When you unlock a vault, KeyTitan decrypts the SQLite database into memory. Password fields remain in a second layer of encryption inside that in-memory database and are decrypted only when needed for copy, edit, or autofill.

If you add or update passwords and choose "Save & Close", the database is serialized, encrypted, and written back to the vault file. If you close without saving, the in-memory database is disposed and the file remains unchanged.

### For The Nerds Among Us

The current vault format is v3:

- Magic prefix: `KTN3`
- KDF: Argon2id, 64 MiB memory, parallelism 2, iterations 3, 32-byte key
- Vault encryption: ChaCha20-Poly1305 with a fresh 12-byte nonce and 16-byte salt on every save
- Field encryption: ChaCha20-Poly1305 with a key derived from the master password bytes and a domain separator
- SQLite: opened through an in-memory virtual filesystem; exported bytes are wiped after encryption when possible

Memory protection is defense-in-depth:

- The vault password is converted to a byte buffer when the vault is opened. That buffer stays available while the vault is open because it is needed for save, copy, edit, and autofill operations, then it is zeroed when the vault is disposed.
- Argon2id-derived vault keys, field-encryption keys, decrypted vault byte buffers, and exported SQLite bytes are zeroed after use where the code has direct byte-buffer access.
- The Rust native core uses `zeroize` for derived keys and wipes buffers returned through the FFI boundary when Dart calls back into `ktn_free`. Dart-owned FFI input copies are also wiped before being freed.
- The in-memory SQLite database stores password fields as ciphertext. Titles, sites, usernames, categories, and URI metadata are not separately encrypted while the vault is open.
- Plaintext passwords are only produced for immediate user actions: copy, edit, or autofill. Dialog controllers are cleared promptly, and clipboard clearing is configurable, but Dart `String` objects, OS clipboards, and OS autofill handoff are managed by their runtimes/platforms and cannot be guaranteed to zero memory.

In other words: KeyTitan tries not to keep plaintext around longer than needed, but it is not a defense against a hostile process, memory scraper, root/kernel compromise, or malicious OS component.

Rust native crypto is attempted first when the native library is present; otherwise the Dart implementation uses the same current formats.

Cloud sync uses Google OAuth. I do not personally collect data, but authenticating with Google means the application can access the Drive files needed for KeyTitan backup/sync.

#### Why ChaCha20?

[ChaCha20-Poly1305](https://en.wikipedia.org/wiki/ChaCha20-Poly1305) is fast and widely used in modern secure protocols such as TLS 1.3, SSH, and WireGuard. It performs well on devices without AES acceleration and has a clean authenticated-encryption construction. As symmetric cryptography, its 256-bit key size is generally considered resistant to known practical quantum attacks; Grover-style search would still leave a very large security margin. Also, yes, it is fun to say.

## License

This project is licensed under the Apache 2.0 license. See `LICENSE.md` for details, or go to http://www.apache.org/licenses/LICENSE-2.0.
