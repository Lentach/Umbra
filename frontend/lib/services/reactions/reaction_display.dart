import 'reaction_token_codec.dart';

/// Turns the map the SERVER sends into the map the UI renders.
///
/// The wire map is keyed by whatever the sender wrote: a blinded token from an
/// updated client, or a plain emoji from one that has not updated yet (the
/// compat window, design §3.3). Both shapes can sit in the same map, and they
/// are distinguishable because a token is exactly 22 base64url characters and
/// an emoji never is.
///
/// A token this device cannot name is LEFT AS THE TOKEN, not dropped. Dropping
/// it would make a peer's reaction indistinguishable from no reaction at all
/// (falsification R4); leaving it lets the chip render a neutral placeholder
/// with the right count, and re-render for real once the key arrives.
Map<String, List<int>> resolveReactionKeys(
  Map<String, List<int>> wire,
  ReactionTokenCodec? codec,
) {
  if (wire.isEmpty) return wire;
  final out = <String, List<int>>{};
  for (final entry in wire.entries) {
    final key = ReactionTokenCodec.looksLikeToken(entry.key)
        ? (codec?.emojiFor(entry.key) ?? entry.key)
        : entry.key;
    final existing = out[key];
    if (existing == null) {
      out[key] = List<int>.of(entry.value);
    } else {
      // Two wire keys can resolve to one emoji during the compat window: a
      // legacy client's plain '👍' and an updated client's token for the same
      // emoji. They are ONE chip, and a user appearing under both counts once.
      for (final userId in entry.value) {
        if (!existing.contains(userId)) existing.add(userId);
      }
    }
  }
  return out;
}

/// Whether [key] is a reaction this device cannot name yet.
///
/// True only for a token shape that survived [resolveReactionKeys] — i.e. the
/// key for this conversation is missing, locked, or not yet pulled. Renderers
/// use it to pick the placeholder glyph instead of printing 22 base64
/// characters into a chip.
bool isUnresolvedReactionKey(String key) =>
    ReactionTokenCodec.looksLikeToken(key);
