/// Classification of native mic-capture failures (desktop cpal path) so the
/// UI can show a localized, actionable hint instead of raw WASAPI text.
enum MicErrorKind {
  /// Windows denied microphone access to the desktop app. Manifests as
  /// E_ACCESSDENIED at device activation, or AUDCLNT_E_DEVICE_IN_USE with
  /// no other app actually holding the device (the privacy gate reports
  /// both). Also covers the rare case of another app holding the mic
  /// exclusively — the hint tells the user to check both.
  privacy,

  /// Anything else — the raw error text is shown as-is.
  other,
}

/// Classifies the raw error text from `ts_get_last_audio_error`. cpal renders
/// backend errors as "<OS message> (0x<HRESULT>)", so match the hex codes
/// (windows-rs formats them lowercase / uppercase depending on version) plus
/// common OS phrasings for robustness across Windows locales.
MicErrorKind classifyMicError(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('0x80070005') || // E_ACCESSDENIED
      lower.contains('access is denied') ||
      lower.contains('access denied') ||
      lower.contains('0x8889000a') || // AUDCLNT_E_DEVICE_IN_USE
      lower.contains('audclnt_e_device_in_use') ||
      lower.contains('device in use')) {
    return MicErrorKind.privacy;
  }
  return MicErrorKind.other;
}
