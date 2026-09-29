import '../contacts/contact_record.dart';
import 'box_frame.dart';

/// Encrypts [json] for device [deviceId] of friend [userId] (the box asks
/// only for friends) and answers the frame from THIS device (kind, this
/// device's id, the Signal bytes, no account), or null when it cannot now:
/// E2E not ready, the friend's VERIFIED list does not name [deviceId] live,
/// or no session could be built (the account anchor refused the key, the
/// bundle fetch failed). [fresh] first builds a NEW session from that
/// device's bundle (a re-key, [BoxFriendLink.rekeyFriend]); the frame is then
/// a PreKey message. The messaging side implements it, so the box layer
/// stays crypto-free (metadata-privacy item 5).
typedef FriendEncrypt =
    Future<BoxFrame?> Function(
      int userId,
      int deviceId,
      String json, {
      bool fresh,
    });

/// The device ids friend [userId]'s VERIFIED list names live, or null when
/// that cannot be known now. Looked up at connect, never by a send (decision
/// 21); the server's word on which devices exist never decides who is
/// handed a queue (E2).
typedef FriendLiveDevices = Future<Set<int>?> Function(int userId);

/// What became of a write a friend's handoff or ack asked for.
enum FriendWrite {
  /// Stored, or already so.
  stored,

  /// Refused for good: not a friend, a queue this device does not hold, a
  /// shape the store cannot keep.
  refused,

  /// The store cannot take it now (closed, a failed write): offer it again.
  retryLater,
}

/// How long a FIRST session this device started with a friend's device
/// waits for that device's own PreKey answer
/// ([BoxFriendLink.awaitingFriendRekeyFrom]); a re-key waits
/// [kFriendRekeyAnswerWindow].
const Duration kFriendRekeyWindow = Duration(minutes: 10);

/// How long a RE-KEY this device sent waits for that device's own PreKey
/// answer: until it is read, or the box drops the frame that could carry it
/// (the box keeps an unread message 30 d). A device that refused our re-key
/// answers with its own only on ITS next connect (it never fetches a bundle
/// on a request-queue frame, BOX-FORGED-PREKEY-LOOKUP), which the 10 min of
/// [kFriendRekeyWindow] would miss: each side would refuse the other's re-key
/// for good, decision 49's stall again. Accepted residual (G5): a revoked
/// device of the friend holding the account identity can answer inside it —
/// only for a device we re-keyed that has not answered yet.
const Duration kFriendRekeyAnswerWindow = Duration(days: 30);

/// What the messaging reader of a friend's queue handoff needs from the box
/// (metadata-privacy item 5, decision 47, E20c/E20d). `BoxSession` is the one
/// implementation.
abstract interface class BoxFriendLink {
  /// Whether this device is on the box now: its request queue is published,
  /// so the server runs the box and friends can hand it their queues. The
  /// composer notice (decision 48) shows only then.
  bool get onBox;

  /// [userId]'s contact record as this device holds it; null when none.
  ContactRecord? contactOf(int userId);

  /// Device [deviceId] of friend [userId] handed off its queue for us
  /// ([sid], [sealPub]): store it as that device's address, replacing an
  /// older one; then acknowledge it into that queue; then — only when that
  /// device has not acknowledged OUR queue for [userId] — hand ours back
  /// into the same queue. The ack goes FIRST, so the friend records it
  /// before it reads our handoff and never answers ours with another. A lost
  /// ack or hand-back costs nothing: the next connect hands off again.
  /// [FriendWrite.stored] once the address is stored, whatever became of
  /// the sends.
  Future<FriendWrite> takeFriendHandoff(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
  });

  /// Device [deviceId] of friend [userId] acknowledged our queue [sid].
  /// [FriendWrite.refused] when no queue of ours for [userId] has that sid
  /// (an older one): the current one is handed to it on the next pass.
  Future<FriendWrite> friendAcked(int userId, int deviceId, String sid);

  /// Hand our queue for [userId] to its device [deviceId] on a FRESH
  /// session ([FriendEncrypt]'s `fresh`): it sent a PreKey message that would
  /// replace the session we hold and we did not ask for one. The handoff is a
  /// PreKey message only that device can read, so what it sends next is
  /// under a session we hold. At most once per device per session. It
  /// fetches that device's bundle: a frame anyone can put on our request
  /// queue asks for it with [rekeyFriendNextConnect] instead.
  Future<void> rekeyFriend(int userId, int deviceId);

  /// [rekeyFriend] on the NEXT connect's handoff pass, never on this one: a
  /// request-queue frame refused as replacing our session with [userId]'s
  /// [deviceId] must not time the bundle fetch a re-key makes — its claimed
  /// sender and identity key are public, so the server could forge it and
  /// learn when this account reads the box and which pair it names (E50f,
  /// owner at G5: defer the re-key).
  void rekeyFriendNextConnect(int userId, int deviceId);

  /// This device just built a session with [userId]'s device [deviceId] —
  /// where it held NONE, or afresh for a re-key — to hand it our queue: that
  /// device's answer may be a PreKey message of its own that replaces it
  /// (two friends starting, or re-keying each other, at once), so it counts
  /// as asked for the next [kFriendRekeyWindow] — a [rekeyFriend] for
  /// [kFriendRekeyAnswerWindow] (decision 49; a revoked device of the friend
  /// can provoke a re-key and use that window). Called by the
  /// [FriendEncrypt] implementation.
  void friendSessionStarted(int userId, int deviceId);

  /// Whether this device started a session with [userId]'s device
  /// [deviceId] ([friendSessionStarted], [rekeyFriend]), its window has not
  /// run out, and it has not read that device since: only then is a PreKey
  /// message from it that would replace our session read (decision 37's
  /// rule; a revoked device of the friend still holds its account identity).
  bool awaitingFriendRekeyFrom(int userId, int deviceId);

  /// A message from [userId]'s device [deviceId] decrypted: the session this
  /// device started with it, if any, is answered.
  void friendRekeyAnswered(int userId, int deviceId);

  /// A message from [userId]'s device [deviceId] was read, on the box or the
  /// old path: that device is not silent. When it has not acknowledged our
  /// queue, the day between handoffs (`kFriendHandoffResend`) is for devices
  /// that are, so it is handed our queue again now — once per device per
  /// session, and not while this connect's own handoff may be in flight.
  void friendHeard(int userId, int deviceId);

  /// Friend [userId]'s verified list stopped naming some device live (a
  /// revoke, slice (e)): the handoff pass runs, which drops that device's
  /// address and rotates our queue away from it (E50e).
  void friendDevicesChanged(int userId);

  /// Sends [auth] — this account's device list — to friend [userId]'s
  /// device [deviceId] as a `list_update` (E50f), into the queue that device
  /// handed us; true only when the box took it. False when this device
  /// holds no address for it: a request queue reads only handoffs.
  Future<bool> sendListUpdate(
    int userId,
    int deviceId,
    Map<String, dynamic> auth,
  );

  /// Sends [auth] as a `list_update` to every live device of every friend
  /// this device holds an address for (a revoke, E50d); true only when the
  /// box took every frame.
  Future<bool> announceOwnList(Map<String, dynamic> auth);
}
