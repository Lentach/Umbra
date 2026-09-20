import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/screens/storage_loss_screen.dart';
import 'package:fireplace/services/backup/history_backup.dart';
import 'package:fireplace/services/backup/history_backup_service.dart';
import 'package:fireplace/services/backup/storage_loss.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The storage-loss screen is the ONE surface whose job is to end the boot
/// latch, and to end it only on an outcome that justifies ending it. These
/// tests drive the two exits and the two failures that must not.
void main() {
  const userId = 7;

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(StorageLoss.resetForTest);

  Future<void> pumpScreen(
    WidgetTester tester, {
    required HistoryBackupService service,
  }) async {
    StorageLoss.record('test');
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: StorageLossScreen(
          userId: userId,
          onDismiss: () {},
          service: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drives restore all the way through the passphrase dialog, which is the
  /// only path that reaches the service.
  Future<void> restoreWith(WidgetTester tester, String passphrase) async {
    await tester.tap(find.byKey(const Key('storage-loss-restore')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, passphrase);
    await tester.tap(
      find.widgetWithText(FilledButton, l10n.backupPassphraseEnterAction),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('continuing without a restore acknowledges the latch', (
    tester,
  ) async {
    await pumpScreen(tester, service: _FakeBackupService.succeeding());
    expect(StorageLoss.lostThisBoot, isTrue);

    await tester.tap(find.byKey(const Key('storage-loss-continue')));
    await tester.pumpAndSettle();

    expect(StorageLoss.lostThisBoot, isFalse);
  });

  testWidgets('a successful restore acknowledges the latch', (tester) async {
    final service = _FakeBackupService.succeeding();
    await pumpScreen(tester, service: service);

    await restoreWith(tester, 'correct horse battery');

    expect(service.attempts, ['correct horse battery']);
    expect(StorageLoss.lostThisBoot, isFalse);
    // Success is the only path that raises a toast; let its self-dismiss
    // timer run out so the tree tears down clean.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a wrong passphrase leaves the latch standing and never '
      'blames the file', (tester) async {
    await pumpScreen(
      tester,
      service: _FakeBackupService.failing(HistoryBackupWrongPassphrase()),
    );

    await restoreWith(tester, 'not the one');

    expect(StorageLoss.lostThisBoot, isTrue);
    expect(find.text(l10n.snackbarHistoryBackupWrongPassphrase), findsOne);
    expect(find.text(l10n.snackbarHistoryBackupCorrupt), findsNothing);
  });

  testWidgets('a corrupt file never blames the passphrase', (tester) async {
    await pumpScreen(
      tester,
      service: _FakeBackupService.failing(HistoryBackupCorrupt('bad magic')),
    );

    await restoreWith(tester, 'correct horse battery');

    expect(StorageLoss.lostThisBoot, isTrue);
    expect(find.text(l10n.snackbarHistoryBackupCorrupt), findsOne);
    expect(find.text(l10n.snackbarHistoryBackupWrongPassphrase), findsNothing);
  });
}

/// Stands in for the real service so the screen's decision logic is what is
/// under test, not the codec. `open` never runs: every override answers
/// before the store is touched.
class _FakeBackupService extends HistoryBackupService {
  _FakeBackupService._(this._failure)
    : super(open: () => throw UnimplementedError('store never opened'));

  factory _FakeBackupService.succeeding() => _FakeBackupService._(null);

  factory _FakeBackupService.failing(Exception failure) =>
      _FakeBackupService._(failure);

  final Exception? _failure;

  /// Passphrases the screen actually handed over, so a test can prove the
  /// dialog's value reached the service rather than an empty string.
  final List<String> attempts = [];

  @override
  Future<HistoryBackupCounts> pickAndImport({
    required int userId,
    required String passphrase,
  }) async {
    attempts.add(passphrase);
    final failure = _failure;
    if (failure != null) throw failure;
    return (records: 12, contacts: 4);
  }
}
