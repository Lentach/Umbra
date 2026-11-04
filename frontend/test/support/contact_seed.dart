import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A contact record for [id], named [name] (`name#000<id>` style tag).
///
/// [box] gives it a box origin (a request or friendship made over the box):
/// only those requests are listed. [chatId] is the legacy chat id a friend
/// from before the box keeps its history under.
ContactRecord contactRecord(
  int id,
  String name,
  ContactState state, {
  bool box = false,
  int? chatId,
  ContactSettings settings = const ContactSettings(),
}) => ContactRecord(
  userId: id,
  username: name,
  tag: id.toString().padLeft(4, '0'),
  state: state,
  settings: settings,
  legacy: ContactLegacy(
    conversationId: chatId,
    conversationCreatedAt: chatId == null ? null : DateTime.utc(2026),
  ),
  // Relative to now: a box request is shown for 30 d, so a fixed date stops
  // showing it once the calendar passes it.
  boxOrigin: box
      ? ContactBoxOrigin(
          at: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        )
      : null,
);

/// A real open contact store for account [selfId] (named [selfName]) holding
/// [records]: what the friend and chat providers read their lists from.
Future<ContactStore> openContactStore(
  List<ContactRecord> records, {
  int selfId = 1,
  String selfName = 'alice',
  bool resetPrefs = true,
}) async {
  if (resetPrefs) SharedPreferences.setMockInitialValues({});
  final kv = await PrefsContentKv.open();
  final store = ContactStore(
    open: () async => kv,
    selfProfile: () => UserModel(
      id: selfId,
      username: selfName,
      tag: selfId.toString().padLeft(4, '0'),
    ),
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );
  await store.open(selfId);
  await putContacts(store, records);
  return store;
}

/// Writes [records] (replacing any record of the same user) and waits for the
/// store's queued writes to settle.
Future<void> putContacts(ContactStore store, List<ContactRecord> records) async {
  for (final r in records) {
    unawaited(store.update(r.userId, (_) => r));
  }
  await store.settled;
}

/// A [FriendsProvider] reading [store], for the store's own account.
FriendsProvider friendsOver(ContactStore store) => FriendsProvider()
  ..contactStore = store
  ..setCurrentUserId(store.userId!);

/// A [ConversationsProvider] that has read [store]'s chats.
ConversationsProvider conversationsOver(ContactStore store) =>
    ConversationsProvider()
      ..contactStore = store
      ..setCurrentUserId(store.userId!)
      ..hydrateFromStore();

/// Opens a contact store holding [records] once, then builds [builder] with
/// it (blank until it is open). For the dev preview harnesses, which have no
/// async `main` of their own; the store is prefs-backed, so a preview keeps
/// whatever the page already holds.
class SeededStoreHost extends StatefulWidget {
  const SeededStoreHost({
    super.key,
    required this.records,
    required this.selfId,
    required this.selfName,
    required this.builder,
  });

  final List<ContactRecord> records;
  final int selfId;
  final String selfName;
  final Widget Function(BuildContext context, ContactStore store) builder;

  @override
  State<SeededStoreHost> createState() => _SeededStoreHostState();
}

class _SeededStoreHostState extends State<SeededStoreHost> {
  ContactStore? _store;

  @override
  void initState() {
    super.initState();
    openContactStore(
      widget.records,
      selfId: widget.selfId,
      selfName: widget.selfName,
      resetPrefs: false,
    ).then((store) {
      if (mounted) setState(() => _store = store);
    }).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return store == null
        ? const SizedBox.shrink()
        : widget.builder(context, store);
  }
}
