import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

/// Forgets the emoji the picker lists under "recent".
///
/// `emoji_picker_flutter` keeps them device-wide in SharedPreferences (key
/// `recent`; `localStorage` on web) and a reaction pick adds to them too, so
/// without this the next account on the device would see the previous user's
/// choices. Called when a session ends and wipes the store. Best effort: a
/// failed wipe must not stop the logout.
Future<void> clearRecentEmoji() async {
  try {
    await EmojiPickerUtils().clearRecentEmojis(
      key: GlobalKey<EmojiPickerState>(),
    );
  } on Object catch (e) {
    debugPrint('Clearing the recent emoji failed: $e');
  }
}
