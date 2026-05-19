# KeyTitan

A simple, cross-platform, local password manager. Primary development is for desktop (Windows, Linux) and Android. 

## Description

KeyTitan is a standalone local password manager that's meant to keep your data safe. Cloud integration (optional) uses your Google Drive account to let you sync files between devices. Passwords are always stored encryped with a quantum-resistant encryption algorithm.

## Getting Started

## Installing

Releases coming soon. Ish.

## Design Philosophy

I wanted to make a simple but secure password manager, that could share passwords between platforms. It uses local storage for securely encrypted passwords (plus Drive, if you so choose). 
 - No complicated website that stores your credentials on a 3rd party server (and adds yet another attack vector for hackers). 
 - No authentication with either myself some third party website.
 - No other network/internet beacons. 
 - No ads or bloat.

Everything is your responsibility. If you forget your primary password - the file is unrecoverable. If you lose your device or password file and haven't backed up somewhere safe, it's gone. Use at your own risk, and use a complex password you can remember.

## How Do I Maximize Security?

### Use A Complex Password For Your File(s)

An old [XKCD Comic](https://xkcd.com/936/) comes to mind. Generally, length is better than complexity though you ideally want both. Avoid keyboard walks - they were innovative 20 years ago, now everyone uses the same 5 or so and they're probably on every password cracking list. Very generally: At least 10-12 (ideally more) characters, and a mix of lower case, upper case, and numbers (bonus for special characters!).

### Guard Your Clipboard

As part of my design philosophy, I do not want my app to care what page you're on, or what service you're logging into, and inject into it. Nor do I want to rely on trust in the OS to handle autofill. However, if the app just copies to the clipboard, your password may persist there in plain text (which, is bad). To combat this, and as good practice, copy something else and/or clear your clipboard contents to remove it. However, modern operating systems may also keep a history of your clipboard contents; to turn this off:
 - Windows: Open Settings (Ctrl+I), Navigate to "System"->"Clipboard", and ensure "Clipboard history" is toggled off
 - Android: Turning off clipboard history may be part of your keyboard app (Samsung) or Android Settings. One or all of these should work:
    - Try opening Device Settings -> Notifications -> Special App Access -> Clipboard and/or Text Sharing -> Disable
    - Samsung Keyboard: On your keyboard, tap the three-dot menu, select "Clipboard", and delete all items (only removes recent history)
    - Gboard: Clipboard history is optional; you should be able to turn it off in gboard settings.

### Clipboard Or Autofill?

Many things in security are a tradeoff. KeyTitan supports clipboard output and
is adding mobile autofill support, with Android available first and iOS
scaffolded for a signed credential-provider extension.

The pro of a clipboard is it's easier, and there's little OS integration to mess with, or worry about security implications of. However, background apps in Windows/Linux, and foreground apps (in Android 10+) can still see what's on your clipboard. Control and responsibility is up to you; if you want to copy your password and then paste it into your facebook stream, or someone phishes you into logging into a fake site (e.g. f4c3b00k.com) - you can expose it. 

The pro of autofill integration is ease of use for the user, being built in to the operating system, and not fumbling around with the clipboard. They also (generally) won't mistake g00gle.com for google.com, as a user might if sent a phishing email, and inadvertently send a password to a credential harvesting site. However, the password entry is completely controlled by the OS at that point; previous attacks such as [autospill](https://www.bleepingcomputer.com/news/security/autospill-attack-steals-credentials-from-android-password-managers/) have taken advantage of that to leak user passwords by exploiting how autofill works. 

You either implicitly trust the OS and its handling of data, or you trust the user to be responsible. If there's pre-existing malware on your system (in the example of background apps listening for the clipboard) then in my humble opinion you are in a bad spot regardless of which method you use. 

### Should I Use Google Drive?

The files themselves are encrypted using a very good encryption algorithm (more below) that's also used for TLS, SSH, and trusted VPNs. Drive makes it easy to update the files across multiple devices, without having to trust a third party website. An attacker would have to breach your Google account, grab your encrypted file, and then crack the encryption on the file itself. I use Drive, because it makes things easier, and it's provided as an option. How comfortable you are with the risk is up to you. 

## How Does It Keep Passwords Secure?

### In Plain English

Passwords are stored in an encrypted file. When you type in your password in the app, the file is decrypted, and you can use your passwords. If you add or update passwords and save them, everything is re-encrypted back to the device. Your primary password for the file is protected and only used for encrypting and decrypting the file. When you want to use a password, it's copied to your device's clipboard at the click of a button to paste into whatever you're logging in to. 

### For The Nerds Among Us <3

Files are stored on disk using [ChaCha20-Poly1305](https://en.wikipedia.org/wiki/ChaCha20-Poly1305) encryption. Previously Salsa20 was used, but it's now been upgraded for enhanced security (old files still work, and will be upgraded quietly on their next save). After a user enters a password for the file, the app uses Argon2Id to protect the password in memory (this adds some latency for opening/closing the file - that's by design to make it tougher to crack). Files are loaded into an in-memory sqlite database, where the passwords themselves are also encrypted in-memory until retrieved. If a user hits "Save & Close" - everything is re-encrypted using the primary password and variables in memory are all zeroed out before being disposed. If a user hits "Exit", variables in memory are all zeroed out before being disposed and the file remains unchanged. Cloud sync is done via Google's Oauth2.

#### Why ChaCha20? Because It's Fun To Say?

[ChaCha20](https://en.wikipedia.org/wiki/ChaCha20-Poly1305), while not quite as fast as Salsa20, is still fairly quick while also being very secure. It's generally considered quantum-resistant, and can be found in things like TLS 1.3 (the HTTPS pages you view), SSH, and some VPNs like Wireguard. It's technically a stream cipher, but will be somewhat faster on phones or embedded devices than, say, AES-256. Also, it's fun to say.

## License

This project is licensed under the Apache 2.0 license - see the LICENSE.md for more details, or go to http://www.apache.org/licenses/LICENSE-2.0
