import 'package:shared_preferences/shared_preferences.dart';

/// Decision 149: the box's FCM wake-up names no chat, so the closed app
/// cannot honour one chat's mute. It stays silent only while EVERY chat of
/// this install is muted. The main isolate, which can read the contact
/// store, leaves that one fact where the FCM background isolate can read it:
/// until when every chat is muted, and nothing about any single chat.

/// [allChatsMutedUntil] for mutes that never run out.
const String kWakeUpMutedForever = 'forever';

/// Until when every chat in [chats] is muted: [kWakeUpMutedForever], the
/// UTC ISO-8601 time the first mute runs out, or null when there is no chat
/// or one of them is not muted at [now].
String? allChatsMutedUntil(
  Iterable<({bool muted, DateTime? until})> chats,
  DateTime now,
) {
  DateTime? first;
  var any = false;
  for (final chat in chats) {
    any = true;
    if (!chat.muted) return null;
    final until = chat.until;
    if (until == null) continue;
    if (!until.isAfter(now)) return null;
    if (first == null || until.isBefore(first)) first = until;
  }
  if (!any) return null;
  return first?.toUtc().toIso8601String() ?? kWakeUpMutedForever;
}

/// Whether a wake-up arriving at [now] stays silent, given what
/// [allChatsMutedUntil] last stored. Anything unreadable is "not silent".
bool wakeUpIsSilenced(String? stored, DateTime now) {
  if (stored == null) return false;
  if (stored == kWakeUpMutedForever) return true;
  final until = DateTime.tryParse(stored);
  return until != null && until.isAfter(now);
}

/// Leaves [allChatsMutedUntil] for the wake-up handler.
typedef WakeUpMuteWriter = Future<void> Function(String? allMutedUntil);

const String _wakeUpMuteKey = 'wake_all_muted_v1';

/// The [WakeUpMuteWriter] of the app: SharedPreferences, readable by the FCM
/// background isolate, which holds no key of the sealed stores.
Future<void> writeWakeUpMute(String? allMutedUntil) async {
  final prefs = await SharedPreferences.getInstance();
  if (allMutedUntil == null) {
    await prefs.remove(_wakeUpMuteKey);
  } else {
    await prefs.setString(_wakeUpMuteKey, allMutedUntil);
  }
}

/// What [writeWakeUpMute] last stored, read from another isolate: its prefs
/// cache is its own, so reload first.
Future<String?> readWakeUpMuteFresh() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs.getString(_wakeUpMuteKey);
}
