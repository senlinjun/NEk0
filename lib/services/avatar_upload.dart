import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'ft_service.dart';
import 'ts_ffi.dart';

/// Why an avatar upload did not complete — mapped to localized snackbars.
enum AvatarUploadFailure { invalidImage, couldNotStart, transferFailed }

class AvatarUploadException implements Exception {
  const AvatarUploadException(this.cause, [this.reason]);
  final AvatarUploadFailure cause;

  /// Human-readable detail (e.g. the server's rejection text) shown after
  /// the localized prefix.
  final String? reason;

  @override
  String toString() => 'AvatarUploadException($cause, $reason)';
}

/// Uploads the user's own avatar to the server.
///
/// TeamSpeak stores an avatar as `/avatar_<uid>` in the channel-0 file
/// storage; other clients only see it once the uploader announces the file's
/// MD5 (clientupdate `client_flag_avatar`) — the Rust side does that
/// automatically once the transfer is confirmed, so a finished upload needs
/// no further handling: the server broadcasts the new hash and the regular
/// avatar cache refresh picks it up.
class AvatarUploadService {
  /// Server default avatar size cap in bytes (see AvatarCache). The
  /// re-encode loop targets this so a default-configured server accepts the
  /// upload; a server with a higher cap just gets a smaller avatar than it
  /// could have.
  static const _maxBytes = 8192;

  /// Compresses `bytes` under the size cap and uploads it as our avatar.
  /// Throws [AvatarUploadException] with a UI-presentable cause.
  static Future<void> upload(Uint8List bytes, String uid) async {
    final encoded = _encodeWithinCap(bytes);
    if (encoded == null) {
      throw const AvatarUploadException(AvatarUploadFailure.invalidImage);
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/nek0_avatar_upload.img';
    final file = File(path);
    await file.writeAsBytes(encoded, flush: true);
    final taskId = TsNative.uploadAvatar(uid, path);
    if (taskId == 0) {
      throw const AvatarUploadException(AvatarUploadFailure.couldNotStart);
    }
    try {
      await FtTransferService.instance.trackHiddenTask(
        taskId,
        'avatar',
        timeout: const Duration(seconds: 30),
      );
    } catch (e) {
      throw AvatarUploadException(
        AvatarUploadFailure.transferFailed,
        e is TransferException ? e.reason : e.toString(),
      );
    }
  }

  /// Decodes any supported image and re-encodes it within the size cap:
  /// already-small files pass through untouched, otherwise PNG at
  /// decreasing sizes first (keeps transparency), JPEG as the fallback for
  /// photos too noisy for a small PNG. Returns null when the bytes are not
  /// a decodable image.
  static Uint8List? _encodeWithinCap(Uint8List bytes) {
    if (bytes.lengthInBytes <= _maxBytes) {
      return bytes;
    }
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    for (final dim in const [256, 192, 128, 96, 72, 48]) {
      final png = img.encodePng(_fit(image, dim));
      if (png.lengthInBytes <= _maxBytes) {
        return png;
      }
    }
    // PNG never fits (noisy photo) — JPEG has no transparency to keep
    // anyway, and compresses photographs far better.
    for (final dim in const [96, 64]) {
      final resized = _fit(image, dim);
      for (final quality in const [85, 70, 55]) {
        final jpg = img.encodeJpg(resized, quality: quality);
        if (jpg.lengthInBytes <= _maxBytes) {
          return jpg;
        }
      }
    }
    // Smallest fallback is still over the cap — upload it anyway and let
    // the server's rejection (surfaced through the transfer error) explain
    // itself instead of guessing a limit here.
    return img.encodeJpg(_fit(image, 64), quality: 55);
  }

  /// Resizes so the longer edge is `dim`, keeping the aspect ratio. Images
  /// already smaller than `dim` are returned as-is (never upscaled).
  static img.Image _fit(img.Image image, int dim) {
    final w = image.width;
    final h = image.height;
    if (w <= dim && h <= dim) return image;
    final scale = dim / (w > h ? w : h);
    return img.copyResize(
      image,
      width: (w * scale).round().clamp(1, dim),
      height: (h * scale).round().clamp(1, dim),
      interpolation: img.Interpolation.average,
    );
  }
}
