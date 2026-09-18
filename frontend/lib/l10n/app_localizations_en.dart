// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settings => 'Settings';

  @override
  String get theme => 'Theme';

  @override
  String get language => 'Language';

  @override
  String get languagePolish => 'Polish';

  @override
  String get languageEnglish => 'English';

  @override
  String get privacyAndSafety => 'Privacy and Safety';

  @override
  String get blocked => 'Blocked';

  @override
  String get devices => 'Devices';

  @override
  String get webPushEnableTitle => 'Enable push notifications';

  @override
  String get webPushEnableSubtitle =>
      'Required on iOS after adding app to Home Screen';

  @override
  String get webPushEnabled => 'Push notifications enabled';

  @override
  String get webPushPermissionDenied => 'Push permission denied';

  @override
  String get webPushInstallRequired =>
      'Add Umbra to Home Screen first (Safari -> Share -> Add to Home Screen)';

  @override
  String get webPushNotSupported =>
      'Push is not supported in this browser/session';

  @override
  String get webPushNoChanges => 'Push is already enabled';

  @override
  String get webPushEnableFailed => 'Failed to enable push';

  @override
  String get resetPassword => 'Reset Password';

  @override
  String get deleteAccount => 'Delete Account';

  @override
  String get logout => 'Logout';

  @override
  String get uninstallWarning =>
      'Don\'t uninstall or clear data — history is lost.';

  @override
  String get uninstallWarningTitle => 'Uninstalling or clearing data';

  @override
  String get chat => 'Chats';

  @override
  String get contacts => 'Contacts';

  @override
  String get uploadFailed => 'Upload failed';

  @override
  String get passwordUpdatedSuccessfully => 'Password updated successfully';

  @override
  String get passwordResetFailed => 'Password reset failed';

  @override
  String get accountDeletionFailed => 'Account deletion failed';

  @override
  String get devicesLoading => 'Loading…';

  @override
  String get devicesExplainer =>
      'Add new devices from the primary device only.';

  @override
  String get devicesLinkedDeviceNote =>
      'This device is linked. New devices are added from the primary device.';

  @override
  String get devicesNotEnrolled =>
      'Device linking is not enabled for this account yet.';

  @override
  String get devicesEnableLinking => 'Enable linking';

  @override
  String get devicesLinkADevice => 'Link a device';

  @override
  String get devicesLinkThisDevice => 'Link this device';

  @override
  String get devicesAlreadyEnrolled =>
      'Linking is enabled on another device. Add from there.';

  @override
  String get devicesEnrollFailed => 'Could not enable linking. Try again.';

  @override
  String get devicesChainInvalid =>
      'The device list could not be verified. Try again later.';

  @override
  String get devicesRevokedBadge => 'revoked';

  @override
  String devicesRevokedSection(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Revoked devices ($count)',
      one: 'Revoked device (1)',
    );
    return '$_temp0';
  }

  @override
  String get devicesRevokeAction => 'Remove device';

  @override
  String get devicesRevokeTitle => 'Remove this device?';

  @override
  String get devicesRevokeExplainer =>
      'It will be signed out. Its messages stay.';

  @override
  String get devicesRevokeFailed => 'Could not remove that device. Try again.';

  @override
  String get deviceRevokedNotice =>
      'This device was removed. Sign in and link it again.';

  @override
  String get deviceMismatchTitle => 'This device was removed from the account';

  @override
  String get deviceMismatchBody =>
      'This device\'s keys were revoked. Link it again from your other device.';

  @override
  String get deviceMismatchAction => 'Link this device';

  @override
  String get devicesPrimaryBadge => 'primary';

  @override
  String get devicesThisDeviceKeyless =>
      'This device holds no keys yet. Link it to your primary device.';

  @override
  String get linkPrimaryTitle => 'Link a device';

  @override
  String get linkPrimaryExplainer =>
      'On the new device choose “Link this device”, then type the code it shows here.';

  @override
  String get linkPrimaryCodeLabel => 'Code from the new device';

  @override
  String get linkPrimaryContinue => 'Continue';

  @override
  String get linkSasHeading => 'Compare the codes';

  @override
  String get linkSasExplainer =>
      'Both devices must show the same code. Approve only if they match exactly.';

  @override
  String get linkApprove => 'Approve';

  @override
  String get linkCancel => 'Cancel';

  @override
  String get linkWaitingForDevice => 'Waiting for the new device…';

  @override
  String get linkPrimaryDone => 'The device has been linked.';

  @override
  String get linkInvalidCode =>
      'Invalid code. Copy it exactly from the new device.';

  @override
  String get linkNoDak => 'Only the device that enabled linking can link.';

  @override
  String get linkFailed => 'Linking failed';

  @override
  String get linkStaleVersionRetry =>
      'The device list changed mid-flight — re-signing…';

  @override
  String get linkNewTitle => 'Link this device';

  @override
  String get linkNewExplainer =>
      'On the primary: Link a device → scan or type this code.';

  @override
  String get linkNewWaitingHello => 'Waiting for your primary device…';

  @override
  String get linkNewCopy => 'Copy code';

  @override
  String get linkNewCopied => 'Code copied';

  @override
  String get linkNewCompleting => 'Linking…';

  @override
  String get linkNewRebinding => 'Switching the session to the new device…';

  @override
  String get linkNewDone => 'This device is linked and ready.';

  @override
  String get linkNewAborted => 'Linking aborted';

  @override
  String get linkNewRetry => 'Try again';

  @override
  String get linkAbortReasonExpired => 'The code expired.';

  @override
  String get linkAbortReasonCancelled =>
      'Linking was cancelled on the other device.';

  @override
  String get linkAbortReasonBadBlob =>
      'Verification failed. Every key was removed from this device.';

  @override
  String get settingsAppVersion => 'App version';

  @override
  String get settingsAboutFireplace => 'About';

  @override
  String get settingsSectionPreferences => 'PREFERENCES';

  @override
  String get settingsSectionSecurity => 'SECURITY';

  @override
  String get settingsSectionSession => 'SESSION';

  @override
  String get privacySafetyTitle => 'Privacy & Safety';

  @override
  String get e2eEncryptionEnabled => 'End-to-end encryption is enabled';

  @override
  String get e2eEncryptionDescription =>
      'Signal encryption. Only you and the recipient see the content.';

  @override
  String get yourEncryptionKeys => 'Your encryption keys';

  @override
  String get yourEncryptionKeysDescription =>
      'Keys live only on this device. Without a backup they can\'t be recovered.';

  @override
  String get singleDeviceEncryption => 'Single-device encryption';

  @override
  String get singleDeviceEncryptionDescription =>
      'Each device has its own keys.';

  @override
  String get webKeyStorage => 'Web: key storage';

  @override
  String get webKeyStorageDescription =>
      'In a browser only the passcode lock protects the keys.';

  @override
  String get whatIsEncrypted => 'What is encrypted';

  @override
  String get whatIsEncryptedDescription =>
      'Text, images, voice, links — all end-to-end.';

  @override
  String get serverStoresMetadata => 'What the server stores (metadata)';

  @override
  String get serverStoresMetadataDescription =>
      'The server sees who, with whom and when. Never the content.';

  @override
  String get deleteAllLocalHistoryTitle =>
      'Delete all messages stored on this device';

  @override
  String get deleteAllLocalHistoryDescription =>
      'Deletes messages from this device. Account and keys stay.';

  @override
  String get deleteAllLocalHistoryButton =>
      'Permanently delete all local messages';

  @override
  String get deleteAllLocalHistoryDialogTitle =>
      'Permanently delete all local messages?';

  @override
  String get deleteAllLocalHistoryDialogBody =>
      'Messages on this device are gone for good.';

  @override
  String get deleteAllLocalHistoryConfirm => 'Delete permanently';

  @override
  String get yourIdentityFingerprint => 'Your identity fingerprint';

  @override
  String get shareFingerprintHint =>
      'This is a unique representation of your encryption key.';

  @override
  String get invitations => 'Invitations';

  @override
  String get invitationsWaitingForYou => 'Waiting for you';

  @override
  String get invitationsSent => 'Sent';

  @override
  String get invitationsNothingWaiting => 'Nothing waiting for you';

  @override
  String get invitationsNoneSent => 'No sent invitations';

  @override
  String get inviteByHandleHint =>
      'Invite someone by username#tag. Your own #tag is in Settings, next to your nickname.';

  @override
  String get usernameTagPlaceholder => 'username#1234';

  @override
  String get sendInvitation => 'Send invitation';

  @override
  String get invitationFindUser => 'Find user';

  @override
  String get userNotFound => 'User not found';

  @override
  String get invitationWantsToConnect => 'Wants to connect';

  @override
  String get invitationWaitingForResponse => 'Waiting for response';

  @override
  String get invitationAccepted => 'Invitation accepted';

  @override
  String get invitationChatReady => 'Chat ready';

  @override
  String get invitationChatNeedsRetry => 'Chat setup needs retry';

  @override
  String get invitationOpenChat => 'Open chat';

  @override
  String get invitationCreateChat => 'Create chat';

  @override
  String get invitationDone => 'Done';

  @override
  String get invitationDecline => 'Decline';

  @override
  String get accept => 'Accept';

  @override
  String get invitationStatusPending => 'Pending';

  @override
  String get invitationSendFailed => 'Could not send the invitation';

  @override
  String get invitationAcceptFailed => 'Could not accept the invitation';

  @override
  String get invitationDeclineFailed => 'Could not decline the invitation';

  @override
  String get invitationChatSetupFailed => 'Could not set up the chat';

  @override
  String get invitationFailedUserNotFound => 'That user no longer exists';

  @override
  String get invitationFailedSelf => 'You cannot invite yourself';

  @override
  String get invitationFailedBlocked => 'You cannot invite this user';

  @override
  String get invitationFailedAlreadyFriends => 'You are already connected';

  @override
  String get invitationFailedDuplicate => 'Invitation already sent';

  @override
  String get invitationFailedInvalidPayload =>
      'Something was wrong with that request';

  @override
  String get invitationFailedNotFriends =>
      'You are not connected with this user';

  @override
  String invitationSemanticIncoming(String name) {
    return '$name, invitation received, wants to connect';
  }

  @override
  String invitationSemanticOutgoing(String name) {
    return '$name, invitation sent, waiting for response';
  }

  @override
  String invitationSemanticAcceptedReady(String name) {
    return '$name, invitation accepted, chat ready';
  }

  @override
  String invitationSemanticAcceptedNotReady(String name) {
    return '$name, invitation accepted, chat setup needs retry';
  }

  @override
  String get encryptedMessage => 'Encrypted message';

  @override
  String get decryptingMessage => 'Decrypting…';

  @override
  String get messageNoLongerStoredOnThisDevice =>
      'This message is no longer stored on this device.';

  @override
  String get messageUnreadableOnThisDevice =>
      'This message can\'t be read on this device.';

  @override
  String get messageUnreadableReasonKeysGone =>
      'The keys are gone — reinstalling won\'t bring them back.';

  @override
  String get messageUnreadableReasonOwnCopyGone =>
      'Your only copy was on the sending device.';

  @override
  String get historyBeforeDeviceLinked =>
      'History from before this device was linked';

  @override
  String get devicesSyncingNote => 'Syncing your devices…';

  @override
  String get encryptionNotInitialized => 'Encryption not initialized';

  @override
  String get identityDamagedTitle => 'Encryption keys missing on this device';

  @override
  String get messageRetrySend => 'Retry';

  @override
  String get messageSendBlockedKeysChanged =>
      'Not sent: this contact\'s security keys changed. Open the red warning in this chat and compare your safety numbers, then retry.';

  @override
  String get authStatusSavedSessionUnreadable =>
      'Could not read the session. Restart the app.';

  @override
  String get authStatusRegisterSucceeded =>
      'Account created. Sign in to continue.';

  @override
  String get authStatusServerUnreachable => 'No connection. Try again.';

  @override
  String get authStatusUnexpectedError =>
      'Something went wrong. Please try again.';

  @override
  String get authStatusNicknameTaken =>
      'That username is already taken. If you created this account, sign in instead.';

  @override
  String get authStatusUsernameInvalid =>
      'Username must be 3-20 characters and use only letters, digits and _ .';

  @override
  String get authStatusPasswordTooWeak =>
      'Password must be at least 8 characters and contain an uppercase letter, a lowercase letter and a digit.';

  @override
  String get authStatusInvalidCredentials => 'Wrong username or password.';

  @override
  String get authStatusWrongPassword => 'Wrong password.';

  @override
  String get authStatusTooManyAttempts =>
      'Too many attempts. Wait a while and try again.';

  @override
  String get authStatusServerError =>
      'The server could not handle that right now. Try again in a moment.';

  @override
  String get authStatusPhraseRejected => 'Name or phrase does not match.';

  @override
  String get authForgotPassword => 'Forgot password';

  @override
  String get authNewPasswordHint => 'New password';

  @override
  String get authRecoverSubmit => 'Set new password';

  @override
  String get authGoToLogin => 'Sign in instead';

  @override
  String get authUsernameRules => '3-20 characters: letters, digits and _ only';

  @override
  String get authPasswordRules =>
      'At least 8 characters, with an uppercase letter, a lowercase letter and a digit';

  @override
  String get identityAlertShowDetails => 'Details';

  @override
  String get identityAlertHideDetails => 'Hide details';

  @override
  String get peerIdentityMarkVerifiedAction => 'Fingerprints match';

  @override
  String get peerIdentityVerifyMenuAction => 'Verify security keys';

  @override
  String get peerIdentityFingerprintDialogTitle => 'Verify security keys';

  @override
  String peerIdentityFingerprintDialogDescription(String name) {
    return 'Compare with $name over another channel. They must match.';
  }

  @override
  String peerIdentityFingerprintPeerLabel(String name) {
    return '$name\'s fingerprint';
  }

  @override
  String get peerIdentityFingerprintNoStoredKey =>
      'No stored identity key is available for this contact.';

  @override
  String peerIdentityFingerprintChangedNotice(String name) {
    return '$name\'s key changed. Compare the NEW fingerprint.';
  }

  @override
  String peerIdentityFingerprintServedNotice(String name) {
    return '$name\'s key came from the server, unconfirmed by any message. Compare it out of band.';
  }

  @override
  String peerIdentityFingerprintNewLabel(String name) {
    return '$name\'s new fingerprint';
  }

  @override
  String get peerIdentityFingerprintPreviousLabel =>
      'Previously trusted fingerprint';

  @override
  String peerIdentityFingerprintOfferChanged(String name) {
    return '$name\'s key changed meanwhile. Compare again.';
  }

  @override
  String peerIdentityFingerprintUnchangedNotice(String name) {
    return '$name\'s key unchanged since you accepted it.';
  }

  @override
  String peerIdentityFingerprintOfferUnavailable(String name) {
    return 'Couldn\'t load $name\'s key. Check the connection.';
  }

  @override
  String peerIdentityChangedTimelineRow(String name) {
    return '$name\'s keys changed. Tap to verify.';
  }

  @override
  String get ownIdentityReplacedTitle => 'New encryption keys on your account';

  @override
  String get ownIdentityReplacedBody =>
      'A new sign-in changed the account keys. Not you? Change your password.';

  @override
  String get ownIdentityReplacedDismissAction => 'Got it';

  @override
  String get identityResetPendingTitle =>
      'Someone asked to reset your encryption keys';

  @override
  String identityResetPendingBody(String remaining) {
    return 'New keys in $remaining. Not you? Cancel now.';
  }

  @override
  String get identityResetCancelAction => 'Cancel it';

  @override
  String identityResetHoursLeft(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String identityResetMinutesLeft(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '1 minute',
      zero: 'under a minute',
    );
    return '$_temp0';
  }

  @override
  String get identityResetAnyMoment => 'any moment now';

  @override
  String get identityUploadLockedTitle =>
      'Your new encryption keys were not published';

  @override
  String get identityResetStartAction => 'Start reset';

  @override
  String get linkGateTitle => 'Link this device';

  @override
  String get linkGateBody =>
      'This device has no account keys. Link it from the primary device.';

  @override
  String get linkGateWaiting => 'Waiting for your main device…';

  @override
  String get linkGateStaleBody =>
      'Keys here are stale — linking replaces them.';

  @override
  String get linkGateNoPrimaryQuestion => 'No longer have your main device?';

  @override
  String get linkGateResetHint =>
      'Reset: new keys after 6 h, other devices signed out, old history lost.';

  @override
  String get linkGateResetPendingTitle => 'Key reset in progress';

  @override
  String linkGateResetPendingBody(String remaining) {
    return 'New keys in $remaining. Got the primary back? Cancel and link from there.';
  }

  @override
  String get linkGateResetPhraseTooNew =>
      'Recovery key is under 6 h old — full 6 h apply.';

  @override
  String get linkGateCheckingTitle => 'Checking this device\'s keys…';

  @override
  String get linkGateCheckingBody =>
      'Checking whether the account has keys elsewhere…';

  @override
  String get linkGateRetryAction => 'Try again';

  @override
  String get linkGateLogoutAction => 'Sign out';

  @override
  String get devicesInstallFirst =>
      'Install Umbra as an app first (menu → Add to Home Screen).';

  @override
  String get devicesInstallNudge =>
      'Install Umbra as an app — the browser may evict the keys.';

  @override
  String get devicesEnableLinkingWebWarningTitle =>
      'This browser becomes the main device';

  @override
  String get devicesEnableLinkingWebWarningBody =>
      'Only the primary device adds and removes devices.';

  @override
  String get devicesEnableLinkingConfirmAction => 'Enable';

  @override
  String get recoveryKeyTitle => 'Recovery key';

  @override
  String get recoveryKeySubtitle =>
      'Recover your password and account if you lose a device';

  @override
  String get recoveryKeyGenerateAction => 'Generate recovery key';

  @override
  String get recoveryKeyShownOnceWarning => 'Shown only once. Save them now.';

  @override
  String get recoveryKeyCopyAction => 'Copy words';

  @override
  String get recoveryKeyCopied => 'Recovery key copied';

  @override
  String get recoveryKeySavedAction => 'I saved it';

  @override
  String get recoveryKeySaved => 'Recovery key saved';

  @override
  String get recoveryKeySaveFailed =>
      'Key not saved. These words won\'t work — try again.';

  @override
  String get recoveryPhrasePromptTitle => 'Do you have a recovery key?';

  @override
  String get recoveryPhrasePromptBody =>
      'The 12 words cut the wait from 6 h to 1 h.';

  @override
  String get recoveryPhrasePromptHint => 'twelve words separated by spaces';

  @override
  String get recoveryPhraseMalformed =>
      'That does not look like a complete 12-word recovery key. Check for typos.';

  @override
  String get recoveryPhraseUseAction => 'Use recovery key';

  @override
  String get recoveryPhraseNoneAction => 'I don\'t have one';

  @override
  String get identityResetStarted =>
      'Reset started. Cancel any time before the countdown ends.';

  @override
  String get identityResetPhraseTooNew =>
      'Reset started. Key is under 6 h old, so the full 6 h apply.';

  @override
  String get identityResetAlreadyRunning =>
      'A reset is already running for this account. The countdown at the top of the screen shows how long is left.';

  @override
  String get identityResetCooldown =>
      'Reset cancelled recently. Next in up to 24 h. Someone else cancelling? Change password.';

  @override
  String get identityResetPhraseRejected =>
      'Those 12 words don\'t match this account.';

  @override
  String get identityResetPhraseLocked =>
      'Too many attempts. Try again in an hour.';

  @override
  String get identityResetNotEnrolled =>
      'No reset needed — just sign in on the new device.';

  @override
  String get identityResetNoAnswer => 'No answer. Nothing started — try again.';

  @override
  String get identityFingerprintUnavailable => 'Fingerprint unavailable.';

  @override
  String get blockUser => 'Block user';

  @override
  String get conversationDeletedByOther =>
      'Conversation deleted by the other user';

  @override
  String get noMessagesYet => 'No messages yet';

  @override
  String get cantMessageThisUser => 'You can\'t message this user';

  @override
  String get cantTypeToThisUser => 'You can\'t type to this user';

  @override
  String get recordingVoice => 'Recording voice…';

  @override
  String get typing => 'typing…';

  @override
  String get chatMessageHint => 'Type a message...';

  @override
  String get chatComposerSendTooltip => 'Send';

  @override
  String get chatComposerSendSemantics => 'Send message';

  @override
  String get chatComposerEmojiTooltip => 'Emoji';

  @override
  String get chatComposerEmojiSemantics => 'Open emoji picker';

  @override
  String get emojiPickerSemantics => 'Emoji picker';

  @override
  String get emojiPickerSearchHint => 'Search emoji';

  @override
  String get emojiPickerNoRecents => 'No recent emoji';

  @override
  String emojiPickerEmojiOptionSemantics(String emoji) {
    return 'Emoji $emoji';
  }

  @override
  String get chatDateToday => 'Today';

  @override
  String get chatDateYesterday => 'Yesterday';

  @override
  String get selectAConversation => 'Select a conversation';

  @override
  String get noConversationsYet => 'No chats yet';

  @override
  String get startNewChatToBegin => 'Start a new chat to begin';

  @override
  String get deleteConversationTitle => 'Delete Conversation?';

  @override
  String get deleteConversationConfirm =>
      'Deletes every message in this conversation.';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get voiceMessage => 'Voice message';

  @override
  String get image => 'Image';

  @override
  String get ping => 'Ping';

  @override
  String get attachment => 'Attachment';

  @override
  String get attachmentOptionDocument => 'Document';

  @override
  String get attachmentOptionGallery => 'Gallery';

  @override
  String get attachmentOptionCamera => 'Camera';

  @override
  String get attachmentOptionRecordVideo => 'Record video';

  @override
  String get attachmentOptionFile => 'File';

  @override
  String get actionTileDisappearingMessages => 'Disappearing messages';

  @override
  String get actionTileClearChat => 'Delete chat for both sides';

  @override
  String get clearChatHoldLabel => 'Keep holding — deletes for both';

  @override
  String get clearChatConfirmTitle => 'Delete this chat for both of you?';

  @override
  String get clearChatConfirmBody =>
      'Every message, photo, video and voice note in this chat is deleted from the server for you AND for the other person. This cannot be undone, and it includes messages from before this device was linked.';

  @override
  String get clearChatConfirmAction => 'Delete for both';

  @override
  String get disappearingTimerTitle => 'Disappearing messages';

  @override
  String get disappearingTimerExplainerLine1 =>
      'Messages are removed after they are read.';

  @override
  String get disappearingTimerExplainerLine2 =>
      'The countdown starts when someone opens the chat.';

  @override
  String get disappearingTimerExplainerLine3 =>
      'Only new messages use the timer you set here.';

  @override
  String get disappearingTimerRangeHint =>
      '5 seconds to 30 days, or all zeros to turn off';

  @override
  String get disappearingTimerSetTimer => 'Set timer';

  @override
  String get disappearingTimerTurnOff => 'Turn off';

  @override
  String disappearingTimerSummarySemantics(String summary) {
    return 'Selected duration: $summary';
  }

  @override
  String disappearingComposerBanner(String duration) {
    return 'Disappearing · $duration';
  }

  @override
  String disappearingComposerBannerSemantics(String duration) {
    return 'Disappearing messages, $duration';
  }

  @override
  String get conversationLastMessageEphemeralPreRead => 'Disappears after read';

  @override
  String conversationLastMessageEphemeralRemaining(String duration) {
    return 'Disappears in $duration';
  }

  @override
  String get disappearingTimerDaysLabel => 'Days';

  @override
  String get disappearingTimerHoursLabel => 'Hours';

  @override
  String get disappearingTimerMinutesLabel => 'Minutes';

  @override
  String get disappearingTimerSecondsLabel => 'Seconds';

  @override
  String get disappearingTimerOff => 'Off';

  @override
  String get disappearingTimerOutOfRange =>
      'Timer must be between 5 seconds and 30 days, or all zeros to turn off.';

  @override
  String disappearingTimerDays(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String disappearingTimerHours(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String disappearingTimerMinutes(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String disappearingTimerSeconds(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count seconds',
      one: '1 second',
    );
    return '$_temp0';
  }

  @override
  String get actionTileGif => 'GIF';

  @override
  String get actionTileAntiQuantumNote => 'Anti-Quantum Note';

  @override
  String get unknown => 'Unknown';

  @override
  String get noBlockedUsers => 'No blocked users';

  @override
  String get unblock => 'Unblock';

  @override
  String get removeFriendTitle => 'Remove Friend?';

  @override
  String removeFriendConfirm(String name) {
    return 'Remove $name from your contacts? This will delete all conversation history.';
  }

  @override
  String get remove => 'Remove';

  @override
  String get noContactsYet => 'No contacts yet';

  @override
  String get addFriendsToStart => 'Add friends to start chatting';

  @override
  String get contactNetworkLocalNode => 'LOCAL NODE';

  @override
  String get contactNetworkYouLocalNode => 'You, local node';

  @override
  String contactNetworkSemantic(num count) {
    return 'Contact network, $count contacts';
  }

  @override
  String contactNetworkNodes(String count) {
    return 'NODES $count';
  }

  @override
  String get contactNetworkShowList => 'List view';

  @override
  String get contactNetworkShowMap => 'Network view';

  @override
  String get contactNetworkOpenChatHint => 'Open chat';

  @override
  String get contactNetworkAddSlot => 'add';

  @override
  String get contactNetworkAddSlotSemantic => 'Add a contact';

  @override
  String contactNetworkPendingRequests(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count friend requests waiting',
      one: '1 friend request waiting',
    );
    return '$_temp0';
  }

  @override
  String get contactsSearchHint => 'Search contacts';

  @override
  String get contactsSearchNoResults => 'No matching contacts';

  @override
  String get block => 'Block';

  @override
  String get imageFailedToLoad => 'Image failed to load';

  @override
  String get unsupportedMessageType => 'Unsupported message type';

  @override
  String get resetPasswordDialogTitle => 'Reset Password';

  @override
  String get oldPassword => 'Old Password';

  @override
  String get newPassword => 'New Password';

  @override
  String get passwordRequired => 'Password is required';

  @override
  String get passwordMinLength => 'Password must be at least 8 characters';

  @override
  String get passwordMustContain =>
      'Password must contain uppercase, lowercase, and number';

  @override
  String get oldPasswordRequired => 'Old password is required';

  @override
  String get resetButton => 'Reset';

  @override
  String sessionEndedReason(String reason) {
    return 'signed out: $reason';
  }

  @override
  String get authTagline => 'Messages only two people can read';

  @override
  String get authLoginTab => 'LOGIN';

  @override
  String get authRegisterTab => 'REGISTER';

  @override
  String get authUsernameHint => 'Username';

  @override
  String get authUsernameRequired => 'Username is required';

  @override
  String get authPasswordHint => 'Password';

  @override
  String get authPasswordHintRegister => 'Password (min 8 chars)';

  @override
  String get authLoginButton => 'Login';

  @override
  String get authCreateAccountButton => 'Create Account';

  @override
  String get deleteAccountDialogTitle => 'Delete Account';

  @override
  String get deleteAccountWarning =>
      'This action is permanent and cannot be undone. All your messages and conversations will be deleted.';

  @override
  String get enterPasswordToConfirm => 'Enter password to confirm';

  @override
  String get gifNoResults => 'No GIFs found';

  @override
  String get gifSearchHint => 'Search GIFs...';

  @override
  String get antiQuantumNoteTitle => 'Anti-Quantum Note';

  @override
  String get antiQuantumNoteHint => 'Write your secret message...';

  @override
  String get antiQuantumNoteTtl1h => '1h';

  @override
  String get antiQuantumNoteTtl6h => '6h';

  @override
  String get antiQuantumNoteTtl12h => '12h';

  @override
  String get antiQuantumNoteTtl24h => '24h';

  @override
  String get antiQuantumNoteGenerateAndSend => '🔗 Generate & Send';

  @override
  String get antiQuantumNoteFooter =>
      'Encrypted client-side · Key never leaves your device';

  @override
  String get antiQuantumNoteSent => 'Anti-Quantum Note sent';

  @override
  String antiQuantumNoteSendFailed(String error) {
    return 'Failed to send note: $error';
  }

  @override
  String get antiQuantumNoteCardSubtitle => 'One-time read · Tap to open';

  @override
  String antiQuantumNoteCardCountdown(String time) {
    return 'Self-destructs in $time';
  }

  @override
  String get antiQuantumNoteCardDestroyed => 'This note has self-destructed';

  @override
  String get antiQuantumNoteBurnedTitle => 'Note destroyed';

  @override
  String get antiQuantumNoteBurnedSubtitle => 'it was read';

  @override
  String get antiQuantumNoteRevealWarning =>
      'You can read it once. Then it\'s gone for everyone.';

  @override
  String get antiQuantumNoteRevealConfirm => 'Reveal & destroy';

  @override
  String get antiQuantumNoteRevealLoading => 'Decrypting…';

  @override
  String get antiQuantumNoteRevealedHeader =>
      'Message revealed · now permanently destroyed';

  @override
  String get antiQuantumNoteRevealedFooter =>
      'This note has been deleted from the server. Only this screen still shows it.';

  @override
  String get antiQuantumNoteRevealClose => 'Close';

  @override
  String get antiQuantumNoteRevealRetry => 'Try again';

  @override
  String get antiQuantumNoteRevealDestroyedBody =>
      'This note has already been read and destroyed. Nothing can bring it back.';

  @override
  String get antiQuantumNoteRevealExpiredTitle => 'Note expired';

  @override
  String get antiQuantumNoteRevealExpiredBody =>
      'This note expired and destroyed itself before being read.';

  @override
  String get antiQuantumNoteRevealCorruptBody =>
      'The note was destroyed, but it could not be decrypted. The link may be damaged.';

  @override
  String get antiQuantumNoteRevealInvalidLinkTitle => 'Damaged link';

  @override
  String get antiQuantumNoteRevealInvalidLinkBody =>
      'This link is missing a valid decryption key. The note has not been destroyed.';

  @override
  String get antiQuantumNoteRevealNetworkErrorTitle => 'No connection';

  @override
  String get antiQuantumNoteRevealNetworkErrorBody =>
      'The server could not be reached. Check your connection and try again.';

  @override
  String get privacyAntiQuantumNoteTitle => 'Anti-Quantum Notes';

  @override
  String get privacyAntiQuantumNoteLead =>
      'Self-destructing notes with their own encryption.';

  @override
  String get privacyAntiQuantumNotePointDevice =>
      'Encrypted on your device; the server sees only ciphertext.';

  @override
  String get privacyAntiQuantumNotePointKey =>
      'The key sits after # in the link, which the server never sees.';

  @override
  String get privacyAntiQuantumNotePointOnce =>
      'A note can be revealed exactly once — then it is permanently deleted.';

  @override
  String get privacyAntiQuantumNotePointTimer =>
      'Unopened ones vanish after 1–24 h.';

  @override
  String get documentDownloaded => 'Document downloaded';

  @override
  String get documentDownloadFailed => 'Failed to download document';

  @override
  String get documentDownloadConfirmTitle => 'Download document?';

  @override
  String get documentDownloadConfirmMessage =>
      'Do you want to download this file?';

  @override
  String get download => 'Download';

  @override
  String get saveImage => 'Save image';

  @override
  String get copyImage => 'Copy image';

  @override
  String get imageSaved => 'Image saved';

  @override
  String get imageSaveFailed => 'Failed to save image';

  @override
  String get imageCopied => 'Image copied';

  @override
  String get imageCopyFailed => 'Failed to copy image';

  @override
  String get snackbarCouldNotReadFile => 'Could not read file';

  @override
  String get snackbarUploadingImage => 'Uploading image…';

  @override
  String get snackbarImageSent => 'Image sent!';

  @override
  String get snackbarUploadingDocument => 'Uploading document…';

  @override
  String get snackbarDocumentSent => 'Document sent!';

  @override
  String get snackbarNoActiveConversation => 'No active conversation';

  @override
  String get snackbarOpenConversationFirst => 'Open a conversation first';

  @override
  String get messageTooLong => 'Message is too long to send';

  @override
  String get snackbarChatHistoryDeleted => 'Chat deleted for both sides';

  @override
  String get snackbarFailedToSendImage => 'Failed to send image';

  @override
  String get snackbarMicrophonePermissionRequired =>
      'Microphone permission required';

  @override
  String get snackbarMicrophonePermissionDenied =>
      'Microphone permission denied';

  @override
  String get snackbarNoMicrophoneFound => 'No microphone found';

  @override
  String get snackbarVoiceRecordingRequiresSecureContext =>
      'Voice recording needs HTTPS or localhost. Use https:// or open from localhost.';

  @override
  String get snackbarFailedToStartRecording => 'Failed to start recording';

  @override
  String get snackbarVoiceRecordingCanceled => 'Voice recording canceled';

  @override
  String get voiceRecordingSendVoiceTooltip => 'Send voice message';

  @override
  String get voiceRecordingSendVoiceSemantics => 'Send voice message';

  @override
  String get voiceRecordingDiscard => 'Discard recording';

  @override
  String voiceRecordingSemanticsLabel(String time) {
    return 'Recording voice message, $time.';
  }

  @override
  String get snackbarFailedToReadRecording => 'Failed to read recording';

  @override
  String get snackbarFailedToSendVoiceMessage => 'Failed to send voice message';

  @override
  String get snackbarAudioNoLongerAvailable => 'Audio no longer available';

  @override
  String get snackbarFailedToLoadAudio => 'Failed to load audio';

  @override
  String get snackbarAllLocalHistoryDeleted =>
      'All messages stored on this device were permanently deleted';

  @override
  String get snackbarFailedToDeleteAllLocalHistory =>
      'Some messages could not be removed from this device. Try again.';

  @override
  String friendAcceptedYourRequest(String name) {
    return '$name accepted your friend request';
  }

  @override
  String get appearance => 'Appearance';

  @override
  String appearanceSummary(String theme, String background) {
    return '$theme · $background';
  }

  @override
  String get appearanceColorTheme => 'COLOR THEME';

  @override
  String get appearanceThemeLight => 'Alabaster';

  @override
  String get appearanceThemeTeal => 'Turquoise';

  @override
  String get appearanceThemeDark => 'Graphite';

  @override
  String get appearanceThemeBlue => 'Azure';

  @override
  String get appearanceThemeCosmic => 'Cosmos';

  @override
  String get themeOptionLight => 'Light warm ivory with ember accents';

  @override
  String get themeOptionDark => 'Dark neutral graphite with teal accents';

  @override
  String get themeOptionBlue => 'Deep dark blue with azure accents';

  @override
  String get themeOptionTealStone => 'Light cool stone with turquoise accents';

  @override
  String get themeOptionCosmic => 'Dark space with ice-blue light';

  @override
  String get appearanceChatBackground => 'CHAT BACKGROUND';

  @override
  String get appearanceBackgroundThemeDefault => 'Theme default';

  @override
  String get appearanceBackgroundThemeDefaultSubtitle =>
      'Follows the selected color theme';

  @override
  String get appearanceBackgroundThemeDefaultCosmicSubtitle =>
      'Animated starfield for Cosmic';

  @override
  String get appearanceBackgroundPlain => 'Plain';

  @override
  String get appearanceBackgroundPlainSubtitle => 'Solid themed chat surface';

  @override
  String get appearanceBackgroundGlyphs => 'Hieroglyphs';

  @override
  String get appearanceBackgroundGlyphsSubtitle => 'Temple-column pattern';

  @override
  String get appearanceBackgroundStarfield => 'Starfield';

  @override
  String get rotateDeviceTitle => 'Rotate your device';

  @override
  String get rotateDeviceMessage => 'Umbra works in portrait mode only.';

  @override
  String get messageActionReply => 'Reply';

  @override
  String get messageActionCopy => 'Copy';

  @override
  String get messageActionEdit => 'Edit';

  @override
  String get messageActionPin => 'Pin';

  @override
  String get messageActionDelete => 'Delete';

  @override
  String get messageDeleteDialogTitle => 'Delete message?';

  @override
  String get messageDeleteForMe => 'Delete for me';

  @override
  String get messageDeleteForEveryone => 'Delete for everyone';

  @override
  String get messageEditedLabel => 'edited';

  @override
  String get messageEditingTitle => 'Editing message';

  @override
  String get messagePinRequiresSentMessage =>
      'Wait until the message is sent before pinning';

  @override
  String get messageReactionMoreEmoji => 'More emoji reactions';

  @override
  String get messageReactionSelected => 'selected';

  @override
  String get messageReactionNotSelected => 'not selected';

  @override
  String messageReactionSemantics(Object emoji, Object state) {
    return 'Reaction $emoji, $state';
  }

  @override
  String messageReactionUnreadable(int count) {
    return 'Reaction not readable on this device ($count)';
  }

  @override
  String get snackbarReactionUnavailable =>
      'Reactions aren\'t ready on this device yet';

  @override
  String get snackbarPinnedMessageUnavailable =>
      'Message is no longer available';

  @override
  String get snackbarMessageCopied => 'Message copied';

  @override
  String get composerAttachmentRemoveTooltip => 'Remove attachment';

  @override
  String get snackbarPastedImageTooLarge => 'Image is too large (max 20 MB)';

  @override
  String get snackbarPastedImageUnsupported =>
      'This image type can\'t be pasted';

  @override
  String get snackbarPastedImageUnavailable =>
      'Couldn\'t read the pasted image';

  @override
  String get pinnedMessageUnpinTooltip => 'Unpin';

  @override
  String get pinnedMessageBannerSemantics => 'Pinned message';

  @override
  String get userCardAbout => 'About';

  @override
  String get userCardMyProfile => 'My profile';

  @override
  String get userCardEditAbout => 'Edit About';

  @override
  String get userCardAddPhoto => 'Add photo';

  @override
  String get userCardPhotoLimitReached => 'Photo limit reached';

  @override
  String get userCardSetMainPhoto => 'Set as main photo';

  @override
  String get userCardDeletePhoto => 'Delete this photo';

  @override
  String get userCardSave => 'Save';

  @override
  String get userCardCancel => 'Cancel';

  @override
  String get userCardBack => 'Back';

  @override
  String get userCardNotificationsOn => 'Notifications on';

  @override
  String get userCardMuteOneHour => 'Mute for 1 hour';

  @override
  String get userCardMuteEightHours => 'Mute for 8 hours';

  @override
  String get userCardMuteOneWeek => 'Mute for 1 week';

  @override
  String get userCardMuteForever => 'Mute forever';

  @override
  String get userCardMessage => 'Message';

  @override
  String get userCardMute => 'Mute';

  @override
  String get userCardMuted => 'Muted';

  @override
  String get userCardCopyTag => 'Copy tag';

  @override
  String get userCardManagePhotos => 'Manage photos';

  @override
  String userCardPhotoOfCount(Object index, Object count) {
    return 'Photo $index of $count';
  }

  @override
  String get userCardMainPhotoHint =>
      'This is your main photo — contacts see it in chats.';

  @override
  String get userCardAboutHint => 'A few words about you';

  @override
  String get userCardSharedMedia => 'Shared media';

  @override
  String get userCardDragReorderHint =>
      'Hold and drag to reorder — the first photo is your main photo.';

  @override
  String get settingsChatBackground => 'Chat background';

  @override
  String get userCardCopyHandle => 'Copy username and tag';

  @override
  String userCardCopiedHandle(Object handle) {
    return 'Copied $handle';
  }

  @override
  String get userCardNotificationsMuted => 'Notifications muted';

  @override
  String userCardBlockTitle(Object handle) {
    return 'Block $handle?';
  }

  @override
  String get userCardBlockConfirm =>
      'You will no longer be able to message this contact.';

  @override
  String get userCardDeletePhotoTitle => 'Delete photo?';

  @override
  String get userCardDeletePhotoConfirm =>
      'This permanently deletes this profile photo.';

  @override
  String get userCardSafety => 'Safety';

  @override
  String get userCardRemoveContact => 'Remove contact';

  @override
  String get messageReadMore => 'Read more';

  @override
  String get messageShowLess => 'Show less';

  @override
  String get chatPickerTitle => 'Choose a friend';

  @override
  String get chatPickerSubtitle => 'Pick a node to start chatting';

  @override
  String get chatPickerEmptyTitle => 'No friends yet';

  @override
  String get chatPickerEmptyDescription => 'Add a friend to start a chat.';

  @override
  String get chatPickerOpenTooltip => 'New chat';

  @override
  String get chatPickerInviteButton => 'Invite someone';

  @override
  String get videoMessage => 'Video';

  @override
  String videoTooLarge(String size) {
    return 'Video is too large ($size MB, max 20 MB)';
  }

  @override
  String videoTooLong(String duration) {
    return 'Video is too long ($duration, max 3 minutes)';
  }

  @override
  String get videoCompressing => 'Compressing video…';

  @override
  String get videoUnsupportedFormat => 'Unsupported video format (MP4 only)';

  @override
  String get videoFailedToLoad => 'Video failed to load';

  @override
  String get videoStillSending => 'Still sending…';

  @override
  String get videoUnmute => 'Unmute';

  @override
  String get videoMute => 'Mute';

  @override
  String get videoSenderYou => 'You';

  @override
  String get settingsAutoplayVideos => 'Autoplay videos';

  @override
  String get settingsAutoplayVideosSubtitle =>
      'Videos in chats play muted while they are on screen';

  @override
  String get attachmentUnsupportedFileType => 'Unsupported file type';

  @override
  String get chatScrollToBottomSemantics => 'Scroll to newest messages';

  @override
  String get avatarOpenProfileSemantics => 'Open profile';

  @override
  String get passcodeLock => 'Passcode Lock';

  @override
  String get passcodeStateOn => 'On';

  @override
  String get passcodeStateOff => 'Off';

  @override
  String get passcodeIntro =>
      'You can add a Passcode Lock to Umbra to make your account more private.';

  @override
  String get passcodeTurnOn => 'Turn Passcode Lock On';

  @override
  String get passcodeTurnOff => 'Turn Passcode Lock Off';

  @override
  String get passcodeChange => 'Change Passcode';

  @override
  String get passcodeAutoLock => 'Auto-Lock';

  @override
  String get passcodeAutoLockImmediately => 'Immediately';

  @override
  String get passcodeAutoLockMinute => 'After 1 minute';

  @override
  String get passcodeAutoLockFiveMinutes => 'After 5 minutes';

  @override
  String get passcodeAutoLockHour => 'After 1 hour';

  @override
  String get passcodeEnterTitle => 'Enter passcode';

  @override
  String get passcodeSetTitle => 'Set passcode';

  @override
  String get passcodeRepeatTitle => 'Re-enter passcode';

  @override
  String get passcodeCurrentTitle => 'Enter current passcode';

  @override
  String get passcodeOptions => 'Passcode Options';

  @override
  String get passcodeOptionCustom => 'Custom Alphanumeric Passcode';

  @override
  String get passcodeOptionSixDigits => '6-Digit Numeric Code';

  @override
  String get passcodeOptionFourDigits => '4-Digit Numeric Code';

  @override
  String get passcodeConfirmAction => 'Confirm';

  @override
  String get passcodeCustomHint => 'Passcode';

  @override
  String get passcodeWrong => 'Wrong passcode. Try again.';

  @override
  String get passcodeMismatch => 'The codes did not match. Start again.';

  @override
  String get passcodeTooShort => 'Use at least 4 characters.';

  @override
  String passcodeBlocked(int seconds) {
    return 'Too many attempts. Try again in ${seconds}s.';
  }

  @override
  String get passcodeUnavailable =>
      'This device could not secure the passcode.';

  @override
  String get passcodeCredentialLoading =>
      'Reading this device\'s secure storage…';

  @override
  String get passcodeForgot => 'Forgot your passcode?';

  @override
  String get passcodeNoRecovery => 'A forgotten passcode cannot be recovered.';

  @override
  String get passcodeEraseWarning =>
      'Erases the app\'s data. Messages only here are gone for good.';

  @override
  String get passcodeEraseConfirmWord => 'ERASE';

  @override
  String passcodeEraseConfirmHint(String word) {
    return 'Type $word to confirm';
  }

  @override
  String get passcodeEraseAction => 'Erase data and sign out';

  @override
  String get passcodeErasing => 'Erasing…';

  @override
  String get passcodeErasePartial => 'Not everything was erased. Try again.';

  @override
  String passcodeAttemptsLeft(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count attempts left before a cooldown',
      one: '1 attempt left before a cooldown',
    );
    return '$_temp0';
  }

  @override
  String get passcodeLockNowTooltip => 'Lock app';

  @override
  String get passcodeSetUpTooltip => 'Set up Passcode Lock';

  @override
  String get passcodeNote =>
      'Forget it and the only way out is erasing this app\'s data.';

  @override
  String get passcodeScopeNoteDevice =>
      'Locks the app on this device. Never sent to the server.';

  @override
  String get passcodeScopeNoteBrowser =>
      'Encrypts this browser\'s keys. Never sent to the server.';

  @override
  String get passcodeTooWeakForKeys =>
      'Custom code: 6+ characters, not digits only.';

  @override
  String get passcodeEraseWarningEnrolled =>
      'Erases the app\'s data. Then restore with the phrase, another device, or a reset.';

  @override
  String get linkScanAction => 'Scan code';

  @override
  String get linkShowCodeAction => 'Show code';

  @override
  String get linkScanHint =>
      'Point the camera at the QR code on the other device.';

  @override
  String get linkScanCameraDenied =>
      'Camera access denied. Type the code instead.';

  @override
  String get linkScanUnsupported =>
      'This browser cannot scan. Type the code instead.';

  @override
  String get linkEnterCodeManually => 'Type the code';

  @override
  String get linkNewCodeLabel => 'Code from the main device';

  @override
  String get linkPrimaryShowCodeExplainer =>
      'Scan this code with the new device.';

  @override
  String get linkGateScanBody =>
      'Scan the primary\'s code, or show it this one.';

  @override
  String get recoveryKeyBackupExplainer =>
      'These 12 words recover your password and the account after losing a device. Whoever has them owns it. Shown once.';

  @override
  String get recoveryKeyConfirmTitle => 'Confirm you saved the words';

  @override
  String recoveryKeyConfirmPrompt(int n) {
    return 'Enter word #$n';
  }

  @override
  String get recoveryKeyConfirmMismatch =>
      'That is not the word. Check what you saved.';

  @override
  String get recoveryKeyConfirmAction => 'Confirm';

  @override
  String get recoveryKeyLaterAction => 'Later';

  @override
  String get recoveryKeyReplacesExisting =>
      'You already have a phrase. New words replace it — the old ones stop working.';

  @override
  String get backupNudgeTitle => 'Secure your account — create 12 words';

  @override
  String get recoveryKeyRequiredForLinking =>
      'Linking requires a recovery phrase — you\'ll create it next.';

  @override
  String get linkGateRestoreAction => 'I have my recovery phrase';

  @override
  String get linkGateRestoreTitle => 'Restore from recovery phrase';

  @override
  String get linkGateRestoreBody =>
      'Enter the 12 words. This device becomes primary.';

  @override
  String get linkGateRestoring => 'Restoring keys…';

  @override
  String get linkGateRestoreWrongPhrase =>
      'The phrase does not match this account\'s key backup.';

  @override
  String get linkGateRestoreNoBackup =>
      'No key backup. Link from the primary or reset.';

  @override
  String get linkGateRestoreFailed => 'Restore failed. Try again.';

  @override
  String get linkGateRestoreDone => 'Account restored.';

  @override
  String get devicesBackupMissing => 'No key backup. Create a recovery phrase.';

  @override
  String get devicesCreateBackupAction => 'Create recovery phrase';

  @override
  String get deviceRevokedRestoredNotice =>
      'Account restored on another device. Link this one again.';

  @override
  String peerIdentityChangedSystemLine(String name) {
    return '$name: new device or browser — keys updated.';
  }

  @override
  String get settingsKeyChangeWarnings => 'Warn when a contact\'s keys change';

  @override
  String get settingsKeyChangeWarningsSubtitle =>
      'By default new keys are accepted and a short note appears in the chat.';

  @override
  String get devicesRenameAction => 'Rename';

  @override
  String get devicesRenameTitle => 'Device name';

  @override
  String get devicesRenameHint => 'e.g. Ann\'s phone';

  @override
  String get devicesRenameSave => 'Save';

  @override
  String get devicesRenameClearHint => 'An empty field removes the name.';

  @override
  String get devicesRenameFailed => 'Could not rename that device. Try again.';

  @override
  String get devicesRenameNotStorable =>
      'That name contains characters we cannot store. Type it in instead of pasting it.';

  @override
  String get updateAvailableTitle => 'New app version';

  @override
  String updateAvailableBody(String version) {
    return 'Version $version is available. Download and install it on this phone — your messages and keys are kept. Do not uninstall the app.';
  }

  @override
  String get updateAvailableDownload => 'Download';

  @override
  String get updateAvailableLater => 'Later';
}
