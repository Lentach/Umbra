import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_frame.dart';

/// Encrypts [json] for this account's own device [deviceId] (the pairwise
/// Signal session every linked device already holds) and answers the frame
/// — kind, THIS device's id, the Signal bytes, no account — or null when it
/// cannot now (E2E not ready, no session could be built, a device the own
/// verified list does not name live). [fresh] first builds a NEW session
/// from that device's bundle over the current one, which libsignal ARCHIVES
/// (never deletes, so what the sibling sent on it still reads): the frame is
/// then a PreKey message (decision 37). The messaging side implements it, so
/// the box layer stays crypto-free.
typedef OwnDeviceEncrypt =
    Future<BoxFrame?> Function(int deviceId, String json, {bool fresh});

/// How long a re-key this device sent waits for the sibling's answer
/// ([BoxSiblingLink.awaitingRekeyFrom], decision 37, E37b).
const Duration kSiblingRekeyWindow = Duration(minutes: 10);

/// This device's id and every device id the account's own VERIFIED list
/// names live, or null when that cannot be known now (E2E not ready, the
/// device id not confirmed, the list not verifiable). The messaging side
/// implements it; the box's sibling rotation (E6/E7) acts on nothing else.
typedef OwnLiveDevices = Future<({int self, Set<int> live})?> Function();

/// What the messaging reader of a sibling's box delivery needs from the box
/// (metadata-privacy PR3.1 sibling queues, owner decisions 26–28). `BoxSession`
/// is the one implementation.
abstract interface class BoxSiblingLink {
  /// Sibling [deviceId] handed off its self-queue ([sid], [sealPub]): store
  /// it, replacing any older address; then acknowledge it into that queue;
  /// then — only when this sibling has not acknowledged OUR current
  /// self-queue — hand ours back into the same queue, so a pair converges
  /// even when one side's ask raced the other's publish. The ack goes FIRST:
  /// the sibling records it before it reads our handoff, so it never answers
  /// ours with another. A lost ack or hand-back costs nothing: the next
  /// connect's swap sends again. [SiblingWrite.stored] once the address is
  /// stored, whatever became of the sends.
  Future<SiblingWrite> takeSiblingHandoff(
    int deviceId, {
    required String sid,
    required String sealPub,
  });

  /// Sibling [deviceId] acknowledged self-queue [sid]; recorded only when
  /// [sid] is this device's current one. An ack of any other sid means the
  /// sibling holds an address we replaced (an older handoff overtook the
  /// newer one): the current one is handed to it again (E6).
  Future<SiblingWrite> siblingAcked(int deviceId, String sid);

  /// [userId]'s contact record, which files a sibling's sent copy under its
  /// chat (E5); null when this device holds none (yet).
  ContactRecord? contactOf(int userId);

  /// Hand our self-queue into sibling [deviceId]'s self-queue again, on a
  /// FRESH session ([OwnDeviceEncrypt]'s `fresh`): our Signal session with it
  /// is gone (its delivery found none, E8), or it sent a PreKey message that
  /// would replace the one we hold and we did not ask for it (decision 37).
  /// The handoff is a PreKey message the sibling reads, so what it sends
  /// next is under a session we hold. Once a handoff was built, this device
  /// awaits that sibling's answer ([awaitingRekeyFrom]). At most once per
  /// sibling per session; nothing when its address is unknown.
  Future<void> rekeySibling(int deviceId);

  /// Whether this device re-keyed sibling [deviceId] within the last
  /// [kSiblingRekeyWindow] and has not read it since: only then is a PreKey
  /// message from it that would replace our session read (decision 37). In
  /// memory: a restart mid-exchange costs one more round.
  bool awaitingRekeyFrom(int deviceId);

  /// A message from sibling [deviceId] decrypted: the re-key this device
  /// asked of it, if any, is answered.
  void rekeyAnswered(int deviceId);
}
