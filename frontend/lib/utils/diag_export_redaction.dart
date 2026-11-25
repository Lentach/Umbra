/// What the hidden E2E diagnostic panel's Copy button puts on the clipboard.
///
/// Users paste that text into bug reports, and the log lines name who the
/// user talks to: the peer's numeric account id (`peer`, `senderId`,
/// `peerIds`...), the chat's conversation id (`activeConvId`, derived from the
/// peer's id for a box friend), the peer's device ids and the user's own id
/// (`userId`, the tail of a `tempId`, the `e2e_<id>_` storage prefix). None
/// of that leaves the device: every distinct id becomes a stable placeholder,
/// so a reader still follows one peer across lines — the same id is the same
/// placeholder within one copy, the user's own id is `me`.
///
/// Entries are stored as the string `HH:MM:SS STEP | {key: value, ...}`
/// (`E2eDiagLog.add`, `E2ePersistentDiag.record`), so they are parsed back
/// into key/value pairs and redacted by KEY, not by a regex over the text.
/// Keys are matched by name, failing closed: an int or a list of ints under
/// any key whose name holds `user`, `peer`, `recipient`, `sender`, `friend`,
/// `contact` (a person), `conv` (a conversation) or `device` (a device) is an
/// id, whatever call site added it. Timestamps, step names, counts, versions,
/// platform names and error text stay readable; error text only loses ids it
/// states next to a person word (`peer 42`) or a 3+ digit id already seen.
///
/// Limits, on purpose: a short bare number in free text (`failed 7 times`) is
/// left alone — it cannot be told from a count — and a key that names none of
/// the words above is not redacted.
String redactDiagForExport(
  List<String> durable,
  List<String> live, {
  int? ownUserId,
}) {
  final redactor = _Redactor(ownUserId);
  final durableLines = redactor.run(durable);
  final liveLines = redactor.run(live);
  return '== DURABLE FAILURES (survives restart) ==\n'
      '${durableLines.join('\n')}\n\n'
      '== LIVE LOG ==\n'
      '${liveLines.join('\n')}';
}

enum _IdKind { person, conversation, device }

final RegExp _int = RegExp(r'^-?\d+$');
final RegExp _pairStart = RegExp(r'^[A-Za-z_][\w.\-]*: ');
final RegExp _tempIdTail = RegExp(r'^(temp_\d+_\d+_)(\d+)$');
final RegExp _storagePrefix = RegExp(r'e2e_(\d+)_');
final RegExp _personWordNumber = RegExp(
  r'\b((?:peer|user|sender|recipient|friend|account|contact)\w*[\s:=#]*)(\d+)\b',
  caseSensitive: false,
);
final RegExp _convWordNumber = RegExp(
  r'\b(conv\w*[\s:=#]*)(\d+)\b',
  caseSensitive: false,
);

_IdKind? _kindOfKey(String key) {
  final k = key.toLowerCase();
  if (k.contains('conv')) return _IdKind.conversation;
  if (k.contains('device') || k == 'gone') return _IdKind.device;
  for (final word in const [
    'user',
    'peer',
    'recipient',
    'sender',
    'friend',
    'contact',
  ]) {
    if (k.contains(word)) return _IdKind.person;
  }
  return null;
}

/// A plural name (`friends`, `devices`) holding ONE int is a count, not an id;
/// a list under it, or an `...Ids` name, is ids.
bool _isCountKey(String key) {
  final lower = key.toLowerCase();
  return lower.endsWith('s') && !lower.endsWith('ids');
}

class _Redactor {
  _Redactor(this.ownUserId);

  final int? ownUserId;
  final Map<_IdKind, Map<int, String>> _names = {
    for (final kind in _IdKind.values) kind: {},
  };

  /// Redacts every line twice over: first all structured ids of all lines are
  /// named (so a free-text mention on an earlier line agrees with a later
  /// structured one), then the lines are rewritten.
  List<String> run(List<String> lines) {
    final parsed = [for (final line in lines) _Line.parse(line)]
      ..forEach(_scan);
    return [for (final line in parsed) _render(line)];
  }

  String _name(_IdKind kind, int id) {
    if (kind == _IdKind.person && id == ownUserId) return 'me';
    final names = _names[kind]!;
    return names[id] ??= switch (kind) {
      _IdKind.person => 'peer#${_letters(names.length)}',
      _IdKind.conversation => 'conv#${names.length + 1}',
      _IdKind.device => 'dev#${names.length + 1}',
    };
  }

  static String _letters(int n) {
    var out = '';
    var i = n;
    do {
      out = String.fromCharCode(65 + i % 26) + out;
      i = i ~/ 26 - 1;
    } while (i >= 0);
    return out;
  }

  /// The ids a pair states: named now so later free text can match them.
  void _scan(_Line line) {
    for (final pair in line.pairs) {
      final ids = _idsOf(pair);
      if (ids == null) continue;
      for (final id in ids.$2) {
        _name(ids.$1, id);
      }
    }
  }

