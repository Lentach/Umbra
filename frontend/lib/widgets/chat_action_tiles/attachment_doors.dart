part of '../chat_action_tiles.dart';

/// The paperclip: the per-platform door sheets and pickers. Nothing here is
/// passed as a callback, so an extension is safe (a tear-off of an extension
/// method is a new closure each time).
extension _ChatActionAttachmentDoors on ChatActionTiles {
  static String _dotAccept(List<String> extensions) =>
      extensions.map((e) => '.$e').join(',');

  /// Paperclip door, per platform (owner rulings 2026-08-19/21/30):
  ///
  /// - iOS PWA: file_picker fallback (owner ruling 2026-08-30), several files
  ///   per pick since 2026-10-27. The anchored-input path was removed after a
  ///   9-variant on-device probe proved the opening mechanism is NOT what
  ///   causes the standalone orb/flash — the real app orbs identically on
  ///   both paths, and only in the installed standalone shell. Parked until
  ///   macOS Web Inspector can observe the presentation (PR #151 comment,
  ///   2026-08-30 session summary). The native-picker span still wraps the
  ///   fallback: the dismiss-slide gate and freeze-reload pick protection are
  ///   mechanism-independent wins.
  /// - Android PWA: Chrome's chooser for a mixed image+video accept lists the
  ///   camera twice (stills + camcorder; emulator s27 AND owner's real device
  ///   2026-08-30) and offers no gallery door, so the paperclip opens an
  ///   in-app glass sheet with three unambiguous doors: Gallery / Camera /
  ///   File (owner ruling 2026-08-19, re-confirmed wanted 2026-08-30).
  /// - Native Android: the same four-door sheet (owner 2026-11-20: the
  ///   system chooser offered only "take a photo" and "add a file", no way to
  ///   pick photos and videos from the gallery). Gallery is the Android photo
  ///   picker, Camera and Record video the camera apps, File the document
  ///   picker as before.
  /// - Desktop web, iOS: system picker via file_picker.
  ///
  /// Every door that can browse (all but the two capture doors) allows
  /// selecting several files; the composer sends them all immediately, in
  /// order, capped at [kMaxFilesPerPick].
  Future<void> _pickAttachment(
    BuildContext context,
    BuildContext tileContext,
  ) async {
    final active = _requireActiveConversation(context);
    if (active == null) return;
    final pickedIn = active.$1.id;

    if (kIsWeb &&
        webAnchoredFileInputSupported &&
        !isIOSWebKit() &&
        defaultTargetPlatform == TargetPlatform.android) {
      await _showAndroidAttachmentSheet(
        context,
        _tileAnchorRect(tileContext),
        pickedIn: pickedIn,
      );
      return;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _showNativeAndroidAttachmentSheet(context, pickedIn: pickedIn);
      return;
    }

    beginComposerNativePicker();
    final List<PickedAttachment>? picked;
    try {
      picked = await _pickWithFilePicker();
    } finally {
      endComposerNativePicker();
    }
    if (picked == null) return;
    await onPickedFiles?.call(picked, pickedIn: pickedIn);
  }

