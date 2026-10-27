import 'dart:ui' show Rect;

import 'web_file_input.dart' show WebPickedFile;

bool get webAnchoredFileInputSupported => false;

Future<List<WebPickedFile>?> pickFilesViaAnchoredInput({
  required Rect anchorRect,
  required String accept,
  String? capture,
  bool multiple = false,
}) async => null;
