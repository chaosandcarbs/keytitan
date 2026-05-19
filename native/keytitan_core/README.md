# KeyTitan Native Core

This crate exposes the KeyTitan vault crypto boundary through a small C ABI.
Flutter uses it through Dart FFI when the compiled library is bundled, and falls
back to the Dart implementation when it is not present.

The native core currently handles:

- `.ktn` v3 ChaCha20-Poly1305 vault encryption/decryption
- legacy v2 Salsa20 vault decryption
- Argon2id key derivation for vault files
- per-entry ChaCha20-Poly1305 encryption/decryption
- legacy per-entry AES-CBC decryption
- URI derivation for web and Android autofill matching

SQLite stays memory-only in Dart for now. That keeps current Windows, Linux, and
Android behavior intact while giving iOS extensions and future platform code a
native crypto surface to call.

## Windows

```powershell
cd native/keytitan_core
cargo build --release
```

Flutter can load the DLL directly from `target/release` during development.
The Windows CMake bundle step also copies it beside the app executable when it
exists.

## Linux

```bash
cd native/keytitan_core
cargo build --release
```

The Linux CMake bundle step copies `target/release/libkeytitan_core.so` into the
app `lib/` directory when it exists.

From Linux/WSL/CI you can also run:

```bash
native/keytitan_core/scripts/build_linux.sh
```

The Windows Rust toolchain can install `x86_64-unknown-linux-gnu`, but it cannot
finish this build without a Linux GNU linker and sysroot. The musl target builds
a static archive on Windows, but Rust drops `cdylib` for that target, so it does
not produce the `libkeytitan_core.so` that Dart FFI expects.

## Android

Install the Android Rust targets and build shared libraries for each ABI you
intend to ship, then place them here:

```text
native/keytitan_core/prebuilt/android/
  arm64-v8a/libkeytitan_core.so
  armeabi-v7a/libkeytitan_core.so
  x86_64/libkeytitan_core.so
```

Gradle is configured to package that directory as `jniLibs`. Until those
libraries are present, Android continues to use the Dart fallback.
