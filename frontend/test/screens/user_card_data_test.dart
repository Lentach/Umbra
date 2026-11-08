import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/screens/user_card_screen.dart';

void main() {
  // Parsed through the wire reader, so a malformed fixture fails loudly.
  final photo = ProfilePhotoRef.fromWire({
    'm': '${'A' * 42}E',
    'k': base64.encode(List.filled(32, 1)),
    'i': base64.encode(List.filled(12, 2)),
    'r': 3,
  })!;

  UserCardVisualData cardFor(
    Map<String, dynamic> payload, {
    ProfilePhotoRef? avatar,
  }) {
    return UserCardVisualData.fromUser(
      UserModel.fromJson(payload).copyWith(avatar: avatar),
      isSelf: false,
      hasConversation: true,
    );
  }

  Map<String, dynamic> alice({String? profilePictureUrl}) => {
    'id': 1,
    'username': 'alice',
    'tag': '0042',
    'profilePictureUrl': profilePictureUrl,
  };

  test('uses compact no-avatar state when a profile has no photo', () {
    final card = cardFor(alice());

    expect(card.handle, 'alice#0042');
    expect(card.avatar, isNull);
    expect(card.legacyPhotoUrl, isNull);
    expect(card.hasPhoto, isFalse);
  });

  test('carries the end-to-end photo reference as the card photo', () {
    final card = cardFor(alice(), avatar: photo);

    expect(card.avatar, photo);
    expect(card.hasPhoto, isTrue);
  });

  test('keeps the legacy server photo for an account without a reference', () {
    final card = cardFor(
      alice(profilePictureUrl: 'https://media.example/avatar.jpg'),
    );

    expect(card.avatar, isNull);
    expect(card.legacyPhotoUrl, 'https://media.example/avatar.jpg');
    expect(card.hasPhoto, isTrue);
  });

  test('a blank legacy photo path is no photo', () {
    final card = cardFor(alice(profilePictureUrl: '  '));

    expect(card.legacyPhotoUrl, isNull);
    expect(card.hasPhoto, isFalse);
  });

  test('a removed photo is no photo even while the legacy path lingers', () {
    final card = cardFor(
      alice(profilePictureUrl: 'https://media.example/old.jpg'),
      avatar: const ProfilePhotoRef.cleared(4),
    );

    expect(card.avatar?.isCleared, isTrue);
    expect(card.hasPhoto, isFalse);
  });

  test('converts expired and timed mutes into the correct visual state', () {
    final now = DateTime.utc(2026, 7, 13, 12);

    expect(
      UserCardMute.fromConversation(
        muted: true,
        mutedUntil: now.subtract(const Duration(seconds: 1)),
        now: now,
      ),
      UserCardMute.off,
    );
    expect(
      UserCardMute.fromConversation(
        muted: true,
        mutedUntil: now.add(const Duration(hours: 5)),
        now: now,
      ),
      UserCardMute.eightHours,
    );
    expect(
      UserCardMute.fromConversation(
        muted: true,
        mutedUntil: now.add(const Duration(hours: 1)),
        now: now,
      ),
      UserCardMute.oneHour,
    );
    expect(
      UserCardMute.fromConversation(
        muted: true,
        mutedUntil: now.add(const Duration(days: 3)),
        now: now,
      ),
      UserCardMute.oneWeek,
    );
    // Pin the boundaries: exactly 2h is still oneHour (<=),
    // exactly 12h is still eightHours (<=).
    expect(
      UserCardMute.fromConversation(
        muted: true,
        mutedUntil: now.add(const Duration(hours: 2)),
        now: now,
      ),
      UserCardMute.oneHour,
    );
    expect(
      UserCardMute.fromConversation(
        muted: true,
        mutedUntil: now.add(const Duration(hours: 12)),
        now: now,
      ),
      UserCardMute.eightHours,
    );
    expect(
      UserCardMute.fromConversation(muted: true, mutedUntil: null, now: now),
      UserCardMute.forever,
    );
  });
}
