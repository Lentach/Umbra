import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/screens/edit_about_screen.dart';
import 'package:fireplace/screens/user_card_photo_actions.dart';
import 'package:fireplace/screens/user_card_screen.dart';
import 'package:fireplace/services/profile/profile_photo_cache.dart';
import 'package:fireplace/services/profile/profile_photos.dart'
    show ProfilePhotoOutcome;
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AuthProvider fake: applies profile mutations in memory so the card's
/// live-data path (self cards watch the provider) can be exercised without
/// network. The rework's contract under test: actions apply IN PLACE and the
/// card never pops itself.
class _FakeAuthProvider extends AuthProvider {
  UserModel? _user;

  _FakeAuthProvider(this._user);

  @override
  UserModel? get currentUser => _user;

  @override
  Future<void> updateProfileAbout(String? about) async {
    _user = _user!.copyWith(about: about, clearAbout: about == null);
    notifyListeners();
  }

  /// What the real flow does once a photo change is published: the own
  /// reference moves on.
  void setAvatar(ProfilePhotoRef ref) {
    _user = _user!.copyWith(avatar: ref);
    notifyListeners();
  }
}

/// The own-photo seam: records what the card asked for and answers with the
/// configured outcome, moving the fake account's reference on `done` like
/// the messaging provider does.
class _FakePhotoActions implements ProfilePhotoActions {
  _FakePhotoActions(this._auth);

  final _FakeAuthProvider _auth;

  /// What the picker returns; null is the user backing out.
  Uint8List? picked = Uint8List.fromList(const [9, 8, 7, 6]);
  ProfilePhotoOutcome setOutcome = ProfilePhotoOutcome.done;
  ProfilePhotoOutcome removeOutcome = ProfilePhotoOutcome.done;
  Error? setThrows;

  final List<Uint8List> setCalls = [];
  int removeCalls = 0;
  int _rev = 10;

  @override
  Future<Uint8List?> pick() async => picked;

  @override
  Future<ProfilePhotoOutcome> set(Uint8List pickedImageBytes) async {
    setCalls.add(pickedImageBytes);
    final thrown = setThrows;
    if (thrown != null) throw thrown;
    if (setOutcome == ProfilePhotoOutcome.done) {
      _auth.setAvatar(_photo(rev: ++_rev, lastChar: 'I'));
    }
    return setOutcome;
  }

  @override
  Future<ProfilePhotoOutcome> remove() async {
    removeCalls++;
    if (removeOutcome == ProfilePhotoOutcome.done) {
      _auth.setAvatar(ProfilePhotoRef.cleared(++_rev));
    }
    return removeOutcome;
  }
}

/// A reference [ProfilePhotoRef.fromWire] accepts (parsed through it, so a
/// malformed fixture fails loudly). [lastChar] tells two photos apart: one of
/// the base64url characters a 32-byte id may end in.
ProfilePhotoRef _photo({int rev = 1, String lastChar = 'A'}) =>
    ProfilePhotoRef.fromWire({
      'm': '${'A' * 42}$lastChar',
      'k': base64.encode(List.filled(32, 1)),
      'i': base64.encode(List.filled(12, 2)),
      'r': rev,
    })!;

/// Stand-in for the decrypted photo the cache would hold: a real 1x1 image,
/// so the hero shows it rather than falling back to initials (bytes that do
/// not decode are, rightly, no photo). Decoding never finishes inside a
/// widget test's fake clock, so the hero stays on its default height.
final Uint8List _photoBytes = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Widget _wrap(
  UserCardVisualData data, {
  AuthProvider? auth,
  ProfilePhotoActions? photoActions,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => auth ?? _FakeAuthProvider(null),
      ),
      ChangeNotifierProvider(create: (_) => FriendsProvider()),
    ],
    child: MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: UserCardScreen(
        data: data,
        onMessage: () {},
        photoActions: photoActions,
      ),
    ),
  );
}

UserModel _selfUser({
  String? about,
  ProfilePhotoRef? avatar,
  String? legacyUrl,
}) {
  return UserModel(
    id: 1,
    username: 'ember',
    tag: '7004',
    about: about,
    avatar: avatar,
    profilePictureUrl: legacyUrl,
  );
}

UserCardVisualData _selfCard(_FakeAuthProvider auth) =>
    UserCardVisualData.fromUser(
      auth.currentUser!,
      isSelf: true,
      hasConversation: false,
    );

