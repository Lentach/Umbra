import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/services/profile/profile_photo_cache.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/avatar_circle.dart';
import 'package:fireplace/widgets/hex_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../support/profile_photo_fakes.dart';

/// Which photo an avatar shows (decision 138): a profile photo reference
/// decides ALONE — the decrypted file when this device holds it, else
/// initials, never the legacy server photo behind it; without a reference the
/// legacy path still shows; with neither, initials.
void main() {
  const legacyUrl = 'https://umbra.example/media/avatars/old.jpg';

  late TagMediaCrypto sender;
  late ProfilePhotoCache cache;

  // Decodable pixels, so a shown photo never takes the error path.
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));
  final png2 = Uint8List.fromList(
    img.encodePng(img.Image(width: 8, height: 8)..clear(img.ColorRgb8(1, 2, 3))),
  );

  ProfilePhotoRef ref(int n, {int rev = 1}) => ProfilePhotoRef(
    rev: rev,
    mediaId: mediaIdOf(n),
    key: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    iv: 'AAAAAAAAAAAAAAAA',
  );

  // A real, decodable JPEG: the photo a friend's file opens to.
  final jpeg = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 8, height: 8)),
  );

  setUp(() {
    sender = TagMediaCrypto();
    cache = ProfilePhotoCache(crypto: TagMediaCrypto());
    ProfilePhotoCache.shared = cache;
  });

  tearDown(() {
    cache.dispose();
    ProfilePhotoCache.shared = ProfilePhotoCache();
  });

  Widget wrap(Widget child) => MaterialApp(
    theme: RpgTheme.themeDataDarkGray,
    home: Scaffold(body: Center(child: child)),
  );

  Finder shownBytes(Uint8List bytes) => find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is MemoryImage &&
        (w.image as MemoryImage).bytes == bytes,
  );
  Finder anyMemoryImage() => find.byWidgetPredicate(
    (w) => w is Image && w.image is MemoryImage,
  );
  Finder networkImage([String? url]) => find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is NetworkImage &&
        (url == null || (w.image as NetworkImage).url == url),
  );

  // The same rule on both avatar widgets.
  final variants = <({
    String name,
    Widget Function(ProfilePhotoRef? avatar, String? url) build,
    Finder initials,
  })>[
    (
      name: 'HexAvatarSurface',
      build: (avatar, url) => SizedBox(
        width: 80,
        height: 80,
        child: HexAvatarSurface(
          imageUrl: url,
          avatar: avatar,
          initials: 'AL',
          surface: Colors.grey,
          initialsStyle: const TextStyle(fontSize: 20),
        ),
      ),
      initials: find.text('AL'),
    ),
    (
      name: 'AvatarCircle',
      build: (avatar, url) => AvatarCircle(
        displayName: 'alice',
        radius: 30,
        profilePictureUrl: url,
        avatar: avatar,
      ),
      initials: find.text('A'),
    ),
  ];

  for (final v in variants) {
    group(v.name, () {
      testWidgets('a held photo is shown from its decrypted bytes, and the '
          'legacy URL beside it is never fetched', (tester) async {
        final photo = ref(1);
        cache.putForTest(photo.mediaId!, png);

        await tester.pumpWidget(wrap(v.build(photo, legacyUrl)));

        expect(shownBytes(png), findsOneWidget);
        expect(v.initials, findsNothing);
        expect(networkImage(), findsNothing);
      });

      testWidgets('a photo this device does not hold is initials — not the '
          'legacy URL, not a spinner', (tester) async {
        await tester.pumpWidget(wrap(v.build(ref(1), legacyUrl)));

        expect(v.initials, findsOneWidget);
        expect(anyMemoryImage(), findsNothing);
        expect(networkImage(), findsNothing);
      });

      testWidgets('a removed photo (cleared reference) is initials, and the '
          'server photo behind it never comes back', (tester) async {
        await tester.pumpWidget(
          wrap(v.build(const ProfilePhotoRef.cleared(7), legacyUrl)),
        );

        expect(v.initials, findsOneWidget);
        expect(networkImage(), findsNothing);
        expect(anyMemoryImage(), findsNothing);
      });

      testWidgets('without a reference the legacy server photo still shows',
          (tester) async {
        await tester.pumpWidget(wrap(v.build(null, legacyUrl)));

        expect(networkImage(legacyUrl), findsOneWidget);
        expect(anyMemoryImage(), findsNothing);
      });

      testWidgets('with neither, initials', (tester) async {
        await tester.pumpWidget(wrap(v.build(null, null)));

        expect(v.initials, findsOneWidget);
        expect(networkImage(), findsNothing);
        expect(anyMemoryImage(), findsNothing);
      });

      testWidgets('a photo that lands later replaces the initials, and one '
          'that is forgotten goes back to them', (tester) async {
        final s = await sealPhoto(sender, jpeg, idFill: 3);
        await tester.pumpWidget(wrap(v.build(s.ref, legacyUrl)));
        expect(v.initials, findsOneWidget);
        expect(anyMemoryImage(), findsNothing);

        final held = await tester.runAsync(
          () => cache.ingest(s.ref, s.ciphertext),
        );
        expect(held, isTrue);
        await tester.pump();
        expect(anyMemoryImage(), findsOneWidget);
        expect(v.initials, findsNothing);
        expect(networkImage(), findsNothing);

        cache.forget(s.ref.mediaId);
        await tester.pump();
        expect(anyMemoryImage(), findsNothing);
        expect(v.initials, findsOneWidget);
      });

      testWidgets('a newer reference shows the newer photo', (tester) async {
        final first = ref(1);
        final second = ref(2, rev: 2);
        cache
          ..putForTest(first.mediaId!, png)
          ..putForTest(second.mediaId!, png2);

        await tester.pumpWidget(wrap(v.build(first, null)));
        expect(shownBytes(png), findsOneWidget);

        await tester.pumpWidget(wrap(v.build(second, null)));
        expect(shownBytes(png2), findsOneWidget);
        expect(shownBytes(png), findsNothing);
      });

      testWidgets('a photo that is removed after being shown goes back to '
          'initials, not to the legacy URL', (tester) async {
        final first = ref(1);
        cache.putForTest(first.mediaId!, png);
        await tester.pumpWidget(wrap(v.build(first, legacyUrl)));
        expect(shownBytes(png), findsOneWidget);

        await tester.pumpWidget(
          wrap(v.build(const ProfilePhotoRef.cleared(2), legacyUrl)),
        );
        expect(v.initials, findsOneWidget);
        expect(anyMemoryImage(), findsNothing);
        expect(networkImage(), findsNothing);
      });

      testWidgets('bytes the platform cannot decode fall back to initials',
          (tester) async {
        final photo = ref(5);
        cache.putForTest(photo.mediaId!, fakeJpeg(5));

        await tester.pumpWidget(wrap(v.build(photo, legacyUrl)));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pump();

        expect(v.initials, findsOneWidget);
        expect(networkImage(), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('HexAvatarSurface: a blank legacy URL is initials',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        const SizedBox(
          width: 80,
          height: 80,
          child: HexAvatarSurface(
            imageUrl: '   ',
            initials: 'AL',
            surface: Colors.grey,
            initialsStyle: TextStyle(),
          ),
        ),
      ),
    );
    expect(find.text('AL'), findsOneWidget);
    expect(networkImage(), findsNothing);
  });

  testWidgets('AvatarCircle: the shown photo fills the circle of its radius',
      (tester) async {
    final photo = ref(1);
    cache.putForTest(photo.mediaId!, png);
    await tester.pumpWidget(
      wrap(AvatarCircle(displayName: 'alice', radius: 30, avatar: photo)),
    );

    final image = tester.widget<Image>(shownBytes(png));
    expect(image.width, 60);
    expect(image.height, 60);
    expect(
      find.ancestor(of: shownBytes(png), matching: find.byType(ClipOval)),
      findsOneWidget,
    );
  });
}
