import 'dart:typed_data';

import '../../utils/video_preview.dart' show kSendableVideoExtensions;

/// The most files one paperclip pick sends (owner, 2026-10-27). Every file is
/// its own upload and its own message, sent one after another.
const kMaxFilesPerPick = 10;

/// Image extensions the paperclip accepts; all of them stage-able types.
const kPickableImageExtensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];

/// Document extensions the paperclip accepts; they go out as FILE messages.
const kPickableDocumentExtensions = [
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'txt',
  'csv',
];

enum PickedAttachmentKind { image, video, document, unsupported }

/// One file from a paperclip picker, on its way to the composer.
///
/// The anchored-input doors and native file_picker read the bytes when the
/// file's turn to send comes; a web file_picker pick (desktop, iOS PWA) has
/// already read every file into RAM, so there [readBytes] only hands them over.
class PickedAttachment {
  const PickedAttachment({required this.name, required this.readBytes});

  final String name;

  /// Null when the platform could not read the file.
  final Future<Uint8List?> Function() readBytes;

  String get extension =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';

  /// Routing is by extension and EXPLICIT: anything outside the lists (e.g.
  /// an iOS HEIC the device did not transcode) is unsupported, never guessed.
  PickedAttachmentKind get kind {
    final ext = extension;
    if (kPickableImageExtensions.contains(ext)) {
      return PickedAttachmentKind.image;
    }
    if (kSendableVideoExtensions.contains(ext)) {
      return PickedAttachmentKind.video;
    }
    if (kPickableDocumentExtensions.contains(ext)) {
      return PickedAttachmentKind.document;
    }
    return PickedAttachmentKind.unsupported;
  }

  /// MIME type of an [PickedAttachmentKind.image] file.
  String get imageMimeType => switch (extension) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };

  /// MIME type of a [PickedAttachmentKind.document] file.
  String get documentMimeType => switch (extension) {
    'pdf' => 'application/pdf',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'txt' => 'text/plain',
    'csv' => 'text/csv',
    _ => 'application/octet-stream',
  };
}