UserCardVisualData _otherCard({
  ProfilePhotoRef? avatar,
  String? legacyPhotoUrl,
}) => UserCardVisualData(
  userId: 2,
  username: 'alice',
  tag: '0042',
  isSelf: false,
  hasConversation: false,
  avatar: avatar,
  legacyPhotoUrl: legacyPhotoUrl,
);

/// The images inside the collapsing hero (the ambient backdrop is not).
Finder _heroImages() => find.descendant(
  of: find.byType(SliverPersistentHeader),
  matching: find.byType(Image),
);

/// Every image of the card, hero and backdrop, whose source is a legacy
/// server URL.
Finder _networkImages() => find.byWidgetPredicate(
  (widget) => widget is Image && widget.image is NetworkImage,
);

/// Scrolls the card's body (below the hero) into view.
Future<void> _scrollToBody(WidgetTester tester) async {
  await tester.dragFrom(
    tester.getCenter(find.byType(CustomScrollView)),
    const Offset(0, -400),
  );
  await tester.pumpAndSettle();
}

const _unreadableMessage = "Couldn't read that photo. Pick another one.";
const _noRouteMessage = "The connection isn't ready yet. Try again in a moment.";
const _failedMessage = "Couldn't update your photo. Try again.";

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProfilePhotoCache.shared = ProfilePhotoCache();
  });

  const contact = UserCardVisualData(
    userId: 2,
    username: 'alice',
    tag: '0042',
    isSelf: false,
    hasConversation: false,
  );

  testWidgets('requires confirmation before removing or blocking a contact', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(contact));

    await tester.tap(find.text('Remove contact'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Friend?'), findsOneWidget);
    expect(
      find.text(
        'Remove alice from your contacts? This will delete all conversation history.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Friend?'), findsNothing);

    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    expect(find.text('Block alice#0042?'), findsOneWidget);
    expect(
      find.text('You will no longer be able to message this contact.'),
      findsOneWidget,
    );
  });

  group("the card shows the account's one profile photo", () {
    testWidgets("a contact's decrypted photo fills the hero", (tester) async {
      final photo = _photo();
      ProfilePhotoCache.shared.putForTest(photo.mediaId!, _photoBytes);
      await tester.pumpWidget(
        _wrap(
          _otherCard(
            avatar: photo,
            legacyPhotoUrl: 'https://example.test/old.jpg',
          ),
        ),
      );
      await tester.pump();

      final image = tester.widget<Image>(_heroImages());
      expect(
        image.image,
        isA<MemoryImage>().having((m) => m.bytes, 'bytes', _photoBytes),
      );
      expect(image.fit, BoxFit.cover);
      // The decrypted photo decides alone: the legacy URL is never fetched.
      expect(_networkImages(), findsNothing);
      expect(find.text('A'), findsNothing, reason: 'no initials placeholder');
    });

    testWidgets('the photo appears once its file lands on the device', (
      tester,
    ) async {
      final photo = _photo();
      await tester.pumpWidget(_wrap(_otherCard(avatar: photo)));
      await tester.pump();
      expect(_heroImages(), findsNothing);
      expect(find.text('A'), findsOneWidget);

      ProfilePhotoCache.shared.putForTest(photo.mediaId!, _photoBytes);
      await tester.pump();

      expect(
        tester.widget<Image>(_heroImages()).image,
        isA<MemoryImage>().having((m) => m.bytes, 'bytes', _photoBytes),
      );
    });

    testWidgets(
      'a removed photo shows initials and never brings back the legacy photo',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            _otherCard(
              avatar: const ProfilePhotoRef.cleared(4),
              legacyPhotoUrl: 'https://example.test/old.jpg',
            ),
          ),
        );
        await tester.pump();

        expect(_heroImages(), findsNothing);
        expect(_networkImages(), findsNothing);
        expect(find.text('A'), findsOneWidget);
      },
    );

    testWidgets(
      'a photo whose file is not on this device shows initials, not the '
      'legacy photo',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            _otherCard(
              avatar: _photo(),
              legacyPhotoUrl: 'https://example.test/old.jpg',
            ),
          ),
        );
        await tester.pump();

        expect(_heroImages(), findsNothing);
        expect(_networkImages(), findsNothing);
        expect(find.text('A'), findsOneWidget);
      },
    );

    testWidgets('an account without a reference shows its legacy photo', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(_otherCard(legacyPhotoUrl: 'https://example.test/old.jpg')),
      );
      await tester.pump();

      final image = tester.widget<Image>(_heroImages());
      expect(
        image.image,
        isA<NetworkImage>().having(
          (n) => n.url,
          'url',
          'https://example.test/old.jpg',
        ),
      );
      expect(image.fit, BoxFit.cover);
    });

    testWidgets('no photo anywhere shows the initials placeholder', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_otherCard()));
      await tester.pump();

      expect(_heroImages(), findsNothing);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets(
      'hero renders a single full-bleed cover image (round 3: no contain '
      'layer, no blurred backdrop) and collapse fades the bar title in',
      (tester) async {
        // Shrink the viewport so the body provides >= 232px of scroll
        // extent (default photoExtent 300 - barHeight 68; test images never
        // resolve, so the adaptive extent stays at the 300 default);
        // otherwise jumpTo clamps to a partial collapse and morphT never
        // reaches 1.
        tester.view.physicalSize = const Size(800, 400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final photo = _photo();
        ProfilePhotoCache.shared.putForTest(photo.mediaId!, _photoBytes);
        final auth = _FakeAuthProvider(
          // About adds body height so the sliver really reaches full
          // collapse in the shrunken viewport.
          _selfUser(
            about: 'sits by the fire and keeps the embers warm',
            avatar: photo,
          ),
        );
        await tester.pumpWidget(_wrap(_selfCard(auth), auth: auth));
        await tester.pump();

        // The bar title is the fontSize-16 copy of the handle; the hero
        // identity block shows a 12.5px copy while expanded.
        bool barTitleShown() => tester
            .widgetList<Text>(find.text('ember#7004'))
            .any((text) => text.style?.fontSize == 16);

        // Expanded: ONE cover image (the hero box tracks the photo's aspect,
        // so cover means full-bleed AND uncropped — the rejected round-2
        // contain/blur-backdrop pair must stay gone), no bar title yet.
        expect(_heroImages(), findsOneWidget);
        expect(tester.widget<Image>(_heroImages()).fit, BoxFit.cover);
        expect(barTitleShown(), isFalse);

        // Force full collapse (photoExtent 300 -> barHeight 68 = 232 plus
        // margin) directly on the scroll position.
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        position.jumpTo(300);
        await tester.pumpAndSettle();

        // Collapsed: same single cover layer, bar title faded in.
        expect(_heroImages(), findsOneWidget);
        expect(tester.widget<Image>(_heroImages()).fit, BoxFit.cover);
        expect(barTitleShown(), isTrue);
      },
    );
  });

  group('self card stays in place (nav-bounce regression)', () {
    testWidgets('saving About returns to the card and applies live', (
      tester,
    ) async {
      final auth = _FakeAuthProvider(_selfUser(about: 'old about'));
      await tester.pumpWidget(
        _wrap(
          UserCardVisualData.fromUser(
            auth.currentUser!,
            isSelf: true,
            hasConversation: false,
          ),
          auth: auth,
        ),
      );
      await tester.pump();

      await tester.dragFrom(
        tester.getCenter(find.byType(CustomScrollView)),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit About'));
      await tester.pumpAndSettle();
      expect(find.byType(EditAboutScreen), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'new about');
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      // ONE pop back to the card — never past it to the shell.
      expect(find.byType(EditAboutScreen), findsNothing);
      expect(find.byType(UserCardScreen), findsOneWidget);
      expect(find.text('new about'), findsOneWidget);
    });
  });

  group('own photo', () {
    Future<(_FakeAuthProvider, _FakePhotoActions)> pumpSelf(
      WidgetTester tester, {
      ProfilePhotoRef? avatar,
      String? legacyUrl,
    }) async {
      final auth = _FakeAuthProvider(
        _selfUser(avatar: avatar, legacyUrl: legacyUrl),
      );
      final actions = _FakePhotoActions(auth);
      await tester.pumpWidget(
        _wrap(_selfCard(auth), auth: auth, photoActions: actions),
      );
      await tester.pump();
      await _scrollToBody(tester);
      return (auth, actions);
    }

    testWidgets('without a photo the card offers only to set one', (
      tester,
    ) async {
      await pumpSelf(tester);

      expect(find.text('Set photo'), findsOneWidget);
      expect(find.text('Change photo'), findsNothing);
      expect(find.text('Remove photo'), findsNothing);
    });

    testWidgets('with a photo the card offers to change or remove it', (
      tester,
    ) async {
      // The file itself is not on this device (not in the cache): the
      // account still HAS a photo.
      await pumpSelf(tester, avatar: _photo());

      expect(find.text('Change photo'), findsOneWidget);
      expect(find.text('Remove photo'), findsOneWidget);
      expect(find.text('Set photo'), findsNothing);
    });

    testWidgets('a removed photo offers to set one again, not the legacy one', (
      tester,
    ) async {
      await pumpSelf(
        tester,
        avatar: const ProfilePhotoRef.cleared(4),
        legacyUrl: 'https://example.test/old.jpg',
      );

      expect(find.text('Set photo'), findsOneWidget);
      expect(find.text('Remove photo'), findsNothing);
    });

    testWidgets('a legacy-photo account can change or remove its photo', (
      tester,
    ) async {
      await pumpSelf(tester, legacyUrl: 'https://example.test/old.jpg');

      expect(find.text('Change photo'), findsOneWidget);
      expect(find.text('Remove photo'), findsOneWidget);
    });

    testWidgets(
      'a picked photo is handed over as picked and the card then offers to '
      'change it',
      (tester) async {
        final (auth, actions) = await pumpSelf(tester);

        await tester.tap(find.text('Set photo'));
        await tester.pumpAndSettle();

        expect(actions.setCalls, hasLength(1));
        expect(actions.setCalls.single, same(actions.picked));
        expect(auth.currentUser!.avatar?.hasPhoto, isTrue);
        // The card stays and re-derives from the account, silently.
        expect(find.byType(UserCardScreen), findsOneWidget);
        expect(find.text('Change photo'), findsOneWidget);
        expect(find.text('Set photo'), findsNothing);
        expect(find.text(_failedMessage), findsNothing);
      },
    );

    testWidgets('backing out of the picker changes nothing', (tester) async {
      final (_, actions) = await pumpSelf(tester);
      actions.picked = null;

      await tester.tap(find.text('Set photo'));
      await tester.pumpAndSettle();

      expect(actions.setCalls, isEmpty);
      expect(find.text('Set photo'), findsOneWidget);
    });

    for (final (outcome, message) in [
      (
        ProfilePhotoOutcome.unreadable,
        _unreadableMessage,
      ),
      (
        ProfilePhotoOutcome.noRoute,
        _noRouteMessage,
      ),
      (ProfilePhotoOutcome.refused, _failedMessage),
      (ProfilePhotoOutcome.failed, _failedMessage),
    ]) {
      testWidgets('a ${outcome.name} change says so and keeps the card as it '
          'was', (tester) async {
        final (_, actions) = await pumpSelf(tester);
        actions.setOutcome = outcome;

        await tester.tap(find.text('Set photo'));
        await tester.pumpAndSettle();

        expect(find.text(message), findsOneWidget);
        expect(find.text('Set photo'), findsOneWidget);
        expect(find.byType(UserCardScreen), findsOneWidget);
        // Let the toast's timer run out.
        await tester.pump(const Duration(seconds: 3));
      });
    }

    testWidgets('an error thrown while changing the photo is reported', (
      tester,
    ) async {
      final (_, actions) = await pumpSelf(tester);
      actions.setThrows = StateError('boom');

      await tester.tap(find.text('Set photo'));
      await tester.pumpAndSettle();

      expect(find.text(_failedMessage), findsOneWidget);
      expect(find.byType(UserCardScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('removing the photo asks first, then removes it', (
      tester,
    ) async {
      final (auth, actions) = await pumpSelf(tester, avatar: _photo());

      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();
      expect(find.text('Delete photo?'), findsOneWidget);
      expect(
        find.text('This permanently deletes this profile photo.'),
        findsOneWidget,
      );
      expect(actions.removeCalls, 0);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(actions.removeCalls, 0);
      expect(find.text('Remove photo'), findsOneWidget);

      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(actions.removeCalls, 1);
      expect(auth.currentUser!.avatar?.isCleared, isTrue);
      expect(find.byType(UserCardScreen), findsOneWidget);
      expect(find.text('Set photo'), findsOneWidget);
      expect(find.text('Remove photo'), findsNothing);
    });

    testWidgets('a failed removal says so and keeps the photo', (
      tester,
    ) async {
      final (_, actions) = await pumpSelf(tester, avatar: _photo());
      actions.removeOutcome = ProfilePhotoOutcome.failed;

      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text(_failedMessage), findsOneWidget);
      expect(find.text('Change photo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
