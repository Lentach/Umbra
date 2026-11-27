import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/settings_screen.dart';
import 'package:fireplace/services/api_exception.dart';
import 'package:fireplace/services/box/box_first_contact.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/dialogs/delete_account_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart';
import '../support/passcode_fakes.dart';

/// Settings -> Delete account (decision 113): the password is checked, the
/// goodbyes go out, the server deletes, THEN the device wipes its keys and
/// closes the connection as a logout. A refused password does none of that.
class _Auth extends AuthProvider {
  /// Every call that reached the server-side delete flow.
  int deleteCalls = 0;

  /// Held open until the test completes it (a slow verify / goodbye / DELETE).
  Completer<void>? hold;

  /// What the flow throws once it gets going (a refused password).
  Exception? refuse;

  @override
  UserModel? get currentUser =>
      UserModel(id: 7, username: 'Marta', tag: '0007');

  @override
  String? get token => 'test-token';

  @override
  Future<bool> deleteAccount(
    String password, {
    Future<void> Function()? beforeDelete,
  }) async {
    deleteCalls++;
    // The real one runs the goodbyes after the password check, best effort.
    try {
      await beforeDelete?.call();
    } on Object {
      // Never holds the delete (E114i).
    }
    await hold?.future;
    if (refuse != null) throw refuse!;
    return true;
  }
}

/// Records the wipe, and the logout the connection runs on this provider
/// (`ConnectionProvider.disconnect(isLogout: true)` calls [clearAll]).
class _Encryption extends EncryptionProvider {
  int keyWipes = 0;
  int logoutResets = 0;

  /// While set, a friend's device list never comes: the goodbye is stuck
  /// (the box that never answers) and outlives its budget.
  Completer<void>? stuck;

  /// Called the moment the wipe has begun, before it finishes.
  Future<void> Function()? duringWipe;

  @override
  bool get isE2EReady => stuck != null || super.isE2EReady;

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await stuck?.future;
    throw StateError('the list never came');
  }

  @override
  Future<void> clearEncryptionKeys({int? userId}) async {
    keyWipes++;
    await duringWipe?.call();
  }

  @override
  void clearAll() {
    logoutResets++;
    super.clearAll();
  }
}

/// A friend the box covers: one goodbye to tell, then the queues to retire.
class _Outbox implements BoxOutbox {
  @override
  Iterable<int> coveredPeers() => const [5];

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) => const {
    1: ContactOutbound(peerDeviceId: 1, sid: 'sid', sealPub: 'pub', idk: null),
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What the account's queue retirement does when the work reaches it.
class _Link implements BoxFirstContactLink {
  _Link(this.encryption);

  final _Encryption encryption;

  /// The retirement started although the connection was not yet closed as a
  /// logout: it ran against the account whose keys were being wiped.
  bool retiredBeforeLogout = false;
  int retired = 0;

  @override
  Future<void> retireAccountQueues() async {
    retired++;
    if (encryption.logoutResets == 0) retiredBeforeLogout = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Auth auth;
  late _Encryption encryption;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    auth = _Auth();
    encryption = _Encryption();
  });

  Future<void> pump(WidgetTester tester, {_Link? link}) async {
    final connection = ConnectionProvider();
    final messaging = MessagingProvider();
    if (link != null) {
      messaging
        ..setEncryptionProvider(encryption)
        ..boxOutbox = _Outbox()
        ..boxFirstContact = link;
    }
    connection.setProviders(
      encryption: encryption,
      friends: FriendsProvider(),
      conversations: ConversationsProvider(),
      messaging: messaging,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider.value(value: connection),
          ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
          ChangeNotifierProvider.value(value: messaging),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(
            create: (_) => PasscodeProvider(
              store: MemoryPasscodeStore(),
              kdf: FakePasscodeKdf(),
            ),
          ),
        ],
        child: MaterialApp(
          theme: RpgTheme.themeDataLight,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapDeleteRow(WidgetTester tester) async {
    final row = find.text(l10n.deleteAccount);
    await tester.scrollUntilVisible(row, 200);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Future<void> submitPassword(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField), 'secret-pw');
    await tester.tap(find.text(l10n.delete));
    // The dialog's close animation; a held delete stays in flight.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a successful delete wipes the keys and logs the socket out', (
    tester,
  ) async {
    await pump(tester);
    await tapDeleteRow(tester);
    await submitPassword(tester);
    await tester.pumpAndSettle();

    expect(auth.deleteCalls, 1);
    expect(encryption.keyWipes, 1, reason: 'local keys must be wiped');
    expect(encryption.logoutResets, 1, reason: 'closed as a logout');
  });

  testWidgets('a refused password wipes nothing and keeps the session', (
    tester,
  ) async {
    auth.refuse = const ApiException(
      statusCode: 401,
      message: 'wrong password',
    );
    await pump(tester);
    await tapDeleteRow(tester);
    await submitPassword(tester);
    await tester.pumpAndSettle();

    // The refusal toast's own timer.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    expect(auth.deleteCalls, 1);
    expect(encryption.keyWipes, 0);
    expect(encryption.logoutResets, 0);
  });

  testWidgets('while a delete runs the row cannot start a second one', (
    tester,
  ) async {
    auth.hold = Completer<void>();
    await pump(tester);
    await tapDeleteRow(tester);
    await submitPassword(tester);
    expect(auth.deleteCalls, 1, reason: 'the first delete is under way');

    await tester.tap(find.text(l10n.deleteAccount));
    await tester.pumpAndSettle();
    expect(find.byType(DeleteAccountDialog), findsNothing);
    await tester.tap(find.text(l10n.deleteAccount), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(auth.deleteCalls, 1, reason: 'no second verify/goodbye/DELETE');
    auth.hold!.complete();
    await tester.pumpAndSettle();
    expect(encryption.keyWipes, 1);
  });

  // Mutation: wipe the keys before closing the connection as a logout.
  testWidgets(
    'a goodbye that outlives its budget cannot run on once the keys are wiped',
    (tester) async {
      final link = _Link(encryption);
      encryption.stuck = Completer<void>();
      await pump(tester, link: link);
      await tapDeleteRow(tester);
      await submitPassword(tester);
      expect(link.retired, 0, reason: 'the goodbye is stuck on the box');

      // The box answers while the wipe is still running.
      encryption.duringWipe = () async {
        encryption.stuck!.complete();
        for (var i = 0; i < 20; i++) {
          await Future<void>.value();
        }
      };

      // The 10 s budget runs out: the delete goes on, the goodbye work stays.
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();

      expect(encryption.keyWipes, 1);
      expect(
        link.retiredBeforeLogout,
        isFalse,
        reason: 'late goodbye work ran against the account being wiped',
      );
    },
  );
}
