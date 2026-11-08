import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/models/user_model.dart';

void main() {
  group('UserModel', () {
    test('fromJson parses user', () {
      final json = {
        'id': 1,
        'username': 'testuser',
        'tag': '0427',
      };
      final user = UserModel.fromJson(json);
      expect(user.id, 1);
      expect(user.username, 'testuser');
      expect(user.tag, '0427');
      expect(user.profilePictureUrl, isNull);
      expect(user.displayHandle, 'testuser#0427');
    });

    test('fromJson parses full user', () {
      final json = {
        'id': 2,
        'username': 'testuser',
        'tag': '1234',
        'profilePictureUrl': 'https://example.com/avatar.png',
      };
      final user = UserModel.fromJson(json);
      expect(user.id, 2);
      expect(user.username, 'testuser');
      expect(user.tag, '1234');
      expect(user.profilePictureUrl, 'https://example.com/avatar.png');
    });

    test('copyWith preserves unchanged fields', () {
      final user = UserModel(id: 1, username: 'old', tag: '0001');
      final updated = user.copyWith(username: 'new');
      expect(updated.id, 1);
      expect(updated.username, 'new');
      expect(updated.tag, '0001');
    });

    test('copyWith clear flags null out fields and win over passed values', () {
      final user = UserModel(
        id: 1,
        username: 'old',
        tag: '0001',
        profilePictureUrl: 'https://example.com/avatar.png',
        about: 'hello world',
      );

      final avatarCleared = user.copyWith(clearProfilePicture: true);
      expect(avatarCleared.profilePictureUrl, isNull);
      expect(avatarCleared.about, 'hello world');

      final aboutCleared = user.copyWith(clearAbout: true);
      expect(aboutCleared.about, isNull);
      expect(aboutCleared.profilePictureUrl, 'https://example.com/avatar.png');

      // Clear flags must win even when a replacement value is also passed.
      final both = user.copyWith(
        profilePictureUrl: 'https://example.com/new.png',
        clearProfilePicture: true,
        about: 'new about',
        clearAbout: true,
      );
      expect(both.profilePictureUrl, isNull);
      expect(both.about, isNull);
    });

    test('fromJson defaults tag to 0000 when absent', () {
      final user = UserModel.fromJson({
        'id': 3,
        'username': 'notag',
      });
      expect(user.tag, '0000');
      expect(user.displayHandle, 'notag#0000');
    });

    test(
      'fromJson reads about and the legacy photo path, and never takes an '
      'end-to-end avatar or a photo list from the server (decision 138)',
      () {
        final user = UserModel.fromJson({
          'id': 4,
          'username': 'photos',
          'tag': '9999',
          'about': 'bio text',
          'profilePictureUrl': '/media/avatars/a.jpg',
          'avatar': {'r': 1, 'x': 1},
          'profilePhotos': [
            {'id': 11, 'url': 'https://example.com/p1.png'},
          ],
        });
        expect(user.about, 'bio text');
        expect(user.profilePictureUrl, '/media/avatars/a.jpg');
        expect(user.avatar, isNull);
      },
    );
  });
}
