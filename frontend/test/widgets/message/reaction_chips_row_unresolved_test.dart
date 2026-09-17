import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/reactions/reaction_display.dart';
import 'package:fireplace/services/reactions/reaction_token_codec.dart';
import 'package:fireplace/widgets/message/reaction_chips_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A reaction this device cannot name must still be VISIBLE with its real
/// count. Hiding it makes the peer's reaction indistinguishable from "they
/// removed it" (design falsification R4), and printing the raw token puts 22
/// base64 characters in the bubble.
void main() {
  final codec = ReactionTokenCodec(
    Uint8List.fromList(List<int>.generate(32, (i) => i)),
  );
  final foreign = ReactionTokenCodec(
    Uint8List.fromList(List<int>.generate(32, (i) => 200 - i)),
  ).tokenFor('😂');

  Future<void> pump(
    WidgetTester tester,
    Map<String, List<int>> reactions, {
    // Why ignored: this mirrors ReactionChipsRow.onTap, whose `(String, bool)`
    // shape is pre-existing public API of the widget under test. Renaming it
    // to satisfy the lint would change production code for a test's benefit.
    // ignore: avoid_positional_boolean_parameters
    void Function(String, bool)? onTap,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReactionChipsRow(
            reactions: reactions,
            currentUserId: 1,
            onTap: onTap ?? (_, _) {},
          ),
        ),
      ),
    );
  }

  testWidgets('an unnameable token renders the placeholder and its count', (
    tester,
  ) async {
    await pump(tester, {foreign: [2, 3]});

    expect(find.textContaining(kUnresolvedReactionGlyph), findsOneWidget);
    expect(find.textContaining('2'), findsOneWidget); // the count
    expect(
      find.textContaining(foreign.substring(0, 8)),
      findsNothing,
      reason: 'the token must never reach the bubble',
    );
  });

  testWidgets('an unnameable chip is inert', (tester) async {
    final taps = <String>[];
    await pump(tester, {foreign: [2]}, onTap: (key, _) => taps.add(key));

    await tester.tap(find.textContaining(kUnresolvedReactionGlyph));
    await tester.pump();

    expect(
      taps,
      isEmpty,
      reason:
          'this device cannot compute that token, so a tap could only ask the '
          'server to toggle a reaction it cannot name',
    );
  });

  testWidgets('a resolved token renders as the emoji and taps through', (
    tester,
  ) async {
    final resolved = resolveReactionKeys({codec.tokenFor('🔥'): [2]}, codec);
    final taps = <String>[];
    await pump(tester, resolved, onTap: (key, _) => taps.add(key));

    expect(find.textContaining('🔥'), findsOneWidget);
    await tester.tap(find.textContaining('🔥'));
    expect(taps, ['🔥']);
  });

  testWidgets('a legacy plaintext emoji still renders untouched', (
    tester,
  ) async {
    // The compat window: an un-updated client writes the emoji itself.
    await pump(tester, resolveReactionKeys({'👍': [2]}, codec));

    expect(find.textContaining('👍'), findsOneWidget);
    expect(find.textContaining(kUnresolvedReactionGlyph), findsNothing);
  });

  test('a legacy emoji and a token for the SAME emoji are one chip', () {
    final merged = resolveReactionKeys({
      '👍': [2],
      codec.tokenFor('👍'): [3, 2],
    }, codec);

    expect(merged.keys, hasLength(1));
    expect(
      merged.values.single,
      [2, 3],
      reason: 'a user present under both shapes counts once',
    );
  });

  test('an empty map is returned untouched, not rebuilt', () {
    final empty = <String, List<int>>{};
    expect(resolveReactionKeys(empty, codec), same(empty));
  });

  test('resolution needs no codec to pass legacy emoji through', () {
    final out = resolveReactionKeys({'❤️': [1]}, null);
    expect(out.keys.single, '❤️');
    // …but a token without a codec stays a token, so the chip placeholders.
    final tokenOnly = resolveReactionKeys({foreign: [1]}, null);
    expect(isUnresolvedReactionKey(tokenOnly.keys.single), isTrue);
  });

  test('base64 of a 32-byte key is what the codec expects', () {
    // Guards the fixture itself: a wrong-length key would make every token in
    // this file meaningless while the assertions still passed.
    expect(base64Decode(base64Encode(List<int>.generate(32, (i) => i))),
        hasLength(ReactionTokenCodec.keyBytes));
  });
}
