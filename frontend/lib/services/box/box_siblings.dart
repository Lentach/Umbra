import '../contacts/contact_store.dart';
import 'box_frame.dart';

/// Encrypts [json] for this account's own device [deviceId] (the pairwise
/// Signal session every linked device already holds) and answers the frame
/// — kind, THIS device's id, the Signal bytes, no account — or null when it
/// cannot now (E2E not ready, no session could be built, a device the own
/// verified list does not name live). The messaging side implements it, so
/// the box layer stays crypto-free.
typedef OwnDeviceEncrypt = Future<BoxFrame?> Function(int deviceId, String json);

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
  /// stored, whatever became of the two sends.
  Future<SiblingWrite> takeSiblingHandoff(
    int deviceId, {
    required String sid,
    required String sealPub,
  });

  /// Sibling [deviceId] acknowledged self-queue [sid]; recorded only when it
  /// is this device's current one.
  Future<SiblingWrite> siblingAcked(int deviceId, String sid);

  /// Whether [rid] is this device's self-queue — whose sid only siblings
  /// were handed. Any other own-account delivery came in on the PUBLIC
  /// request queue, where a frame that cannot be read now is dropped rather
  /// than held: anyone can fill that queue, and a real sibling hands off
  /// again on its next connect.
  bool viaSelfQueue(String rid);
}
