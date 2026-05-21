use argon2::{Algorithm, Argon2, Params, Version};
use base64::{engine::general_purpose, Engine as _};
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Nonce,
};
use sha2::{Digest, Sha256};
use std::{panic, ptr, slice};
use zeroize::Zeroize;

const KTN3_MAGIC: &[u8; 4] = b"KTN3";
const SQLITE_HEADER: &[u8; 16] = b"SQLite format 3\0";
const FIELD_PREFIX: &str = "c20p1";

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KtnStatus {
    Ok = 0,
    NullArgument = 1,
    InvalidInput = 2,
    CryptoError = 3,
    AllocationError = 4,
    Panic = 255,
}

#[no_mangle]
pub extern "C" fn ktn_version(out_ptr: *mut *mut u8, out_len: *mut usize) -> KtnStatus {
    guard(|| write_output(b"keytitan_core 0.1.0".to_vec(), out_ptr, out_len))
}

#[no_mangle]
pub extern "C" fn ktn_decrypt_vault(
    input_ptr: *const u8,
    input_len: usize,
    password_ptr: *const u8,
    password_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> KtnStatus {
    guard(|| {
        let input = read_slice(input_ptr, input_len)?;
        let password = read_slice(password_ptr, password_len)?;
        let decrypted = decrypt_vault_bytes(input, password)?;
        write_output(decrypted, out_ptr, out_len)
    })
}

#[no_mangle]
pub extern "C" fn ktn_encrypt_vault(
    sqlite_ptr: *const u8,
    sqlite_len: usize,
    password_ptr: *const u8,
    password_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> KtnStatus {
    guard(|| {
        let sqlite = read_slice(sqlite_ptr, sqlite_len)?;
        let password = read_slice(password_ptr, password_len)?;
        if !is_sqlite_bytes(sqlite) {
            return Err(KtnStatus::InvalidInput);
        }
        let encrypted = encrypt_vault_bytes(sqlite, password)?;
        write_output(encrypted, out_ptr, out_len)
    })
}

#[no_mangle]
pub extern "C" fn ktn_field_encrypt(
    password_ptr: *const u8,
    password_len: usize,
    plaintext_ptr: *const u8,
    plaintext_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> KtnStatus {
    guard(|| {
        let password = read_slice(password_ptr, password_len)?;
        let plaintext = read_slice(plaintext_ptr, plaintext_len)?;
        let encrypted = field_encrypt(password, plaintext)?;
        write_output(encrypted.into_bytes(), out_ptr, out_len)
    })
}

#[no_mangle]
pub extern "C" fn ktn_field_decrypt(
    password_ptr: *const u8,
    password_len: usize,
    ciphertext_ptr: *const u8,
    ciphertext_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> KtnStatus {
    guard(|| {
        let password = read_slice(password_ptr, password_len)?;
        let ciphertext = read_slice(ciphertext_ptr, ciphertext_len)?;
        let decrypted = field_decrypt(password, ciphertext)?;
        write_output(decrypted, out_ptr, out_len)
    })
}

#[no_mangle]
pub extern "C" fn ktn_derive_uris(
    site_ptr: *const u8,
    site_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> KtnStatus {
    guard(|| {
        let site = read_slice(site_ptr, site_len)?;
        let site = std::str::from_utf8(site).map_err(|_| KtnStatus::InvalidInput)?;
        write_output(derive_uris(site).into_bytes(), out_ptr, out_len)
    })
}

/// # Safety
///
/// `ptr` and `len` must be a buffer previously returned by keytitan_core with
/// the same length. Passing any other pointer, or freeing the same pointer more
/// than once, is undefined behavior.
#[no_mangle]
pub unsafe extern "C" fn ktn_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    unsafe {
        let mut buf = Vec::from_raw_parts(ptr, len, len);
        buf.zeroize();
    }
}

fn guard<F>(f: F) -> KtnStatus
where
    F: FnOnce() -> Result<KtnStatus, KtnStatus>,
{
    match panic::catch_unwind(panic::AssertUnwindSafe(f)) {
        Ok(result) => result.unwrap_or_else(|status| status),
        Err(_) => KtnStatus::Panic,
    }
}

fn read_slice<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], KtnStatus> {
    if ptr.is_null() {
        return if len == 0 {
            Ok(&[])
        } else {
            Err(KtnStatus::NullArgument)
        };
    }
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}

fn write_output(
    data: Vec<u8>,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> Result<KtnStatus, KtnStatus> {
    if out_ptr.is_null() || out_len.is_null() {
        return Err(KtnStatus::NullArgument);
    }
    let mut boxed = data.into_boxed_slice();
    let len = boxed.len();
    let ptr = if len == 0 {
        ptr::null_mut()
    } else {
        boxed.as_mut_ptr()
    };
    std::mem::forget(boxed);
    unsafe {
        *out_ptr = ptr;
        *out_len = len;
    }
    Ok(KtnStatus::Ok)
}

fn decrypt_vault_bytes(input: &[u8], password: &[u8]) -> Result<Vec<u8>, KtnStatus> {
    if input.len() < 49 || !input.starts_with(KTN3_MAGIC) {
        return Err(KtnStatus::InvalidInput);
    }

    let nonce = &input[4..16];
    let salt = &input[16..32];
    let payload = &input[32..];
    let mut key = derive_argon2id_key(password, salt)?;
    let decrypted = decrypt_chacha20_poly1305(&key, nonce, payload);
    key.zeroize();
    let decrypted = decrypted?;
    if is_sqlite_bytes(&decrypted) {
        return Ok(decrypted);
    }
    Err(KtnStatus::InvalidInput)
}

fn encrypt_vault_bytes(sqlite: &[u8], password: &[u8]) -> Result<Vec<u8>, KtnStatus> {
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    getrandom::getrandom(&mut salt).map_err(|_| KtnStatus::CryptoError)?;
    getrandom::getrandom(&mut nonce).map_err(|_| KtnStatus::CryptoError)?;

    let mut key = derive_argon2id_key(password, &salt)?;
    let payload = encrypt_chacha20_poly1305(&key, &nonce, sqlite);
    key.zeroize();
    let payload = payload?;

    let mut out = Vec::with_capacity(4 + nonce.len() + salt.len() + payload.len());
    out.extend_from_slice(KTN3_MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&salt);
    out.extend_from_slice(&payload);
    Ok(out)
}

fn derive_argon2id_key(password: &[u8], salt: &[u8]) -> Result<[u8; 32], KtnStatus> {
    let params = Params::new(65_536, 3, 2, Some(32)).map_err(|_| KtnStatus::CryptoError)?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = [0u8; 32];
    argon2
        .hash_password_into(password, salt, &mut key)
        .map_err(|_| KtnStatus::CryptoError)?;
    Ok(key)
}

fn encrypt_chacha20_poly1305(
    key: &[u8],
    nonce: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>, KtnStatus> {
    let cipher = ChaCha20Poly1305::new_from_slice(key).map_err(|_| KtnStatus::CryptoError)?;
    cipher
        .encrypt(Nonce::from_slice(nonce), plaintext)
        .map_err(|_| KtnStatus::CryptoError)
}

fn decrypt_chacha20_poly1305(
    key: &[u8],
    nonce: &[u8],
    payload: &[u8],
) -> Result<Vec<u8>, KtnStatus> {
    if payload.len() < 16 || nonce.len() != 12 {
        return Err(KtnStatus::InvalidInput);
    }
    let cipher = ChaCha20Poly1305::new_from_slice(key).map_err(|_| KtnStatus::CryptoError)?;
    cipher
        .decrypt(Nonce::from_slice(nonce), payload)
        .map_err(|_| KtnStatus::CryptoError)
}

fn is_sqlite_bytes(bytes: &[u8]) -> bool {
    bytes.len() >= SQLITE_HEADER.len() && &bytes[..SQLITE_HEADER.len()] == SQLITE_HEADER
}

fn field_encrypt(password: &[u8], plaintext: &[u8]) -> Result<String, KtnStatus> {
    if plaintext.is_empty() {
        return Ok(String::new());
    }
    let mut nonce = [0u8; 12];
    getrandom::getrandom(&mut nonce).map_err(|_| KtnStatus::CryptoError)?;

    let mut key = derive_field_key(password);
    let payload = encrypt_chacha20_poly1305(&key, &nonce, plaintext);
    key.zeroize();
    let payload = payload?;

    Ok(format!(
        "{}:{}:{}",
        FIELD_PREFIX,
        general_purpose::STANDARD.encode(nonce),
        general_purpose::STANDARD.encode(payload),
    ))
}

fn field_decrypt(password: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>, KtnStatus> {
    if ciphertext.is_empty() {
        return Ok(Vec::new());
    }
    let text = std::str::from_utf8(ciphertext).map_err(|_| KtnStatus::InvalidInput)?;
    if !text.starts_with(&format!("{}:", FIELD_PREFIX)) {
        return Err(KtnStatus::InvalidInput);
    }
    field_decrypt_chacha20(password, text)
}

fn field_decrypt_chacha20(password: &[u8], text: &str) -> Result<Vec<u8>, KtnStatus> {
    let parts: Vec<&str> = text.split(':').collect();
    if parts.len() != 3 {
        return Err(KtnStatus::InvalidInput);
    }
    let nonce = general_purpose::STANDARD
        .decode(parts[1])
        .map_err(|_| KtnStatus::InvalidInput)?;
    let payload = general_purpose::STANDARD
        .decode(parts[2])
        .map_err(|_| KtnStatus::InvalidInput)?;
    let mut key = derive_field_key(password);
    let decrypted = decrypt_chacha20_poly1305(&key, &nonce, &payload);
    key.zeroize();
    decrypted
}

fn derive_field_key(password: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(b"KeyTitan field encryption v1");
    hasher.update(password);
    hasher.finalize().into()
}

fn derive_uris(site: &str) -> String {
    let raw = site.trim();
    if raw.is_empty() {
        return "[]".to_string();
    }

    let mut values = Vec::<String>::new();
    push_unique(&mut values, raw.to_string());
    let lower_raw = raw.to_lowercase();
    if lower_raw.starts_with("androidapp://") || lower_raw.starts_with("app://") {
        if let Some(package_name) = lower_raw
            .split("://")
            .nth(1)
            .and_then(|v| v.split('/').next())
        {
            if !package_name.is_empty() {
                push_unique(&mut values, package_name.to_string());
            }
        }
        return json_array(&values);
    }

    let host = normalized_host(raw);
    if !host.is_empty() {
        push_unique(&mut values, host.clone());
        if host.contains('.') {
            push_unique(&mut values, format!("https://{}", host));
            if !host.starts_with("www.") {
                push_unique(&mut values, format!("https://www.{}", host));
            }
        }
    }

    json_array(&values)
}

fn normalized_host(raw: &str) -> String {
    let lower = raw.to_lowercase();
    let without_scheme = if lower.starts_with("https://") {
        &raw[8..]
    } else if lower.starts_with("http://") {
        &raw[7..]
    } else {
        raw
    };
    without_scheme
        .split('/')
        .next()
        .unwrap_or("")
        .to_lowercase()
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !values.iter().any(|existing| existing == &value) {
        values.push(value);
    }
}

fn json_array(values: &[String]) -> String {
    let mut out = String::from("[");
    for (index, value) in values.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push('"');
        for c in value.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out.push('"');
    }
    out.push(']');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vault_v3_round_trips_sqlite_bytes() {
        let mut sqlite = b"SQLite format 3\0".to_vec();
        sqlite.extend_from_slice(&[0u8; 128]);
        let password = b"correct horse battery staple";

        let encrypted = encrypt_vault_bytes(&sqlite, password).unwrap();
        assert_ne!(encrypted, sqlite);
        assert!(encrypted.starts_with(KTN3_MAGIC));

        let decrypted = decrypt_vault_bytes(&encrypted, password).unwrap();
        assert_eq!(decrypted, sqlite);
        assert!(decrypt_vault_bytes(&encrypted, b"wrong password").is_err());
    }

    #[test]
    fn field_encryption_round_trips_and_rejects_wrong_password() {
        let password = b"master-password";
        let encrypted = field_encrypt(password, b"entry-password").unwrap();
        assert!(encrypted.starts_with("c20p1:"));

        let decrypted = field_decrypt(password, encrypted.as_bytes()).unwrap();
        assert_eq!(decrypted, b"entry-password");
        assert!(field_decrypt(b"wrong", encrypted.as_bytes()).is_err());
    }

    #[test]
    fn vault_decrypt_rejects_non_v3_input() {
        let mut old_shape = vec![0u8; 25];
        old_shape[0..16].copy_from_slice(SQLITE_HEADER);
        assert!(decrypt_vault_bytes(&old_shape, b"password").is_err());
    }

    #[test]
    fn uri_derivation_adds_web_identifiers_without_package_guessing() {
        let uris = derive_uris("https://amazon.com/login");
        assert!(uris.contains("\"amazon.com\""));
        assert!(uris.contains("\"https://amazon.com\""));
        assert!(uris.contains("\"https://www.amazon.com\""));
        assert!(!uris.contains("androidapp://"));

        let app_uris = derive_uris("androidapp://com.example.app");
        assert!(app_uris.contains("\"androidapp://com.example.app\""));
        assert!(app_uris.contains("\"com.example.app\""));
    }
}
