import 'user_model.dart';

enum InvitationAction { send, accept, decline }

enum InvitationActionStatus { inFlight, failed }

enum InvitationDirection { incoming, outgoing }

/// A friendship made over the box, as the invitations screen shows it after
/// the accept: the peer and the chat that is already open for them.
class InvitationOutcome {
  final int peerUserId;
  final InvitationDirection direction;
  final UserModel peer;
  final int? requestId;
  final int? conversationId;

  const InvitationOutcome({
    required this.peerUserId,
    required this.direction,
    required this.peer,
    required this.requestId,
    required this.conversationId,
  });
}

class InvitationFailure {
  final InvitationAction action;
  final int? requestId;
  final int? recipientId;
  final String reason;

  const InvitationFailure({
    required this.action,
    required this.requestId,
    required this.recipientId,
    required this.reason,
  });
}

class PendingFriendAccepted {
  final String name;
  final int peerUserId;
  final int? conversationId;

  const PendingFriendAccepted({
    required this.name,
    required this.peerUserId,
    required this.conversationId,
  });
}
