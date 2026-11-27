import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `kickSendPumps` is an extension method (static dispatch), so the app's
/// wiring of the box's two start-up kicks cannot be observed through a fake.
/// The wiring is therefore pinned at its source: the end of the labelling
/// (`onAddressesLabelled`) must kick the send pump exactly as the judged
/// journal does (review P2-1: a row refused `unlabelled` would otherwise wait
/// for an unrelated kick).
void main() {
  final source = File('lib/providers/connection_provider.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the end of the labelling kicks the send pump in the app wiring', () {
    expect(
      RegExp(r'\.\.onAddressesLabelled\s*=\s*messaging\.kickSendPumps')
          .allMatches(source),
      hasLength(1),
    );
  });

  test('the judged journal kicks it too (the sibling kick)', () {
    expect(
      RegExp(r'\.\.onJournalJudged\s*=\s*messaging\.kickSendPumps')
          .allMatches(source),
      hasLength(1),
    );
  });

  // Owner decision C: the red bar closes the gate, and its end kicks the pump.
  test('the red key-change bar closes the friend write gate in the app '
      'wiring, by the same predicate the bar is drawn from', () {
    expect(
      RegExp(
        r'\.\.redHeld\s*=\s*\(\(peer\)\s*=>\s*_encryptionProvider\?\.redBarShows\(peer\)',
      ).allMatches(source),
      hasLength(1),
    );
  });

  test('the end of the red bar kicks the send pump in the app wiring', () {
    expect(
      RegExp(
        r'_encryptionProvider\?\.onRedHoldEnded\s*=\s*\(peer\)\s*=>\s*_messagingProvider\?\.kickSendPump\(peer\)',
      ).allMatches(source),
      hasLength(1),
    );
  });
}
