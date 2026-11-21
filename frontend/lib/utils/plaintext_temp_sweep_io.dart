import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'video_temp_file_io.dart' show transcodeOutputPrefix, videoTempPrefix;

/// light_compressor_v2's audio spill for a transcode
/// (`File.createTempFile("lc_audio_", ".tmp", cacheDir)`).
const String _transcodeAudioPrefix = 'lc_audio_';

/// file_picker (Android) copies every picked file into
/// `cacheDir/file_picker/<ms>/<name>` and never deletes it.
const String _filePickerDir = 'file_picker';

/// `RecordingController` records a voice note to `tempDir/voice_<ms>.m4a`.
/// A failed send keeps it for the in-session 'Ponów', which re-reads it; no
/// stored row survives a restart with a local path (decision 104 keeps a
/// send only once its attachment is on the box), so at launch it is orphaned.
final RegExp _voiceRecording = RegExp(r'^voice_\d+\.m4a$');

/// image_picker (Android) copies a gallery pick into
/// `cacheDir/<random UUID>/<name>`.
final RegExp _imagePickerDir = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// image_picker (Android) writes a camera capture to
/// `cacheDir/<random UUID><digits>.jpg` (photo) or `.mp4` (video)
/// (`File.createTempFile`).
final RegExp _imagePickerCapture = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\d+\.(jpg|mp4)$',
);

/// Deletes the plaintext media copies the app leaves outside its sealed
/// stores (hardening A5): decrypted video and transcoder files a killed
/// process did not get to delete, and the pickers' copies of every file the
/// user picked. Run once at launch, after `runApp`; never throws.
///
/// Also swept: `voice_*.m4a`, a recording whose send failed in an earlier
/// process — its retry lived only in that process's memory.
Future<void> sweepStalePlaintextTempFiles() async {
  final before = DateTime.now();
  try {
    await sweepPlaintextTempDirs(
      temp: await getTemporaryDirectory(),
      support: await getApplicationSupportDirectory(),
      before: before,
    );
  } on Object {
    // Nothing to sweep this launch; the next one tries again.
  }
}

/// [sweepStalePlaintextTempFiles] over explicit directories. Only the names
/// above are touched, and only when everything in them was last modified
/// before [before]: anything newer belongs to a pick or a video opened after
/// the sweep began.
@visibleForTesting
Future<void> sweepPlaintextTempDirs({
  required Directory temp,
  required Directory support,
  required DateTime before,
}) async {
  Future<void> dropIfStale(FileSystemEntity entry) async {
    try {
      final files = <FileSystemEntity>[
        if (entry is Directory)
          ...entry.listSync(recursive: true).whereType<File>()
        else
          entry,
      ];
      final newest = files.isEmpty
          ? entry.statSync().modified
          : files
                .map((f) => f.statSync().modified)
                .reduce((a, b) => a.isAfter(b) ? a : b);
      if (!newest.isBefore(before)) return;
      await entry.delete(recursive: true);
    } on Object {
      // Gone already or busy: the next launch tries again.
    }
  }

  if (temp.existsSync()) {
    for (final entry in temp.listSync()) {
      final name = _nameOf(entry);
      if (entry is File &&
          (name.startsWith(videoTempPrefix) ||
              name.startsWith(_transcodeAudioPrefix) ||
              _voiceRecording.hasMatch(name) ||
              _imagePickerCapture.hasMatch(name))) {
        await dropIfStale(entry);
      } else if (entry is Directory && name == _filePickerDir) {
        for (final pick in entry.listSync()) {
          await dropIfStale(pick);
        }
      } else if (entry is Directory && _imagePickerDir.hasMatch(name)) {
        await dropIfStale(entry);
      }
    }
  }
  if (support.existsSync()) {
    for (final entry in support.listSync()) {
      if (entry is File && _nameOf(entry).startsWith(transcodeOutputPrefix)) {
        await dropIfStale(entry);
      }
    }
  }
}

String _nameOf(FileSystemEntity entry) =>
    entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
