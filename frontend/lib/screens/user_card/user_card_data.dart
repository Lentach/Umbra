import '../../models/profile_photo.dart';
import '../../models/user_model.dart';

class UserCardVisualData {
  final int? userId;
  final String username;
  final String tag;
  final String? about;
  final bool isSelf;
  final bool hasConversation;

  /// Conversation with this contact when one exists — feeds the shared-media
  /// section. Always null for self cards.
  final int? conversationId;

  /// The account's end-to-end photo reference. When set it decides alone:
  /// the decrypted file, else initials — never [legacyPhotoUrl] behind it.
  final ProfilePhotoRef? avatar;

  /// The server-side photo path of a pre-E2E account; shown only while
  /// [avatar] is null.
  final String? legacyPhotoUrl;

  final UserCardMute mute;

  factory UserCardVisualData.fromUser(
    UserModel user, {
    required bool isSelf,
    required bool hasConversation,
    int? conversationId,
    UserCardMute mute = UserCardMute.off,
  }) {
    final legacy = user.profilePictureUrl;
    return UserCardVisualData(
      userId: user.id,
      username: user.username,
      about: user.about,
      tag: user.tag,
      isSelf: isSelf,
      hasConversation: hasConversation,
      conversationId: conversationId,
      avatar: user.avatar,
      legacyPhotoUrl: legacy == null || legacy.trim().isEmpty ? null : legacy,
      mute: mute,
    );
  }

  const UserCardVisualData({
    this.userId,
    required this.username,
    required this.tag,
    this.about,
    required this.isSelf,
    required this.hasConversation,
    this.conversationId,
    this.avatar,
    this.legacyPhotoUrl,
    this.mute = UserCardMute.off,
  });

  String get handle => '$username#$tag';

  /// Whether the account has a photo at all (shown or not here yet): what
  /// the own card offers to change or remove.
  bool get hasPhoto =>
      avatar?.hasPhoto ?? (legacyPhotoUrl?.trim().isNotEmpty ?? false);
}

enum UserCardMute {
  off,
  oneHour,
  eightHours,
  oneWeek,
  forever;

  static UserCardMute fromConversation({
    required bool muted,
    required DateTime? mutedUntil,
    DateTime? now,
  }) {
    if (!muted) return UserCardMute.off;
    if (mutedUntil == null) return UserCardMute.forever;
    final remaining = mutedUntil.difference(now ?? DateTime.now());
    if (remaining <= Duration.zero) return UserCardMute.off;
    if (remaining <= const Duration(hours: 2)) return UserCardMute.oneHour;
    if (remaining <= const Duration(hours: 12)) return UserCardMute.eightHours;
    return UserCardMute.oneWeek;
  }
}
