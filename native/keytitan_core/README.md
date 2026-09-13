# KeyTitan Native Core

This crate exposes a legacy/experimental KeyTitan boundary through a small C
ABI. Its crypto functions implement KTN3 and c20p1, not the current KTN4 and
c20p2 formats. The Flutter vault implementation therefore does not call these
crypto functions. It can use the crate's URI derivation during development when
a locally built library is present. Release builds do not currently bundle Rust
artifacts: this prevents an old, manually copied binary from silently diverging
from the reviewed source.

The native core currently handles:

- `.ktn` v3 ChaCha20-Poly1305 vault encryption/decryption
- Argon2id key derivation for vault files
- per-entry ChaCha20-Poly1305 encryption/decryption
- URI derivation for web and Android autofill matching

SQLite and current-format crypto stay in Dart for now. The crate remains useful
as a foundation for iOS extensions and other future platform code, but its
legacy crypto ABI must not be connected to KTN4 vault writes.

Any future native KTN4 implementation must follow `../../VAULT_FORMAT.md` and
pass fixed cross-language vectors for both successful operations and tamper
rejection before the app calls it.

## Windows

```powershell
cd native/keytitan_core
cargo build --locked --release
```

Flutter can load the DLL directly from `target/release` during development.
It is not copied into release bundles automatically. A future native release
integration must build the crate from the locked source as part of that build.

## Linux

```bash
cd native/keytitan_core
cargo build --locked --release
```

Flutter can load `target/release/libkeytitan_core.so` during development. It is
not copied into release bundles automatically.

From Linux/WSL/CI you can also run:

```bash
native/keytitan_core/scripts/build_linux.sh
```

The Windows Rust toolchain can install `x86_64-unknown-linux-gnu`, but it cannot
finish this build without a Linux GNU linker and sysroot. The musl target builds
a static archive on Windows, but Rust drops `cdylib` for that target, so it does
not produce the `libkeytitan_core.so` that Dart FFI expects.

## Android

Android currently uses the Dart implementation. Do not manually check in or
package prebuilt `.so` files. If Android is connected to the native core in the
future, Gradle/CI must compile every ABI from this crate with `--locked` and run
the cross-language compatibility tests against the packaged libraries.

## Release rule

Never package a library merely because it happens to exist under `target/` or a
`prebuilt/` directory. A native artifact is release-eligible only when the same
build invocation compiles it from this `Cargo.lock` and runs the native FFI
check in `tool/check_native_core.dart` against that exact output.

That check currently validates only the legacy KTN3/c20p1 ABI plus URI
derivation. Passing it does not establish KTN4 compatibility.