  /// The system file picker (images, videos, documents); null when nothing
  /// was picked.
  static Future<List<PickedAttachment>?> _pickWithFilePicker() async {
    final pickResult = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        ...kPickableImageExtensions,
        ...kSendableVideoExtensions,
        ...kPickableDocumentExtensions,
      ],
      allowMultiple: true,
      // Web has no path, so file_picker reads EVERY picked file into RAM
      // before it returns; native reads each file from its path when its
      // turn to send comes.
      withData: kIsWeb,
    );
    if (pickResult == null || pickResult.files.isEmpty) return null;
    return [
      for (final file in pickResult.files)
        PickedAttachment(name: file.name, readBytes: () => _readBytes(file)),
    ];
  }

  static Future<Uint8List?> _readBytes(PlatformFile file) async {
    if (file.bytes != null) return file.bytes;
    if (kIsWeb || file.path == null) return null;
    try {
      return Uint8List.fromList(await file_utils.readFileBytes(file.path!));
    } on Object {
      return null;
    }
  }

  static Rect _tileAnchorRect(BuildContext tileContext) {
    final box = tileContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      // Degenerate but rendered fallback: bottom-center of the screen, where
      // the composer lives — still a real anchor for Safari.
      final size = MediaQuery.sizeOf(tileContext);
      return Rect.fromCenter(
        center: Offset(size.width / 2, size.height - 100),
        width: 48,
        height: 48,
      );
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Android four-door sheet (web): Gallery / Camera / Record video / File.
  /// Each door opens the anchored input with a door-specific accept, so
  /// Chrome never shows its ambiguous camera/camcorder/media chooser.
  ///
  /// Video capture is its own door because Android has no single input that
  /// offers "photo or video": `image/*` + `capture` opens the camera in photo
  /// mode and `video/*` + `capture` opens the camcorder. iOS ignores `capture`
  /// and shows its own "Take Photo or Video" sheet, which is why iOS could
  /// record a video from the camera and Android could not (owner report
  /// 2026-09-05).
  Future<void> _showAndroidAttachmentSheet(
    BuildContext context,
    Rect anchor, {
    required int pickedIn,
  }) => _showAttachmentDoors(
    context,
    gallery: (sheet) => _openDoor(
      sheet,
      anchor,
      pickedIn: pickedIn,
      accept: 'image/*,video/*',
      multiple: true,
    ),
    camera: (sheet) => _openDoor(
      sheet,
      anchor,
      pickedIn: pickedIn,
      accept: 'image/*',
      capture: 'environment',
    ),
    recordVideo: (sheet) => _openDoor(
      sheet,
      anchor,
      pickedIn: pickedIn,
      accept: 'video/*',
      capture: 'environment',
    ),
    file: (sheet) => _openDoor(
      sheet,
      anchor,
      pickedIn: pickedIn,
      accept: _dotAccept(kPickableDocumentExtensions),
      multiple: true,
    ),
  );

  /// The same four doors in the native Android app: Gallery is the system
  /// photo picker (photos and videos, several at once) or, where Android has
  /// none, the device's gallery app; Camera and Record video hand off to the
  /// camera app, File is the system file picker.
  Future<void> _showNativeAndroidAttachmentSheet(
    BuildContext context, {
    required int pickedIn,
  }) => _showAttachmentDoors(
    context,
    gallery: (sheet) => _openNativeDoor(
      sheet,
      pickedIn: pickedIn,
      pick: _pickFromGallery,
    ),
    camera: (sheet) => _openNativeDoor(
      sheet,
      pickedIn: pickedIn,
      pick: () async =>
          _fromXFile(await ImagePicker().pickImage(source: ImageSource.camera)),
    ),
    recordVideo: (sheet) => _openNativeDoor(
      sheet,
      pickedIn: pickedIn,
      pick: () async =>
          _fromXFile(await ImagePicker().pickVideo(source: ImageSource.camera)),
    ),
    file: (sheet) => _openNativeDoor(
      sheet,
      pickedIn: pickedIn,
      pick: _pickWithFilePicker,
    ),
  );

  static const MethodChannel _galleryChannel = MethodChannel(
    'fireplace/gallery',
  );

  /// Android 13+ (or a backported picker): the system photo picker, a grid
  /// of the device's photos and videos. Older Android has none, and
  /// image_picker would open the document browser there, "a file picker, not
  /// a gallery" (owner 2026-11-21): the gallery app answers instead
  /// (`GalleryPicker.kt`), and the document browser only when the device has
  /// no gallery app at all.
  static Future<List<PickedAttachment>?> _pickFromGallery() async {
    final hasPhotoPicker =
        await _galleryChannel.invokeMethod<bool>(
          'systemPhotoPickerAvailable',
        ) ??
        false;
    if (!hasPhotoPicker) {
      final paths = await _galleryChannel.invokeListMethod<String>(
        'pickFromGalleryApp',
        // One past the cap: the composer then sends ten and says the rest
        // were dropped, and the gallery app's copies stop there.
        {'limit': kMaxFilesPerPick + 1},
      );
      if (paths != null) {
        return paths.isEmpty
            ? null
            : [
                for (final path in paths)
                  PickedAttachment(
                    name: path.split('/').last,
                    readBytes: () async {
                      try {
                        return Uint8List.fromList(
                          await file_utils.readFileBytes(path),
                        );
                      } on Object {
                        return null;
                      }
                    },
                  ),
              ];
      }
    }
    final platform = ImagePickerPlatform.instance;
    if (platform is ImagePickerAndroid) platform.useAndroidPhotoPicker = true;
    return _fromXFiles(
      await ImagePicker().pickMultipleMedia(limit: kMaxFilesPerPick),
    );
  }

  static List<PickedAttachment>? _fromXFile(XFile? file) =>
      file == null ? null : _fromXFiles([file]);

  static List<PickedAttachment>? _fromXFiles(List<XFile> files) => files.isEmpty
      ? null
      : [
          for (final file in files)
            PickedAttachment(name: file.name, readBytes: file.readAsBytes),
        ];

  Future<void> _showAttachmentDoors(
    BuildContext context, {
    required void Function(BuildContext sheet) gallery,
    required void Function(BuildContext sheet) camera,
    required void Function(BuildContext sheet) recordVideo,
    required void Function(BuildContext sheet) file,
  }) async {
    // The modal sheet route unfocuses the composer and drops the keyboard
    // before any door is tapped — that drop is not a user dismiss either.
    // Depth-counted: a door begins its own span synchronously BEFORE this
    // await resumes, so the flag never flickers between sheet and dialog.
    beginComposerNativePicker();
    final l10n = AppLocalizations.of(context);
    final glass = GlassTheme.of(context);
    try {
      await showGlassSheet<void>(
        context,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              _AttachmentDoorRow(
                key: const Key('attachment-door-gallery'),
                icon: Icons.photo_library_outlined,
                label: l10n.attachmentOptionGallery,
                color: glass.onGlassAccent,
                onTap: () => gallery(sheetContext),
              ),
              _AttachmentDoorRow(
                key: const Key('attachment-door-camera'),
                icon: Icons.photo_camera_outlined,
                label: l10n.attachmentOptionCamera,
                color: glass.onGlassAccent,
                onTap: () => camera(sheetContext),
              ),
              _AttachmentDoorRow(
                key: const Key('attachment-door-record-video'),
                icon: Icons.videocam_outlined,
                label: l10n.attachmentOptionRecordVideo,
                color: glass.onGlassAccent,
                onTap: () => recordVideo(sheetContext),
              ),
              _AttachmentDoorRow(
                key: const Key('attachment-door-file'),
                icon: Icons.folder_outlined,
                label: l10n.attachmentOptionFile,
                color: glass.onGlassAccent,
                onTap: () => file(sheetContext),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    } finally {
      endComposerNativePicker();
    }
  }

  /// Door tap: pop the sheet and open the input SYNCHRONOUSLY in the same
  /// gesture stack (a deferred click is silently blocked — 08-19 §3.5), then
  /// hand the files to the composer. Fire-and-forget by design: the row's
  /// onTap is sync.
  void _openDoor(
    BuildContext sheetContext,
    Rect anchor, {
    required int pickedIn,
    required String accept,
    String? capture,
    bool multiple = false,
  }) {
    beginComposerNativePicker();
    Navigator.of(sheetContext).pop();
    pickFilesViaAnchoredInput(
          anchorRect: anchor,
          accept: accept,
          capture: capture,
          multiple: multiple,
        )
        .then((picked) async {
          if (picked == null || picked.isEmpty) return;
          await onPickedFiles?.call([
            for (final file in picked)
              PickedAttachment(name: file.name, readBytes: file.readBytes),
          ], pickedIn: pickedIn);
        })
        .whenComplete(endComposerNativePicker)
        .ignore();
  }

  /// Native door tap: pop the sheet, run [pick] (a system picker or the
  /// camera app), then hand the files to the composer once the picker span
  /// is over, as the plain file_picker path does. A picker error (camera
  /// permission refused, no camera app) is a pick of nothing.
  void _openNativeDoor(
    BuildContext sheetContext, {
    required int pickedIn,
    required Future<List<PickedAttachment>?> Function() pick,
  }) {
    beginComposerNativePicker();
    Navigator.of(sheetContext).pop();
    Future<List<PickedAttachment>?> guarded() async {
      try {
        return await pick();
      } on Object catch (e) {
        debugPrint('[ChatActionTiles] native pick failed: $e');
        return null;
      } finally {
        endComposerNativePicker();
      }
    }

    guarded().then((picked) async {
      if (picked == null || picked.isEmpty) return;
      await onPickedFiles?.call(picked, pickedIn: pickedIn);
    }).ignore();
  }
}
