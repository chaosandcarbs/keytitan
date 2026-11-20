/// Best-effort cleanup for buffers owned by this application. Managed strings
/// and copies inside runtimes/platform APIs cannot be reliably overwritten.
void wipeBytes(List<int>? bytes) {
  if (bytes == null) return;
  try {
    bytes.fillRange(0, bytes.length, 0);
  } on UnsupportedError {
    // Some crypto backends expose an immutable view of their result.
  }
}
