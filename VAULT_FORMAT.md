# KeyTitan vault format

All byte ranges below are half-open and all integers are unsigned big-endian.

## KTN4 (current writes)

KTN4 separates the master-password key from the key that encrypts vault data:

- `DEK`: a random 32-byte data-encryption key generated for the vault.
- `KEK`: a 32-byte key-encryption key derived from the UTF-8 master password and the header
  salt using Argon2id v1.3 (`v=19`; 64 MiB, 3 iterations, parallelism 2).
- The KEK encrypts (wraps) the DEK with ChaCha20-Poly1305.
- The DEK encrypts the SQLite payload with ChaCha20-Poly1305.

The file layout is:

| Range | Length | Meaning |
| --- | ---: | --- |
| `0..4` | 4 | ASCII magic `KTN4` |
| `4..8` | 4 | Header length, currently `132` |
| `8..12` | 4 | Argon2id memory in KiB, currently `65536` |
| `12..16` | 4 | Argon2id iterations, currently `3` |
| `16..20` | 4 | Argon2id parallelism, currently `2` |
| `20..36` | 16 | Random vault ID |
| `36..52` | 16 | Argon2id salt |
| `52..64` | 12 | DEK-wrapping nonce |
| `64..112` | 48 | Encrypted 32-byte DEK followed by its 16-byte Poly1305 tag |
| `112..120` | 8 | Payload revision; starts at 1 and increments on each write (current maximum `2^63 - 1`) |
| `120..132` | 12 | Payload nonce |
| `132..EOF` | variable | Encrypted SQLite bytes followed by a 16-byte Poly1305 tag |

The DEK wrapper authenticates bytes `0..64` as associated data. The payload
authenticates the complete header, bytes `0..132`, as associated data. This
binds the KDF parameters, vault identity, wrapped DEK, revision, and payload
nonce to the ciphertext. The implementation rejects unsupported KDF parameters
before running Argon2id so an untrusted file cannot request arbitrary work.

Salt, nonces, the vault ID, revision, and wrapped DEK are public metadata. They
do not reveal the master password, DEK, or vault contents. Fresh randomness is
required whenever a new wrapper or payload ciphertext is produced. Routine
saves copy the existing wrapper unchanged; they do not perform another
encryption operation with its wrapping nonce.

### Lifecycle

1. Creation generates a random DEK. The master password derives a KEK, which
   wraps the DEK. The KEK and master-password byte buffer are then discarded.
2. Unlock derives the KEK, authenticates and unwraps the DEK, authenticates and
   decrypts the payload, then discards the KEK and master-password byte buffer.
3. While unlocked, the DEK remains in memory and encrypts password fields and
   routine vault saves. Each save uses a fresh payload nonce and increments the
   revision; it does not rerun Argon2id.
4. Changing the master password authenticates the current password by unwrapping
   the stored DEK, generates a replacement DEK, rekeys every `c20p2` password
   field, and encrypts the payload with the replacement. A KEK derived from the
   new password wraps the replacement DEK with a fresh salt and nonce. The vault
   ID remains stable.
5. Locking closes the in-memory database and zeroes the DEK buffer where Dart
   provides direct access to it.

The revision is authenticated but is not, by itself, rollback protection. A
device with no trusted external record cannot distinguish an authentic older
copy of the whole vault from the newest copy.

## Password fields

KTN4 password values inside SQLite use the prefix `c20p2`. Their 32-byte key is
HMAC-SHA-256 with the random DEK as the HMAC key and the UTF-8 domain separator
`KeyTitan field encryption v2` as the message. Each value is
ChaCha20-Poly1305 encrypted with a fresh random 12-byte nonce. The plaintext is
UTF-8 and the nonce and ciphertext-plus-tag use standard padded Base64:

```text
c20p2:<base64 nonce>:<base64 ciphertext+tag>
```

Titles, sites, usernames, categories, and URI metadata are plaintext inside the
SQLite payload, but the complete SQLite payload is encrypted at rest.

## KTN3 (read/migrate only)

KTN3 remains supported for backward compatibility:

```text
"KTN3" || 12-byte nonce || 16-byte salt || encrypted SQLite || 16-byte tag
```

Its payload key is derived directly from the UTF-8 master password using the
same Argon2id v1.3 parameters. KTN3 payload encryption has no associated data.
Password fields use the `c20p1` prefix and the v1 domain separator with the
master-password bytes as their seed.

On the first successful save after a KTN3 unlock, KeyTitan generates a random
DEK, converts every `c20p1` field to `c20p2` in memory, and writes KTN4. If
conversion, encryption, or persistence fails, the in-memory field conversion is
rolled back and the original KTN3 file remains in place. The upgrade is silent
and one-way; older builds that understand only KTN3 cannot open the new file.
