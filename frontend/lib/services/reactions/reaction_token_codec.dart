import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

/// Blinds a reaction emoji into a token the SERVER cannot read.
///
/// Design of record: `docs/design/reaction-privacy.md` (owner-picked option B).
/// `messages.reactions` keeps its `{key: [userId]}` shape and all of the
/// server's merge/toggle/atomicity logic; only the KEY changes, from the emoji
/// itself to
///
///   base64url( HMAC-SHA256(K_react, "umbra.reaction.v1" || emoji) [0..15] )
///
/// The token is deterministic per conversation, which is exactly what lets the
/// server keep aggregating chips while learning nothing about which emoji it
/// is holding. `K_react` never leaves the two participants' devices, so HMAC
/// without it is not invertible and the public emoji set buys an attacker
/// nothing.
///
/// **Skin tones are normalised away before hashing** (U+1F3FB..U+1F3FF plus
/// VS16). Without that the reverse map would have to enumerate every tone
/// variant of every emoji, and a peer's toned reaction would render as the
/// unknown-token placeholder on this device. The visible consequence is
/// deliberate and small: a reaction is displayed in its base tone, and two
/// participants reacting with different tones of the same emoji share one
/// chip — which is what a reader expects from a counter anyway.
class ReactionTokenCodec {
  ReactionTokenCodec(Uint8List key)
    : assert(key.length == keyBytes, 'K_react must be $keyBytes bytes'),
      _key = key;

  /// Domain separation: this key is used for nothing else today, and a future
  /// second use MUST get its own string rather than share this one.
  static const String domain = 'umbra.reaction.v1';

  /// 32 bytes of CSPRNG output, generated once per conversation epoch.
  static const int keyBytes = 32;

  /// 16 of the 32 HMAC bytes. Enough that a collision inside ONE conversation
  /// is not reachable (the candidate set is ~1.8k emoji), and short enough
  /// that a row of tokens stays comparable in size to a row of emoji.
  static const int tokenBytes = 16;

  /// 16 bytes, base64url, padding stripped.
  static const int tokenChars = 22;

  static final RegExp _tokenShape = RegExp('^[A-Za-z0-9_-]{$tokenChars}\$');
  static final RegExp _skinTone = RegExp('[\u{1F3FB}-\u{1F3FF}\uFE0F]', unicode: true);

  final Uint8List _key;
  Map<String, String>? _emojiByToken;

  /// True when [value] has the shape of a token rather than an emoji.
  ///
  /// The two alphabets cannot overlap — a token is 22 ASCII characters from
  /// the base64url set — which is what lets one column hold both shapes
  /// during the legacy-client compat window (design §3.3).
  static bool looksLikeToken(String value) => _tokenShape.hasMatch(value);

  /// Strips skin-tone modifiers and VS16 so every variant of one emoji hashes
  /// to the same token.
  static String normalise(String emoji) => emoji.replaceAll(_skinTone, '');

  String tokenFor(String emoji) {
    final mac = Hmac(
      sha256,
      _key,
    ).convert(utf8.encode('$domain${normalise(emoji)}'));
    return base64Url
        .encode(Uint8List.fromList(mac.bytes.sublist(0, tokenBytes)))
        .replaceAll('=', '');
  }

  /// The emoji a token stands for, or null when this device cannot name it.
  ///
  /// Null is a legitimate answer, not an error: it is what a device sees for a
  /// reaction sent under an epoch whose key it does not hold (design §3.2), and
  /// the caller MUST render a placeholder rather than dropping the chip —
  /// dropping it would make the peer's reaction indistinguishable from no
  /// reaction at all.
  String? emojiFor(String token) => (_emojiByToken ??= _buildReverse())[token];

  /// token → the **display-qualified** emoji, never the normalised key.
  ///
  /// Canonical-for-hashing and qualified-for-display are deliberately two
  /// different strings. `normalise` strips VS16, and `'\u2764'` without it
  /// renders as monochrome TEXT presentation on several platforms — so
  /// rendering the hash key would visibly change a reaction the user picked
  /// as `'\u2764\uFE0F'`. The map therefore keys on the normalised token and
  /// stores the picker's own string as the value.
  Map<String, String> _buildReverse() {
    final out = <String, String>{};
    for (final category in defaultEmojiSet) {
      for (final emoji in category.emoji) {
        final display = emoji.emoji;
        if (normalise(display).isEmpty) continue;
        // First writer wins: two entries normalising to the same token are one
        // reaction as far as this map is concerned, and the picker lists the
        // qualified form first.
        out.putIfAbsent(tokenFor(display), () => display);
      }
    }
    return out;
  }
}