  /// (kind, ids) when [pair] is an id-carrying pair, else null.
  (_IdKind, List<int>)? _idsOf(_Pair pair) {
    final kind = _kindOfKey(pair.key);
    if (kind == null) return null;
    final value = pair.value.trim();
    if (_int.hasMatch(value)) {
      final id = int.parse(value);
      if (id < 0 || (_isCountKey(pair.key) && !_isOwn(kind, id))) return null;
      return (kind, [id]);
    }
    if (value.startsWith('[') && value.endsWith(']')) {
      final inner = value.substring(1, value.length - 1).trim();
      if (inner.isEmpty) return null;
      final parts = inner.split(RegExp(r',\s*'));
      if (parts.every(_int.hasMatch)) {
        return (kind, [for (final p in parts) int.parse(p)]);
      }
    }
    return null;
  }

  bool _isOwn(_IdKind kind, int id) =>
      kind == _IdKind.person && id == ownUserId;

  String _render(_Line line) {
    if (line.pairs.isEmpty) return _freeText(line.raw);
    return '${line.head} | {${[for (final p in line.pairs) _renderPair(p)].join(', ')}}';
  }

  String _renderPair(_Pair pair) {
    final ids = _idsOf(pair);
    if (ids != null) {
      final names = [for (final id in ids.$2) _name(ids.$1, id)];
      final isList = pair.value.trim().startsWith('[');
      return '${pair.key}: ${isList ? '[${names.join(', ')}]' : names.single}';
    }
    final value = pair.value;
    if (pair.key == 'key' && _int.hasMatch(value.trim())) {
      // DEVICELIST_PIN_ENTRY_SKIPPED: the stored pin's key IS a peer id.
      final id = int.parse(value.trim());
      if (id >= 0) return '${pair.key}: ${_name(_IdKind.person, id)}';
    }
    final tail = _tempIdTail.firstMatch(value.trim());
    if (pair.key.toLowerCase().contains('tempid') && tail != null) {
      // `temp_<millis>_<n>_<userId>`: the tail is the sender's own id.
      final id = int.parse(tail.group(2)!);
      return '${pair.key}: ${tail.group(1)}${_name(_IdKind.person, id)}';
    }
    return '${pair.key}: ${_freeText(value)}';
  }

  /// Ids inside free text (an error message, a storage prefix): only those
  /// stated next to a person/conversation word, inside `e2e_<id>_`, or a
  /// 3+ digit id already named.
  String _freeText(String text) {
    var out = text.replaceAllMapped(
      _storagePrefix,
      (m) => 'e2e_${_name(_IdKind.person, int.parse(m.group(1)!))}_',
    );
    out = out.replaceAllMapped(
      _convWordNumber,
      (m) =>
          '${m.group(1)}${_name(_IdKind.conversation, int.parse(m.group(2)!))}',
    );
    out = out.replaceAllMapped(
      _personWordNumber,
      (m) => '${m.group(1)}${_name(_IdKind.person, int.parse(m.group(2)!))}',
    );
    for (final kind in [_IdKind.person, _IdKind.conversation]) {
      for (final entry in _names[kind]!.entries) {
        if (entry.key.toString().length < 3) continue;
        out = out.replaceAll(
          RegExp('(?<![\\w#])${entry.key}(?![\\w])'),
          entry.value,
        );
      }
    }
    final own = ownUserId;
    if (own != null && own.toString().length >= 3) {
      out = out.replaceAll(RegExp('(?<![\\w#])$own(?![\\w])'), 'me');
    }
    return out;
  }
}

class _Pair {
  const _Pair(this.key, this.value);
  final String key;
  final String value;
}

/// One stored entry: `<head> | {<pairs>}`, or just [raw] when it is not that.
class _Line {
  const _Line(this.raw, this.head, this.pairs);

  factory _Line.parse(String raw) {
    final cut = raw.indexOf(' | {');
    if (cut < 0 || !raw.endsWith('}')) {
      return _Line(raw, raw, const []);
    }
    final body = raw.substring(cut + 4, raw.length - 1);
    final pairs = <_Pair>[];
    var depth = 0;
    var start = 0;
    void emit(int end) {
      final text = body.substring(start, end);
      final colon = text.indexOf(': ');
      if (colon > 0) {
        pairs.add(_Pair(text.substring(0, colon), text.substring(colon + 2)));
      }
    }

    for (var i = 0; i < body.length; i++) {
      final c = body[i];
      if (c == '[' || c == '{' || c == '(') depth++;
      if (c == ']' || c == '}' || c == ')') depth--;
      if (depth == 0 &&
          c == ',' &&
          i + 1 < body.length &&
          body[i + 1] == ' ' &&
          _pairStart.hasMatch(body.substring(i + 2))) {
        emit(i);
        start = i + 2;
      }
    }
    emit(body.length);
    // `{}` (no data) has no pairs: nothing to redact, keep the line as is.
    if (pairs.isEmpty) return _Line(raw, raw, const []);
    return _Line(raw, raw.substring(0, cut), pairs);
  }

  final String raw;
  final String head;
  final List<_Pair> pairs;
}
