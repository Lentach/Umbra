import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/l10n/app_localizations_en.dart';
import 'package:fireplace/l10n/app_localizations_pl.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/widgets/recovery_phrase_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every answer the reset ceremony can give must reach the user (§6.2).
///
/// Three of the six refuse to start anything, and they are exactly the ones a
/// genuine owner recovering lost keys runs into: a mistyped phrase that still
/// passes the local BIP39 checksum, the lockout after five of those, and the
/// cooldown that follows a cancel. Silence there looks like a dead button
/// while the account stays unreachable.
///
/// The sixth starts a ceremony but withholds the shortcut (amendment (xlii)),
/// which is the one answer a user can mistake for a refusal.
void main() {
  final AppLocalizations en = AppLocalizationsEn();
  final AppLocalizations pl = AppLocalizationsPl();

  const answers = <String>[
    'pending',
    'existing',
    'cooldown',
    'invalid_phrase',
    'locked',
    'not_enrolled',
    'legacy_recovery_key',
    EncryptionProvider.identityResetPhraseTooNewStatus,
  ];

  test('every server answer produces a sentence, in both languages', () {
    for (final status in answers) {
      expect(
        identityResetAnswerMessage(en, status),
        isNotNull,
        reason: '$status has no English copy',
      );
      expect(
        identityResetAnswerMessage(pl, status),
        isNotNull,
        reason: '$status has no Polish copy',
      );
    }
  });

  test('the answers are distinguishable, not one generic line', () {
    final messages = answers
        .map((status) => identityResetAnswerMessage(en, status))
        .toSet();

    expect(messages.length, answers.length);
  });

  test('no answer at all is reported as such, never as success', () {
    expect(identityResetAnswerMessage(en, null), en.identityResetNoAnswer);
    expect(identityResetAnswerIsRefusal(null), isTrue);
  });

  test('refusals are marked as refusals so they can be styled as errors', () {
    expect(identityResetAnswerIsRefusal('cooldown'), isTrue);
    expect(identityResetAnswerIsRefusal('invalid_phrase'), isTrue);
    expect(identityResetAnswerIsRefusal('locked'), isTrue);
    expect(identityResetAnswerIsRefusal('not_enrolled'), isTrue);
    expect(identityResetAnswerIsRefusal('legacy_recovery_key'), isTrue);
    expect(identityResetAnswerIsRefusal('pending'), isFalse);
    expect(identityResetAnswerIsRefusal('existing'), isFalse);
  });

  test('a too-young phrase is not styled as a refusal — it DID start', () {
    // Red would say "rejected", and the user would retype a correct phrase
    // until the five-attempt lockout. A ceremony really is running.
    expect(
      identityResetAnswerIsRefusal(
        EncryptionProvider.identityResetPhraseTooNewStatus,
      ),
      isFalse,
    );
  });

  test('the too-young message says the phrase was right, and why it waits', () {
    for (final l10n in <AppLocalizations>[en, pl]) {
      final message = identityResetAnswerMessage(
        l10n,
        EncryptionProvider.identityResetPhraseTooNewStatus,
      );
      // Distinct from a plain start: that line is what the user got BEFORE
      // this amendment, and it is exactly what left them guessing.
      expect(message, isNot(l10n.identityResetStarted));
      // ...and distinct from a rejection, which is the wrong conclusion.
      expect(message, isNot(l10n.identityResetPhraseRejected));
      // The wait it explains is the full one, so the number has to appear
      // (6 h since (lxxxii) clause 1).
      expect(message, contains('6 h'));
    }
  });

  test('the cooldown message names the way out', () {
    // A password thief can loop start+cancel and hold the cooldown open; the
    // owner's escape is to change the password and evict them, so the message
    // has to say so rather than leaving them stuck.
    expect(en.identityResetCooldown.toLowerCase(), contains('password'));
    expect(pl.identityResetCooldown.toLowerCase(), contains('hasło'));
  });

  test('an unknown future status is a REFUSAL with a sentence, never silence',
      () {
    // A server newer than this client answers a status it has never seen
    // (this happened live with `not_enrolled` on 2026-09-05: every cached PWA
    // session during the deploy window was that client). Silence plus
    // not-a-refusal is the one combination the pending banner must never
    // produce — nothing started, and the user is left believing otherwise.
    expect(identityResetAnswerIsRefusal('something_new'), isTrue);
    expect(
      identityResetAnswerMessage(en, 'something_new'),
      en.identityResetNoAnswer,
    );
    expect(
      identityResetAnswerMessage(pl, 'something_new'),
      pl.identityResetNoAnswer,
    );
  });
}
