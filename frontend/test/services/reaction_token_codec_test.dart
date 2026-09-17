import 'dart:typed_data';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:fireplace/services/reactions/reaction_token_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _key(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + seed) & 0xff));

void main() {
  test('a token round-trips to a DISPLAY-QUALIFIED emoji', () {
    final codec = ReactionTokenCodec(_key(1));
    for (final emoji in ['👍', '❤️', '😂', '😮', '😢', '🔥']) {
      final named = codec.emojiFor(codec.tokenFor(emoji));
      expect(named, isNotNull, reason: 'the quick-reaction row must be nameable on the far side');
      expect(
        ReactionTokenCodec.normalise(named!),
        ReactionTokenCodec.normalise(emoji),
        reason: 'it must name the same reaction the sender picked',
      );
    }
  });

  test('the named emoji keeps VS16, so a heart is not rendered as text', () {
    final codec = ReactionTokenCodec(_key(1));
    const heart = '❤️'; // U+2764 U+FE0F
    final named = codec.emojiFor(codec.tokenFor(heart))!;
    expect(
      named.runes,
      contains(0xFE0F),
      reason:
          'hashing normalises VS16 away, but rendering the normalised key '
          'would flip the heart to monochrome TEXT presentation on several '
          'platforms — canonical-for-hashing and qualified-for-display are '
          'deliberately different strings',
    );
  });

  test('the same emoji under a DIFFERENT conversation key is a different token', () {
    final a = ReactionTokenCodec(_key(1));
    final b = ReactionTokenCodec(_key(2));
    expect(
      a.tokenFor('👍'),
      isNot(b.tokenFor('👍')),
      reason:
          'per-conversation scope is what stops the server correlating one '
          'learned mapping across every conversation (falsification R1)',
    );
  });

  test('tokens are 22 base64url chars and self-identifying against emoji', () {
    final codec = ReactionTokenCodec(_key(3));
    final token = codec.tokenFor('🔥');
    expect(token, hasLength(ReactionTokenCodec.tokenChars));
    expect(ReactionTokenCodec.looksLikeToken(token), isTrue);
    // The compat window puts both shapes in one column, so the discriminator
    // must never confuse them in either direction.
    expect(ReactionTokenCodec.looksLikeToken('🔥'), isFalse);
    expect(ReactionTokenCodec.looksLikeToken('👍'), isFalse);
    expect(ReactionTokenCodec.looksLikeToken(token.substring(1)), isFalse);
    expect(ReactionTokenCodec.looksLikeToken('$token='), isFalse);
  });

  test('every skin tone of one emoji collapses to one token', () {
    final codec = ReactionTokenCodec(_key(4));
    const base = '👍';
    const tones = ['👍🏻', '👍🏼', '👍🏽', '👍🏾', '👍🏿'];
    for (final toned in tones) {
      expect(
        codec.tokenFor(toned),
        codec.tokenFor(base),
        reason:
            'without normalisation a toned reaction would arrive as an '
            'unnameable token and render as the placeholder',
      );
    }
    expect(codec.emojiFor(codec.tokenFor(tones.first)), base);
  });

  test('no two emoji in the pickable set collide on a token', () {
    final codec = ReactionTokenCodec(_key(5));
    final seen = <String, String>{};
    final collisions = <String>[];
    for (final category in defaultEmojiSet) {
      for (final e in category.emoji) {
        final base = ReactionTokenCodec.normalise(e.emoji);
        if (base.isEmpty) continue;
        final token = codec.tokenFor(base);
        final prior = seen[token];
        if (prior != null && prior != base) collisions.add('$prior vs $base');
        seen[token] = base;
      }
    }
    expect(
      collisions,
      isEmpty,
      reason:
          'a collision merges two different reactions into one chip '
          '(falsification R6 — this is what 16 bytes is buying)',
    );
    expect(
      seen.length,
      greaterThan(1000),
      reason: 'the reverse map must actually cover the picker, not a handful',
    );
  });

  test('an unknown token is null, not a crash and not an empty string', () {
    final codec = ReactionTokenCodec(_key(6));
    // A token from another conversation's key: right shape, unnameable here.
    final foreign = ReactionTokenCodec(_key(7)).tokenFor('😂');
    expect(codec.emojiFor(foreign), isNull);
    expect(codec.emojiFor('not-a-real-token-1234'), isNull);
  });
}
