# KeyTitan

A simple, cross-platform, local password manager. Primary development is focused on Windows, Linux, and Android, with some macOS/iOS scaffolding in place.

## Description

KeyTitan is a standalone local password manager. Your vault is a local `.ktn` file, and optional Google Drive sync can upload/download those encrypted files between devices. The app does not run a KeyTitan server and does not store your passwords outside your vault. Vault details are discussed in greater detail in the VAULT_FORMAT.md.  Vault keys, and the vault contents itself are wrapped in ChaCha20-Poly1305, which is a modern cryptographic algorithm that is quantum-resistant.

## Design Philosophy

I wanted to make a simple but secure password manager that can share passwords between platforms without turning into another web account you have to trust.

- No 3rd-party account or credential server outside your immediate control
- No unnecessary authentication; I don't care who you are.
- No network use beyond optional Google Drive authentication/sync (optional).
- No ads or bloat.

Everything is your responsibility. If you forget your vault password, the file is unrecoverable (it is secure by design). If you lose your device or password file and have not backed it up somewhere safe, it is gone. Use at your own risk, and use a strong password you can remember.

## Current Status

KeyTitan is still in active development. Releases are not published yet ; you can build it yourself as well.

Supported or actively worked-on targets:

- Windows
- Linux
- Android

Development is centered around distrust of the Operating System (OS). Autofill (currently Android-only) breaks that somewhat, but only if explicitly enabled by a user. 

Apple's iOS/macOS essentially force you to trust the OS (part of their walled-garden approach). While their native keychain is well implemented overall it still provides less protection should an attacker manage to get root access. 

## Building Yourself

You will need Flutter/Dart and, if you want Google Drive sync, your own Google Cloud OAuth client IDs configured through Envied in `kt.env`. An example is provided in git. 

## Storage Locations

Vault files are user-selected on desktop and stored in app-private application documents storage on Android.

The settings JSON is separate from vault files; it contains only minor user-specific settings:

- Windows: `%APPDATA%\keytitan\keytitan_settings.json`
- Linux: `$XDG_CONFIG_HOME/keytitan/keytitan_settings.json`, or `~/.config/keytitan/keytitan_settings.json`
- Android: app-private application documents storage

## How Do I Maximize Security?

### Use A Complex Password For Your File

An old [XKCD comic](https://xkcd.com/936/) comes to mind. Generally, length is better than complexity, though you ideally want both. Avoid keyboard walks; they were innovative 20 years ago, and now they are probably on every password cracking list. For a vault password, prefer a long passphrase or a high-entropy password; 16+ characters is a much better floor than 10-12, and more is better.

### Clipboard Or Autofill?

Many things in security are a tradeoff. KeyTitan supports clipboard output and security-gated Android autofill. Desktop browser/plugin autofill is not implemented. The iOS credential-provider scaffold does not return passwords.

The pro of the clipboard is that it is simple and has little OS integration. The downside is that background apps on desktop, and foreground apps on Android 10+, can observe clipboard contents. KeyTitan can clear the clipboard after a timer, but clipboard history and other apps are ultimately controlled by the OS.

Android autofill initially returns one generic authenticated suggestion and no credential values. After selection, KeyTitan shows the exact package, signing-certificate digest, and web origin; requires explicit approval for an unverified destination; requires authentication; and only then shows the account choices inside KeyTitan. After one account is selected and confirmed, only that password is decrypted. Approvals bind to the package certificate and, for WebViews, the exact origin. Exact origins are matched conservatively: schemes, subdomains, and non-default ports are not treated as interchangeable. Native app associations can be made explicit with `androidapp://com.example.app?sha256_cert=<SHA-256>`.

The complete request, trust, partitioning, capability, and plaintext-boundary invariants are documented in [ANDROID_AUTOFILL_SECURITY.md](ANDROID_AUTOFILL_SECURITY.md).

The OS still controls the final credential handoff, and autofill systems have had real-world bugs and leakage risks (for example, [autospill](https://www.bleepingcomputer.com/news/security/autospill-attack-steals-credentials-from-android-password-managers/)). If there is already malware or root/kernel-level compromise on your device, both approaches carry obvious risk. 

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

Passwords are stored in an encrypted `.ktn` vault file. In a nutshell, your password + parts of your vault file are used to derive/decrypt a 32-byte key (KEK) which is then used to derive/decrypt a separate random 32-byte key (DEK) which is what actually encrypts your data. The two keys mean KeyTitan doesn't have to keep your vault password in memory or stored anywhere on device after you enter it and the KEK is derived. Both keys, and the vault contents itself are wrapped in ChaCha20-Poly1305, which is a modern cryptographic algorithm that is quantum-resistant when using 32-byte (256-bit) keys. When you unlock a vault, KeyTitan decrypts the SQLite database into memory. Password fields remain in a second layer of encryption inside that in-memory database and are decrypted only when needed for copy, edit, or a selected and authenticated Android autofill request.

Credential changes are encrypted and saved immediately. Pending changes are also retried when the app backgrounds, the window loses focus, the vault auto-locks, or you choose "Save & Close". A failed save leaves the vault open in memory and reports an error instead of silently locking or closing. "Close without saving" discards only changes that are still pending after a failed save; it cannot undo changes that were already auto-saved.

### For The Nerds Among Us

VAULT_FORMAT.md and ANDROID_AUTOFILL_SECURITY.md are both worth reading if you want the gory details. 

#### Why ChaCha20?

[ChaCha20-Poly1305](https://en.wikipedia.org/wiki/ChaCha20-Poly1305) is fast and widely used in modern secure protocols such as TLS 1.3, SSH, and WireGuard. It performs well on devices without AES acceleration and has a clean authenticated-encryption construction. As symmetric cryptography, its 256-bit key size is generally considered resistant to known practical quantum attacks; Grover-style search would still leave a very large security margin. Also, yes, it is fun to say.

## License

This project is licensed under the Apache 2.0 license. See `LICENSE.md` for details, or go to http://www.apache.org/licenses/LICENSE-2.0.
