import 'profile_photo.dart';

class UserModel {
  final int id;
  final String username;
  final String tag;

  /// The server photo path a pre-decision-138 account still has: read for
  /// release A only (the own migration source, an older friend's `a`), shown
  /// only while [avatar] names nothing. Removed in release B.
  final String? profilePictureUrl;

  /// The end-to-end photo reference (decision 138) — the photo this account
  /// itself sent, never the server's word. When set it decides what shows,
  /// a cleared one included: a removed photo is initials, never the legacy
  /// URL behind it.
  final ProfilePhotoRef? avatar;
  final String? about;

  UserModel({
    required this.id,
    required this.username,
    required this.tag,
    this.profilePictureUrl,
    this.avatar,
    this.about,
  });

  String get displayHandle => '$username#$tag';

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] as int,
      username: json['username'] as String,
      tag: json['tag'] as String? ?? '0000',
      profilePictureUrl: json['profilePictureUrl'] as String?,
      about: json['about'] as String?,
    );
  }

  UserModel copyWith({
    int? id,
    String? username,
    String? tag,
    String? profilePictureUrl,
    bool clearProfilePicture = false,
    ProfilePhotoRef? avatar,
    bool clearAvatar = false,
    String? about,
    bool clearAbout = false,
  }) {
    return UserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      tag: tag ?? this.tag,
      profilePictureUrl: clearProfilePicture
          ? null
          : profilePictureUrl ?? this.profilePictureUrl,
      avatar: clearAvatar ? null : avatar ?? this.avatar,
      about: clearAbout ? null : about ?? this.about,
    );
  }
}
