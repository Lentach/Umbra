/// The first LOCAL message id (metadata-privacy owner decision 14): a
/// box-delivered message has no server row, so this device names it from a
/// per-account counter starting here. 2^48, written out because a shift is
/// 32-bit on web; far above any server id and below 2^53, so it stays an
/// exact integer on web.
const int kFirstLocalMessageId = 281474976710656;

/// Whether [id] names a server `messages` row: the ONE test every server
/// action keyed by a message id (pin, edit, delete, reaction, delivery
/// receipt, reconciliation) must pass. Temp ids of unsent rows are negative;
/// local ids are at or above [kFirstLocalMessageId].
bool isServerMessageId(int id) => id > 0 && id < kFirstLocalMessageId;

/// Whether [id] names a box message this device holds under a LOCAL id —
/// not a temp id (an unsent row, which still belongs to its send path).
bool isLocalMessageId(int id) => id >= kFirstLocalMessageId;
