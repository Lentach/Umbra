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

/// Whether a pin, edit, delete-for-everyone or reaction can name the
/// message [id]: a server row by its id (the old path, decision 46), a box
/// message by its sender's [wireId] (item 4, E19a) — never an unsent row.
bool hasActionTarget(int id, {String? wireId}) =>
    isServerMessageId(id) || (isLocalMessageId(id) && wireId != null);

/// The first LOCAL conversation id (metadata-privacy owner decision 52): a
/// friendship made over the box has no server `conversations` row, so its
/// chat is keyed by [localConversationIdFor]. 2^48, as [kFirstLocalMessageId]
/// (a separate namespace: a conversation id is never compared with a
/// message id), far above any server id and exact on web.
const int kFirstLocalConversationId = 281_474_976_710_656;

/// The chat id of a friendship made over the box with [peerUserId]: derived,
/// not counted, so every device of the account and the history file agree on
/// it with nothing to sync.
int localConversationIdFor(int peerUserId) =>
    kFirstLocalConversationId + peerUserId;

/// Whether [conversationId] names a chat with no server row — the ONE test
/// every server event keyed by a conversation id (history, read marks, the
/// timer, mute, clear, delete, reaction keys) must fail before it is emitted.
bool isLocalConversationId(int conversationId) =>
    conversationId >= kFirstLocalConversationId;
