// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Polish (`pl`).
class AppLocalizationsPl extends AppLocalizations {
  AppLocalizationsPl([String locale = 'pl']) : super(locale);

  @override
  String get settings => 'Ustawienia';

  @override
  String get theme => 'Motyw';

  @override
  String get language => 'Język';

  @override
  String get languagePolish => 'Polski';

  @override
  String get languageEnglish => 'Angielski';

  @override
  String get privacyAndSafety => 'Prywatność i bezpieczeństwo';

  @override
  String get blocked => 'Zablokowani';

  @override
  String get devices => 'Urządzenia';

  @override
  String get webPushEnableTitle => 'Włącz powiadomienia push';

  @override
  String get webPushEnableSubtitle =>
      'Na iOS wymagane po dodaniu aplikacji do ekranu głównego';

  @override
  String get webPushEnabled => 'Powiadomienia push włączone';

  @override
  String get webPushPermissionDenied => 'Odrzucono uprawnienie do powiadomień';

  @override
  String get webPushInstallRequired =>
      'Najpierw dodaj Umbra do ekranu głównego (Safari -> Udostępnij -> Do ekranu początkowego)';

  @override
  String get webPushNotSupported =>
      'Powiadomienia push nie są obsługiwane w tej przeglądarce/sesji';

  @override
  String get webPushNoChanges => 'Powiadomienia push są już włączone';

  @override
  String get webPushEnableFailed => 'Nie udało się włączyć powiadomień push';

  @override
  String get resetPassword => 'Zmień hasło';

  @override
  String get deleteAccount => 'Usuń konto';

  @override
  String get logout => 'Wyloguj';

  @override
  String get uninstallWarning =>
      'Nie odinstalowuj i nie czyść danych — historia zniknie.';

  @override
  String get uninstallWarningTitle => 'Odinstalowanie lub czyszczenie danych';

  @override
  String get chat => 'Czaty';

  @override
  String get contacts => 'Kontakty';

  @override
  String get uploadFailed => 'Nie udało się przesłać';

  @override
  String get passwordUpdatedSuccessfully => 'Hasło zostało zmienione';

  @override
  String get passwordResetFailed => 'Nie udało się zmienić hasła';

  @override
  String get accountDeletionFailed => 'Nie udało się usunąć konta';

  @override
  String get devicesLoading => 'Ładowanie…';

  @override
  String get devicesExplainer =>
      'Nowe urządzenie dodasz tylko z urządzenia głównego.';

  @override
  String get devicesLinkedDeviceNote =>
      'To urządzenie jest połączone. Nowe urządzenia dodaje się z urządzenia głównego.';

  @override
  String get devicesNotEnrolled =>
      'Łączenie urządzeń nie jest jeszcze włączone dla tego konta.';

  @override
  String get devicesEnableLinking => 'Włącz łączenie';

  @override
  String get devicesLinkADevice => 'Połącz urządzenie';

  @override
  String get devicesLinkThisDevice => 'Połącz to urządzenie';

  @override
  String get devicesAlreadyEnrolled =>
      'Łączenie włączono na innym urządzeniu. Dodawaj stamtąd.';

  @override
  String get devicesEnrollFailed =>
      'Nie udało się włączyć łączenia. Spróbuj ponownie.';

  @override
  String get devicesChainInvalid =>
      'Nie można zweryfikować listy urządzeń. Spróbuj ponownie później.';

  @override
  String get devicesRevokedBadge => 'cofnięte';

  @override
  String devicesRevokedSection(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Cofnięte urządzenia ($count)',
      one: 'Cofnięte urządzenie (1)',
    );
    return '$_temp0';
  }

  @override
  String get devicesRevokeAction => 'Usuń urządzenie';

  @override
  String get devicesRevokeTitle => 'Usunąć to urządzenie?';

  @override
  String get devicesRevokeExplainer =>
      'Zostanie wylogowane. Jego wiadomości zostają.';

  @override
  String get devicesRevokeFailed =>
      'Nie udało się usunąć tego urządzenia. Spróbuj ponownie.';

  @override
  String get deviceRevokedNotice =>
      'To urządzenie usunięto z konta. Zaloguj się i połącz je ponownie.';

  @override
  String get deviceMismatchTitle => 'To urządzenie zostało usunięte z konta';

  @override
  String get deviceMismatchBody =>
      'Klucze tego urządzenia zostały unieważnione. Połącz je ponownie z drugiego urządzenia.';

  @override
  String get deviceMismatchAction => 'Połącz to urządzenie';

  @override
  String get devicesPrimaryBadge => 'główne';

  @override
  String get devicesThisDeviceKeyless =>
      'To urządzenie nie ma jeszcze kluczy. Połącz je ze swoim głównym urządzeniem.';

  @override
  String get linkPrimaryTitle => 'Połącz urządzenie';

  @override
  String get linkPrimaryExplainer =>
      'Na nowym urządzeniu wybierz „Połącz to urządzenie”, a potem wpisz tutaj wyświetlony kod.';

  @override
  String get linkPrimaryCodeLabel => 'Kod z nowego urządzenia';

  @override
  String get linkPrimaryContinue => 'Dalej';

  @override
  String get linkSasHeading => 'Porównaj kody';

  @override
  String get linkSasExplainer =>
      'Oba urządzenia muszą pokazywać ten sam kod. Zatwierdź tylko wtedy, gdy są identyczne.';

  @override
  String get linkApprove => 'Zatwierdź';

  @override
  String get linkCancel => 'Anuluj';

  @override
  String get linkWaitingForDevice => 'Czekam na nowe urządzenie…';

  @override
  String get linkPrimaryDone => 'Urządzenie zostało połączone.';

  @override
  String get linkInvalidCode =>
      'Nieprawidłowy kod. Przepisz go dokładnie z nowego urządzenia.';

  @override
  String get linkNoDak =>
      'Łączyć można tylko z urządzenia, które włączyło łączenie.';

  @override
  String get linkFailed => 'Łączenie nie powiodło się';

  @override
  String get linkStaleVersionRetry =>
      'Lista urządzeń zmieniła się w trakcie — podpisuję ponownie…';

  @override
  String get linkNewTitle => 'Połącz to urządzenie';

  @override
  String get linkNewExplainer =>
      'Na urządzeniu głównym: Połącz urządzenie → zeskanuj lub wpisz ten kod.';

  @override
  String get linkNewWaitingHello => 'Czekam na główne urządzenie…';

  @override
  String get linkNewCopy => 'Skopiuj kod';

  @override
  String get linkNewCopied => 'Kod skopiowany';

  @override
  String get linkNewCompleting => 'Łączenie…';

  @override
  String get linkNewRebinding => 'Przełączam sesję na nowe urządzenie…';

  @override
  String get linkNewDone => 'To urządzenie jest połączone i gotowe.';

  @override
  String get linkNewAborted => 'Łączenie przerwane';

  @override
  String get linkNewRetry => 'Spróbuj ponownie';

  @override
  String get linkAbortReasonExpired => 'Kod wygasł.';

  @override
  String get linkAbortReasonCancelled =>
      'Łączenie anulowano na drugim urządzeniu.';

  @override
  String get linkAbortReasonBadBlob =>
      'Weryfikacja danych nie powiodła się. Klucze zostały usunięte z tego urządzenia.';

  @override
  String get settingsAppVersion => 'Wersja aplikacji';

  @override
  String get settingsAboutFireplace => 'O projekcie';

  @override
  String get settingsSectionPreferences => 'PREFERENCJE';

  @override
  String get settingsSectionSecurity => 'BEZPIECZEŃSTWO';

  @override
  String get settingsSectionSession => 'SESJA';

  @override
  String get privacySafetyTitle => 'Prywatność i bezpieczeństwo';

  @override
  String get e2eEncryptionEnabled => 'Szyfrowanie end-to-end jest włączone';

  @override
  String get e2eEncryptionDescription =>
      'Szyfrowanie Signal. Treść widzisz tylko Ty i odbiorca.';

  @override
  String get yourEncryptionKeys => 'Twoje klucze szyfrowania';

  @override
  String get yourEncryptionKeysDescription =>
      'Klucze są tylko na tym urządzeniu. Bez kopii nie da się ich odzyskać.';

  @override
  String get singleDeviceEncryption => 'Szyfrowanie na jednym urządzeniu';

  @override
  String get singleDeviceEncryptionDescription =>
      'Każde urządzenie ma własne klucze.';

  @override
  String get webKeyStorage => 'Przeglądarka: przechowywanie kluczy';

  @override
  String get webKeyStorageDescription =>
      'W przeglądarce klucze chroni tylko blokada kodem.';

  @override
  String get whatIsEncrypted => 'Co jest szyfrowane';

  @override
  String get whatIsEncryptedDescription =>
      'Tekst, zdjęcia, głos, linki — wszystko end-to-end.';

  @override
  String get serverStoresMetadata => 'Co przechowuje serwer (metadane)';

  @override
  String get serverStoresMetadataDescription =>
      'Serwer widzi kto, z kim i kiedy. Nigdy treść.';

  @override
  String get deleteAllLocalHistoryTitle =>
      'Usuń wszystkie wiadomości z tego urządzenia';

  @override
  String get deleteAllLocalHistoryDescription =>
      'Usuwa wiadomości z tego urządzenia. Konto i klucze zostają.';

  @override
  String get deleteAllLocalHistoryButton =>
      'Usuń trwale wszystkie lokalne wiadomości';

  @override
  String get deleteAllLocalHistoryDialogTitle =>
      'Trwale usunąć wszystkie lokalne wiadomości?';

  @override
  String get deleteAllLocalHistoryDialogBody =>
      'Wiadomości z tego urządzenia znikną na zawsze.';

  @override
  String get deleteAllLocalHistoryConfirm => 'Usuń trwale';

  @override
  String get yourIdentityFingerprint => 'Twój odcisk tożsamości';

  @override
  String get shareFingerprintHint =>
      'To unikalna reprezentacja Twojego klucza szyfrowania.';

  @override
  String get invitations => 'Zaproszenia';

  @override
  String get invitationsWaitingForYou => 'Czeka na Ciebie';

  @override
  String get invitationsSent => 'Wysłane';

  @override
  String get invitationsNothingWaiting => 'Nic na Ciebie nie czeka';

  @override
  String get invitationsNoneSent => 'Brak wysłanych zaproszeń';

  @override
  String get inviteByHandleHint =>
      'Zaproś kogoś po username#tag. Swój #tag znajdziesz w Ustawieniach przy nicku.';

  @override
  String get usernameTagPlaceholder => 'username#1234';

  @override
  String get sendInvitation => 'Wyślij zaproszenie';

  @override
  String get invitationFindUser => 'Znajdź użytkownika';

  @override
  String get userNotFound => 'Nie znaleziono użytkownika';

  @override
  String get invitationWantsToConnect => 'Chce się połączyć';

  @override
  String get invitationWaitingForResponse => 'Czeka na odpowiedź';

  @override
  String get invitationAccepted => 'Zaproszenie zaakceptowane';

  @override
  String get invitationChatReady => 'Czat gotowy';

  @override
  String get invitationChatNeedsRetry => 'Czat wymaga ponowienia';

  @override
  String get invitationOpenChat => 'Otwórz czat';

  @override
  String get invitationCreateChat => 'Utwórz czat';

  @override
  String get invitationDone => 'Gotowe';

  @override
  String get invitationDecline => 'Odrzuć';

  @override
  String get accept => 'Zaakceptuj';

  @override
  String get invitationStatusPending => 'Oczekuje';

  @override
  String get invitationSendFailed => 'Nie udało się wysłać zaproszenia';

  @override
  String get invitationAcceptFailed => 'Nie udało się zaakceptować zaproszenia';

  @override
  String get invitationDeclineFailed => 'Nie udało się odrzucić zaproszenia';

  @override
  String get invitationChatSetupFailed => 'Nie udało się utworzyć czatu';

  @override
  String get invitationFailedUserNotFound => 'Ten użytkownik już nie istnieje';

  @override
  String get invitationFailedSelf => 'Nie możesz zaprosić samego siebie';

  @override
  String get invitationFailedBlocked => 'Nie możesz zaprosić tego użytkownika';

  @override
  String get invitationFailedAlreadyFriends => 'Już jesteście połączeni';

  @override
  String get invitationFailedDuplicate => 'Zaproszenie zostało już wysłane';

  @override
  String get invitationFailedInvalidPayload =>
      'Coś było nie tak z tym żądaniem';

  @override
  String get invitationFailedNotFriends =>
      'Nie jesteś połączony z tym użytkownikiem';

  @override
  String invitationSemanticIncoming(String name) {
    return '$name, otrzymane zaproszenie, chce się połączyć';
  }

  @override
  String invitationSemanticOutgoing(String name) {
    return '$name, wysłane zaproszenie, czeka na odpowiedź';
  }

  @override
  String invitationSemanticAcceptedReady(String name) {
    return '$name, zaproszenie zaakceptowane, czat gotowy';
  }

  @override
  String invitationSemanticAcceptedNotReady(String name) {
    return '$name, zaproszenie zaakceptowane, czat wymaga ponowienia';
  }

  @override
  String get encryptedMessage => 'Wiadomość zaszyfrowana';

  @override
  String get decryptingMessage => 'Odszyfrowywanie…';

  @override
  String get messageNoLongerStoredOnThisDevice =>
      'Ta wiadomość nie jest już przechowywana na tym urządzeniu.';

  @override
  String get messageUnreadableOnThisDevice =>
      'Nie można odczytać tej wiadomości na tym urządzeniu.';

  @override
  String get messageUnreadableReasonKeysGone =>
      'Klucze zniknęły — reinstalacja ich nie przywróci.';

  @override
  String get messageUnreadableReasonOwnCopyGone =>
      'Twoja jedyna kopia była na urządzeniu wysyłającym.';

  @override
  String get historyBeforeDeviceLinked =>
      'Historia sprzed połączenia tego urządzenia';

  @override
  String get devicesSyncingNote => 'Synchronizowanie urządzeń…';

  @override
  String get encryptionNotInitialized => 'Szyfrowanie niezainicjowane';

  @override
  String get identityDamagedTitle =>
      'Brak kluczy szyfrowania na tym urządzeniu';

  @override
  String get messageRetrySend => 'Ponów';

  @override
  String get messageSendBlockedKeysChanged =>
      'Nie wysłano: klucze bezpieczeństwa tego kontaktu się zmieniły. Otwórz czerwone ostrzeżenie w tym czacie i porównajcie odciski, a potem ponów.';

  @override
  String get authStatusSavedSessionUnreadable =>
      'Nie udało się odczytać sesji. Uruchom aplikację ponownie.';

  @override
  String get authStatusRegisterSucceeded =>
      'Konto utworzone. Zaloguj się, aby kontynuować.';

  @override
  String get authStatusServerUnreachable =>
      'Brak połączenia. Spróbuj ponownie.';

  @override
  String get authStatusUnexpectedError =>
      'Coś poszło nie tak. Spróbuj ponownie.';

  @override
  String get authStatusNicknameTaken =>
      'Ta nazwa użytkownika jest już zajęta. Jeśli to Ty założyłeś to konto, zaloguj się.';

  @override
  String get authStatusUsernameInvalid =>
      'Nazwa użytkownika musi mieć 3-20 znaków i zawierać tylko litery, cyfry i _ .';

  @override
  String get authStatusPasswordTooWeak =>
      'Hasło musi mieć co najmniej 8 znaków oraz zawierać wielką literę, małą literę i cyfrę.';

  @override
  String get authStatusInvalidCredentials =>
      'Nieprawidłowa nazwa użytkownika lub hasło.';

  @override
  String get authStatusWrongPassword => 'Nieprawidłowe hasło.';

  @override
  String get authStatusTooManyAttempts =>
      'Zbyt wiele prób. Odczekaj chwilę i spróbuj ponownie.';

  @override
  String get authStatusServerError =>
      'Serwer nie mógł tego teraz obsłużyć. Spróbuj za chwilę.';

  @override
  String get authStatusPhraseRejected => 'Nazwa lub fraza nie pasuje.';

  @override
  String get authForgotPassword => 'Nie pamiętam hasła';

  @override
  String get authNewPasswordHint => 'Nowe hasło';

  @override
  String get authRecoverSubmit => 'Ustaw nowe hasło';

  @override
  String get authGoToLogin => 'Przejdź do logowania';

  @override
  String get authUsernameRules => '3-20 znaków: tylko litery, cyfry i _';

  @override
  String get authPasswordRules =>
      'Co najmniej 8 znaków, w tym wielka litera, mała litera i cyfra';

  @override
  String get identityAlertShowDetails => 'Szczegóły';

  @override
  String get identityAlertHideDetails => 'Ukryj szczegóły';

  @override
  String get peerIdentityMarkVerifiedAction => 'Odciski się zgadzają';

  @override
  String get peerIdentityVerifyMenuAction => 'Zweryfikuj klucze bezpieczeństwa';

  @override
  String get peerIdentityFingerprintDialogTitle =>
      'Zweryfikuj klucze bezpieczeństwa';

  @override
  String peerIdentityFingerprintDialogDescription(String name) {
    return 'Porównaj z $name innym kanałem. Muszą się zgadzać.';
  }

  @override
  String peerIdentityFingerprintPeerLabel(String name) {
    return 'Odcisk tożsamości użytkownika $name';
  }

  @override
  String get peerIdentityFingerprintNoStoredKey =>
      'Brak zapisanego klucza tożsamości dla tego kontaktu.';

  @override
  String peerIdentityFingerprintChangedNotice(String name) {
    return 'Klucz $name się zmienił. Porównaj NOWY odcisk.';
  }

  @override
  String peerIdentityFingerprintServedNotice(String name) {
    return 'Klucz $name z serwera, niepotwierdzony wiadomością. Porównaj go innym kanałem.';
  }

  @override
  String peerIdentityFingerprintNewLabel(String name) {
    return 'Nowy odcisk tożsamości użytkownika $name';
  }

  @override
  String get peerIdentityFingerprintPreviousLabel =>
      'Poprzednio zaufany odcisk';

  @override
  String peerIdentityFingerprintOfferChanged(String name) {
    return 'Klucz $name zmienił się w trakcie. Porównaj ponownie.';
  }

  @override
  String peerIdentityFingerprintUnchangedNotice(String name) {
    return 'Klucz $name bez zmian od Twojej akceptacji.';
  }

  @override
  String peerIdentityFingerprintOfferUnavailable(String name) {
    return 'Nie udało się pobrać klucza $name. Sprawdź połączenie.';
  }

  @override
  String peerIdentityChangedTimelineRow(String name) {
    return 'Klucze $name się zmieniły. Dotknij, aby sprawdzić.';
  }

  @override
  String get ownIdentityReplacedTitle =>
      'Nowe klucze szyfrowania na Twoim koncie';

  @override
  String get ownIdentityReplacedBody =>
      'Nowe logowanie zmieniło klucze konta. To nie Ty? Zmień hasło.';

  @override
  String get ownIdentityReplacedDismissAction => 'Rozumiem';

  @override
  String get identityResetPendingTitle =>
      'Ktoś poprosił o zresetowanie Twoich kluczy szyfrowania';

  @override
  String identityResetPendingBody(String remaining) {
    return 'Za $remaining konto dostanie nowe klucze. To nie Ty? Anuluj teraz.';
  }

  @override
  String get identityResetCancelAction => 'Anuluj';

  @override
  String identityResetHoursLeft(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours godzin',
      few: '$hours godziny',
      one: '1 godzinę',
    );
    return '$_temp0';
  }

  @override
  String identityResetMinutesLeft(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minut',
      few: '$minutes minuty',
      one: '1 minutę',
      zero: 'niecałą minutę',
    );
    return '$_temp0';
  }

  @override
  String get identityResetAnyMoment => 'lada chwila';

  @override
  String get identityUploadLockedTitle =>
      'Twoje nowe klucze szyfrowania nie zostały opublikowane';

  @override
  String get identityResetStartAction => 'Rozpocznij reset';

  @override
  String get linkGateTitle => 'Połącz to urządzenie';

  @override
  String get linkGateBody =>
      'To urządzenie nie ma kluczy konta. Połącz je z urządzenia głównego.';

  @override
  String get linkGateWaiting => 'Czekam na urządzenie główne…';

  @override
  String get linkGateStaleBody =>
      'Klucze tutaj są nieaktualne — połączenie je zastąpi.';

  @override
  String get linkGateNoPrimaryQuestion => 'Nie masz już urządzenia głównego?';

  @override
  String get linkGateResetHint =>
      'Reset: nowe klucze po 6 h, inne urządzenia wylogowane, stara historia przepada.';

  @override
  String get linkGateResetPendingTitle => 'Reset kluczy w toku';

  @override
  String linkGateResetPendingBody(String remaining) {
    return 'Za $remaining konto dostanie nowe klucze. Odzyskałeś urządzenie główne? Anuluj i połącz stamtąd.';
  }

  @override
  String get linkGateResetPhraseTooNew =>
      'Klucz odzyskiwania ma mniej niż 6 h — obowiązuje pełne 6 h.';

  @override
  String get linkGateCheckingTitle => 'Sprawdzam klucze tego urządzenia…';

  @override
  String get linkGateCheckingBody =>
      'Sprawdzam, czy konto ma klucze na innym urządzeniu…';

  @override
  String get linkGateRetryAction => 'Spróbuj ponownie';

  @override
  String get linkGateLogoutAction => 'Wyloguj';

  @override
  String get devicesInstallFirst =>
      'Najpierw zainstaluj Umbra jako aplikację (menu → Dodaj do ekranu).';

  @override
  String get devicesInstallNudge =>
      'Zainstaluj Umbra jako aplikację — przeglądarka może usunąć klucze.';

  @override
  String get devicesEnableLinkingWebWarningTitle =>
      'Ta przeglądarka stanie się urządzeniem głównym';

  @override
  String get devicesEnableLinkingWebWarningBody =>
      'Tylko urządzenie główne dodaje i usuwa urządzenia.';

  @override
  String get devicesEnableLinkingConfirmAction => 'Włącz';

  @override
  String get recoveryKeyTitle => 'Klucz odzyskiwania';

  @override
  String get recoveryKeySubtitle =>
      'Odzyskasz hasło i konto, gdy stracisz urządzenie';

  @override
  String get recoveryKeyGenerateAction => 'Wygeneruj klucz odzyskiwania';

  @override
  String get recoveryKeyShownOnceWarning =>
      'Pokazujemy je tylko raz. Zapisz teraz.';

  @override
  String get recoveryKeyCopyAction => 'Kopiuj słowa';

  @override
  String get recoveryKeyCopied => 'Skopiowano klucz odzyskiwania';

  @override
  String get recoveryKeySavedAction => 'Zapisałem/am';

  @override
  String get recoveryKeySaved => 'Zapisano klucz odzyskiwania';

  @override
  String get recoveryKeySaveFailed =>
      'Nie zapisano klucza. Te słowa nie działają — spróbuj ponownie.';

  @override
  String get recoveryPhrasePromptTitle => 'Masz klucz odzyskiwania?';

  @override
  String get recoveryPhrasePromptBody =>
      '12 słów skraca oczekiwanie z 6 h do 1 h.';

  @override
  String get recoveryPhrasePromptHint => 'dwanaście słów oddzielonych spacjami';

  @override
  String get recoveryPhraseMalformed =>
      'To nie wygląda na kompletny 12-słowny klucz odzyskiwania. Sprawdź literówki.';

  @override
  String get recoveryPhraseUseAction => 'Użyj klucza';

  @override
  String get recoveryPhraseNoneAction => 'Nie mam go';

  @override
  String get identityResetStarted =>
      'Reset rozpoczęty. Możesz go anulować do końca odliczania.';

  @override
  String get identityResetPhraseTooNew =>
      'Reset rozpoczęty. Klucz ma mniej niż 6 h, więc czekasz pełne 6 h.';

  @override
  String get identityResetAlreadyRunning =>
      'Dla tego konta reset już trwa. Odliczanie na górze ekranu pokazuje, ile zostało czasu.';

  @override
  String get identityResetCooldown =>
      'Reset niedawno anulowano. Nowy za maks. 24 h. Ktoś obcy anuluje? Zmień hasło.';

  @override
  String get identityResetPhraseRejected =>
      'Te 12 słów nie pasuje do tego konta.';

  @override
  String get identityResetPhraseLocked =>
      'Zbyt wiele prób. Spróbuj za godzinę.';

  @override
  String get identityResetNotEnrolled =>
      'Reset niepotrzebny — zaloguj się na nowym urządzeniu.';

  @override
  String get identityResetNoAnswer =>
      'Brak odpowiedzi. Nic nie rozpoczęto — spróbuj ponownie.';

  @override
  String get identityFingerprintUnavailable =>
      'Odcisk tożsamości jest niedostępny.';

  @override
  String get blockUser => 'Zablokuj użytkownika';

  @override
  String get conversationDeletedByOther => 'Rozmowa usunięta przez drugą osobę';

  @override
  String get noMessagesYet => 'Brak wiadomości';

  @override
  String get cantMessageThisUser => 'Nie możesz pisać do tego użytkownika';

  @override
  String get cantTypeToThisUser => 'Nie możesz pisać do tego użytkownika';

  @override
  String get recordingVoice => 'Nagrywanie głosu…';

  @override
  String get typing => 'pisze…';

  @override
  String get chatMessageHint => 'Napisz wiadomość…';

  @override
  String get chatComposerSendTooltip => 'Wyślij';

  @override
  String get chatComposerSendSemantics => 'Wyślij wiadomość';

  @override
  String get chatComposerEmojiTooltip => 'Emoji';

  @override
  String get chatComposerEmojiSemantics => 'Otwórz panel emoji';

  @override
  String get emojiPickerSemantics => 'Panel emoji';

  @override
  String get emojiPickerSearchHint => 'Szukaj emoji';

  @override
  String get emojiPickerNoRecents => 'Brak ostatnich emoji';

  @override
  String emojiPickerEmojiOptionSemantics(String emoji) {
    return 'Emoji $emoji';
  }

  @override
  String get chatDateToday => 'Dziś';

  @override
  String get chatDateYesterday => 'Wczoraj';

  @override
  String get selectAConversation => 'Wybierz rozmowę';

  @override
  String get noConversationsYet => 'Brak czatów';

  @override
  String get startNewChatToBegin => 'Rozpocznij czat, aby zacząć';

  @override
  String get deleteConversationTitle => 'Usuń rozmowę?';

  @override
  String get deleteConversationConfirm =>
      'Usunie wszystkie wiadomości z tej rozmowy.';

  @override
  String get cancel => 'Anuluj';

  @override
  String get delete => 'Usuń';

  @override
  String get voiceMessage => 'Wiadomość głosowa';

  @override
  String get image => 'Obraz';

  @override
  String get ping => 'Ping';

  @override
  String get attachment => 'Załącznik';

  @override
  String get attachmentOptionDocument => 'Dokument';

  @override
  String get attachmentOptionGallery => 'Galeria';

  @override
  String get attachmentOptionCamera => 'Aparat';

  @override
  String get attachmentOptionRecordVideo => 'Nagraj wideo';

  @override
  String get attachmentOptionFile => 'Plik';

  @override
  String get actionTileDisappearingMessages => 'Znikające wiadomości';

  @override
  String get actionTileClearChat => 'Usuń czat u obu stron';

  @override
  String get clearChatHoldLabel => 'Trzymaj — usuwa u obu stron';

  @override
  String get clearChatConfirmTitle => 'Usunąć ten czat u obu stron?';

  @override
  String get clearChatConfirmBody =>
      'Wszystkie wiadomości, zdjęcia, filmy i wiadomości głosowe z tego czatu zostaną usunięte z serwera u Ciebie I u drugiej osoby. Tego nie można cofnąć — obejmuje to też wiadomości sprzed połączenia tego urządzenia.';

  @override
  String get clearChatConfirmAction => 'Usuń u obu stron';

  @override
  String get disappearingTimerTitle => 'Znikające wiadomości';

  @override
  String get disappearingTimerExplainerLine1 =>
      'Wiadomości znikają po odczytaniu.';

  @override
  String get disappearingTimerExplainerLine2 =>
      'Odliczanie startuje, gdy ktoś otworzy czat.';

  @override
  String get disappearingTimerExplainerLine3 =>
      'Tylko nowe wiadomości używają ustawionego tu czasu.';

  @override
  String get disappearingTimerRangeHint =>
      'Od 5 sekund do 30 dni; same zera = wyłączone';

  @override
  String get disappearingTimerSetTimer => 'Ustaw timer';

  @override
  String get disappearingTimerTurnOff => 'Wyłącz';

  @override
  String disappearingTimerSummarySemantics(String summary) {
    return 'Wybrany czas: $summary';
  }

  @override
  String disappearingComposerBanner(String duration) {
    return 'Znikające · $duration';
  }

  @override
  String disappearingComposerBannerSemantics(String duration) {
    return 'Znikające wiadomości, $duration';
  }

  @override
  String get conversationLastMessageEphemeralPreRead => 'Znika po odczytaniu';

  @override
  String conversationLastMessageEphemeralRemaining(String duration) {
    return 'Znika za $duration';
  }

  @override
  String get disappearingTimerDaysLabel => 'Dni';

  @override
  String get disappearingTimerHoursLabel => 'Godziny';

  @override
  String get disappearingTimerMinutesLabel => 'Minuty';

  @override
  String get disappearingTimerSecondsLabel => 'Sekundy';

  @override
  String get disappearingTimerOff => 'Wyłączone';

  @override
  String get disappearingTimerOutOfRange =>
      'Timer: od 5 sekund do 30 dni albo same zera, aby wyłączyć.';

  @override
  String disappearingTimerDays(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dnia',
      many: '$count dni',
      few: '$count dni',
      one: '1 dzień',
    );
    return '$_temp0';
  }

  @override
  String disappearingTimerHours(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count godziny',
      many: '$count godzin',
      few: '$count godziny',
      one: '1 godzina',
    );
    return '$_temp0';
  }

  @override
  String disappearingTimerMinutes(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minuty',
      many: '$count minut',
      few: '$count minuty',
      one: '1 minuta',
    );
    return '$_temp0';
  }

  @override
  String disappearingTimerSeconds(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sekundy',
      many: '$count sekund',
      few: '$count sekundy',
      one: '1 sekunda',
    );
    return '$_temp0';
  }

  @override
  String get actionTileGif => 'GIF';

  @override
  String get actionTileAntiQuantumNote => 'Notatka antykwantowa';

  @override
  String get unknown => 'Nieznany';

  @override
  String get noBlockedUsers => 'Brak zablokowanych użytkowników';

  @override
  String get unblock => 'Odblokuj';

  @override
  String get removeFriendTitle => 'Usuń z kontaktów?';

  @override
  String removeFriendConfirm(String name) {
    return 'Usunąć $name z kontaktów? Zostanie usunięta cała historia rozmowy.';
  }

  @override
  String get remove => 'Usuń';

  @override
  String get noContactsYet => 'Brak kontaktów';

  @override
  String get addFriendsToStart => 'Dodaj znajomych, aby zacząć pisać';

  @override
  String get contactNetworkLocalNode => 'WĘZEŁ LOKALNY';

  @override
  String get contactNetworkYouLocalNode => 'Ty, węzeł lokalny';

  @override
  String contactNetworkSemantic(num count) {
    return 'Sieć kontaktów, $count kontaktów';
  }

  @override
  String contactNetworkNodes(String count) {
    return 'WĘZŁY $count';
  }

  @override
  String get contactNetworkShowList => 'Widok listy';

  @override
  String get contactNetworkShowMap => 'Widok sieci';

  @override
  String get contactNetworkOpenChatHint => 'Otwórz czat';

  @override
  String get contactNetworkAddSlot => 'dodaj';

  @override
  String get contactNetworkAddSlotSemantic => 'Dodaj kontakt';

  @override
  String contactNetworkPendingRequests(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count zaproszeń oczekuje',
      many: '$count zaproszeń oczekuje',
      few: '$count zaproszenia oczekują',
      one: '1 zaproszenie oczekuje',
    );
    return '$_temp0';
  }

  @override
  String get contactsSearchHint => 'Szukaj kontaktów';

  @override
  String get contactsSearchNoResults => 'Brak pasujących kontaktów';

  @override
  String get block => 'Zablokuj';

  @override
  String get imageFailedToLoad => 'Nie udało się załadować obrazu';

  @override
  String get unsupportedMessageType => 'Nieobsługiwany typ wiadomości';

  @override
  String get resetPasswordDialogTitle => 'Zmień hasło';

  @override
  String get oldPassword => 'Obecne hasło';

  @override
  String get newPassword => 'Nowe hasło';

  @override
  String get passwordRequired => 'Hasło jest wymagane';

  @override
  String get passwordMinLength => 'Hasło musi mieć co najmniej 8 znaków';

  @override
  String get passwordMustContain =>
      'Hasło musi zawierać wielką literę, małą literę i cyfrę';

  @override
  String get oldPasswordRequired => 'Obecne hasło jest wymagane';

  @override
  String get resetButton => 'Zmień';

  @override
  String sessionEndedReason(String reason) {
    return 'wylogowano: $reason';
  }

  @override
  String get authTagline => 'Wiadomości, które przeczytają tylko dwie osoby';

  @override
  String get authLoginTab => 'LOGOWANIE';

  @override
  String get authRegisterTab => 'REJESTRACJA';

  @override
  String get authUsernameHint => 'Nazwa użytkownika';

  @override
  String get authUsernameRequired => 'Nazwa użytkownika jest wymagana';

  @override
  String get authPasswordHint => 'Hasło';

  @override
  String get authPasswordHintRegister => 'Hasło (min. 8 znaków)';

  @override
  String get authLoginButton => 'Zaloguj się';

  @override
  String get authCreateAccountButton => 'Utwórz konto';

  @override
  String get deleteAccountDialogTitle => 'Usuń konto';

  @override
  String get deleteAccountWarning =>
      'Ta operacja jest nieodwracalna. Wszystkie Twoje wiadomości i rozmowy zostaną usunięte.';

  @override
  String get enterPasswordToConfirm => 'Wpisz hasło, aby potwierdzić';

  @override
  String get gifNoResults => 'Nie znaleziono GIFów';

  @override
  String get gifSearchHint => 'Szukaj GIFów...';

  @override
  String get antiQuantumNoteTitle => 'Notatka antykwantowa';

  @override
  String get antiQuantumNoteHint => 'Napisz swoją tajną wiadomość...';

  @override
  String get antiQuantumNoteTtl1h => '1h';

  @override
  String get antiQuantumNoteTtl6h => '6h';

  @override
  String get antiQuantumNoteTtl12h => '12h';

  @override
  String get antiQuantumNoteTtl24h => '24h';

  @override
  String get antiQuantumNoteGenerateAndSend => '🔗 Wygeneruj i wyślij';

  @override
  String get antiQuantumNoteFooter =>
      'Szyfrowanie po stronie klienta · Klucz nigdy nie opuszcza Twojego urządzenia';

  @override
  String get antiQuantumNoteSent => 'Notatka antykwantowa wysłana';

  @override
  String antiQuantumNoteSendFailed(String error) {
    return 'Nie udało się wysłać notatki: $error';
  }

  @override
  String get antiQuantumNoteCardSubtitle =>
      'Jednorazowy odczyt · Dotknij, aby otworzyć';

  @override
  String antiQuantumNoteCardCountdown(String time) {
    return 'Zniszczy się za $time';
  }

  @override
  String get antiQuantumNoteCardDestroyed =>
      'Ta notatka uległa samozniszczeniu';

  @override
  String get antiQuantumNoteBurnedTitle => 'Notatka zniszczona';

  @override
  String get antiQuantumNoteBurnedSubtitle => 'została odczytana';

  @override
  String get antiQuantumNoteRevealWarning =>
      'Odczytasz ją tylko raz. Potem zniknie dla wszystkich.';

  @override
  String get antiQuantumNoteRevealConfirm => 'Odsłoń i zniszcz';

  @override
  String get antiQuantumNoteRevealLoading => 'Odszyfrowywanie…';

  @override
  String get antiQuantumNoteRevealedHeader =>
      'Wiadomość odsłonięta · trwale zniszczona';

  @override
  String get antiQuantumNoteRevealedFooter =>
      'Notatka została usunięta z serwera. Widać ją już tylko na tym ekranie.';

  @override
  String get antiQuantumNoteRevealClose => 'Zamknij';

  @override
  String get antiQuantumNoteRevealRetry => 'Spróbuj ponownie';

  @override
  String get antiQuantumNoteRevealDestroyedBody =>
      'Ta notatka została już odczytana i zniszczona. Nie da się jej przywrócić.';

  @override
  String get antiQuantumNoteRevealExpiredTitle => 'Notatka wygasła';

  @override
  String get antiQuantumNoteRevealExpiredBody =>
      'Ta notatka wygasła i zniszczyła się, zanim została odczytana.';

  @override
  String get antiQuantumNoteRevealCorruptBody =>
      'Notatka została zniszczona, ale nie udało się jej odszyfrować. Link może być uszkodzony.';

  @override
  String get antiQuantumNoteRevealInvalidLinkTitle => 'Uszkodzony link';

  @override
  String get antiQuantumNoteRevealInvalidLinkBody =>
      'W tym linku brakuje prawidłowego klucza deszyfrującego. Notatka nie została zniszczona.';

  @override
  String get antiQuantumNoteRevealNetworkErrorTitle => 'Brak połączenia';

  @override
  String get antiQuantumNoteRevealNetworkErrorBody =>
      'Nie udało się połączyć z serwerem. Sprawdź połączenie i spróbuj ponownie.';

  @override
  String get privacyAntiQuantumNoteTitle => 'Notatki antykwantowe';

  @override
  String get privacyAntiQuantumNoteLead =>
      'Samoniszczące notatki z własnym szyfrowaniem.';

  @override
  String get privacyAntiQuantumNotePointDevice =>
      'Szyfrowane na Twoim urządzeniu, serwer widzi tylko szyfrogram.';

  @override
  String get privacyAntiQuantumNotePointKey =>
      'Klucz jest w linku po #, którego serwer nigdy nie widzi.';

  @override
  String get privacyAntiQuantumNotePointOnce =>
      'Notatkę można odczytać dokładnie raz — po czym jest trwale usuwana.';

  @override
  String get privacyAntiQuantumNotePointTimer =>
      'Nieotwarte znikają po 1–24 h.';

  @override
  String get documentDownloaded => 'Dokument pobrany';

  @override
  String get documentDownloadFailed => 'Nie udało się pobrać dokumentu';

  @override
  String get documentDownloadConfirmTitle => 'Pobrać dokument?';

  @override
  String get documentDownloadConfirmMessage => 'Czy chcesz pobrać ten plik?';

  @override
  String get download => 'Pobierz';

  @override
  String get saveImage => 'Zapisz obraz';

  @override
  String get copyImage => 'Kopiuj obraz';

  @override
  String get imageSaved => 'Zapisano obraz';

  @override
  String get imageSaveFailed => 'Nie udało się zapisać obrazu';

  @override
  String get imageCopied => 'Skopiowano obraz';

  @override
  String get imageCopyFailed => 'Nie udało się skopiować obrazu';

  @override
  String get snackbarCouldNotReadFile => 'Nie udało się odczytać pliku';

  @override
  String get snackbarUploadingImage => 'Wysyłanie zdjęcia…';

  @override
  String get snackbarImageSent => 'Zdjęcie wysłane!';

  @override
  String get snackbarUploadingDocument => 'Wysyłanie dokumentu…';

  @override
  String get snackbarDocumentSent => 'Dokument wysłany!';

  @override
  String get snackbarNoActiveConversation => 'Brak aktywnej rozmowy';

  @override
  String get snackbarOpenConversationFirst => 'Najpierw otwórz rozmowę';

  @override
  String get messageTooLong => 'Wiadomość jest za długa, aby ją wysłać';

  @override
  String get snackbarChatHistoryDeleted => 'Czat usunięty u obu stron';

  @override
  String get snackbarFailedToSendImage => 'Nie udało się wysłać zdjęcia';

  @override
  String get snackbarMicrophonePermissionRequired =>
      'Wymagane jest uprawnienie do mikrofonu';

  @override
  String get snackbarMicrophonePermissionDenied =>
      'Odmowa dostępu do mikrofonu';

  @override
  String get snackbarNoMicrophoneFound => 'Nie znaleziono mikrofonu';

  @override
  String get snackbarVoiceRecordingRequiresSecureContext =>
      'Nagrywanie głosu wymaga HTTPS lub localhost. Użyj https:// lub otwórz z localhost.';

  @override
  String get snackbarFailedToStartRecording =>
      'Nie udało się rozpocząć nagrywania';

  @override
  String get snackbarVoiceRecordingCanceled => 'Nagrywanie głosu anulowane';

  @override
  String get voiceRecordingSendVoiceTooltip => 'Wyślij wiadomość głosową';

  @override
  String get voiceRecordingSendVoiceSemantics => 'Wyślij wiadomość głosową';

  @override
  String get voiceRecordingDiscard => 'Odrzuć nagranie';

  @override
  String voiceRecordingSemanticsLabel(String time) {
    return 'Nagrywanie wiadomości głosowej, $time.';
  }

  @override
  String get snackbarFailedToReadRecording => 'Nie udało się odczytać nagrania';

  @override
  String get snackbarFailedToSendVoiceMessage =>
      'Nie udało się wysłać wiadomości głosowej';

  @override
  String get snackbarAudioNoLongerAvailable => 'Dźwięk nie jest już dostępny';

  @override
  String get snackbarFailedToLoadAudio => 'Nie udało się wczytać dźwięku';

  @override
  String get snackbarAllLocalHistoryDeleted =>
      'Wszystkie wiadomości zapisane na tym urządzeniu zostały trwale usunięte';

  @override
  String get snackbarFailedToDeleteAllLocalHistory =>
      'Nie udało się usunąć części wiadomości z tego urządzenia. Spróbuj ponownie.';

  @override
  String friendAcceptedYourRequest(String name) {
    return '$name zaakceptował(a) zaproszenie do znajomych';
  }

  @override
  String get appearance => 'Wygląd';

  @override
  String appearanceSummary(String theme, String background) {
    return '$theme · $background';
  }

  @override
  String get appearanceColorTheme => 'MOTYW KOLORYSTYCZNY';

  @override
  String get appearanceThemeLight => 'Alabaster';

  @override
  String get appearanceThemeTeal => 'Turkus';

  @override
  String get appearanceThemeDark => 'Grafit';

  @override
  String get appearanceThemeBlue => 'Błękit';

  @override
  String get appearanceThemeCosmic => 'Kosmos';

  @override
  String get themeOptionLight => 'Jasny ciepły papier z żarowymi akcentami';

  @override
  String get themeOptionDark =>
      'Ciemny neutralny grafit z turkusowymi akcentami';

  @override
  String get themeOptionBlue => 'Głęboki granat z błękitnymi akcentami';

  @override
  String get themeOptionTealStone =>
      'Jasny chłodny kamień z turkusowymi akcentami';

  @override
  String get themeOptionCosmic => 'Ciemny kosmos z lodowoniebieskim światłem';

  @override
  String get appearanceChatBackground => 'TŁO CZATU';

  @override
  String get appearanceBackgroundThemeDefault => 'Domyślne motywu';

  @override
  String get appearanceBackgroundThemeDefaultSubtitle =>
      'Dopasowuje się do wybranego motywu';

  @override
  String get appearanceBackgroundThemeDefaultCosmicSubtitle =>
      'Animowane gwiazdy dla motywu Kosmos';

  @override
  String get appearanceBackgroundPlain => 'Gładkie';

  @override
  String get appearanceBackgroundPlainSubtitle =>
      'Jednolite tło w kolorach motywu';

  @override
  String get appearanceBackgroundGlyphs => 'Hieroglify';

  @override
  String get appearanceBackgroundGlyphsSubtitle => 'Wzór świątynnych kolumn';

  @override
  String get appearanceBackgroundStarfield => 'Gwiazdy';

  @override
  String get rotateDeviceTitle => 'Obróć urządzenie';

  @override
  String get rotateDeviceMessage => 'Umbra działa tylko w trybie pionowym.';

  @override
  String get messageActionReply => 'Odpowiedz';

  @override
  String get messageActionCopy => 'Kopiuj';

  @override
  String get messageActionEdit => 'Edytuj';

  @override
  String get messageActionPin => 'Przypnij';

  @override
  String get messageActionDelete => 'Usuń';

  @override
  String get messageDeleteDialogTitle => 'Usunąć wiadomość?';

  @override
  String get messageDeleteForMe => 'Usuń u mnie';

  @override
  String get messageDeleteForEveryone => 'Usuń dla wszystkich';

  @override
  String get messageEditedLabel => 'edytowano';

  @override
  String get messageEditingTitle => 'Edytowanie wiadomości';

  @override
  String get messagePinRequiresSentMessage =>
      'Poczekaj na wysłanie wiadomości, aby ją przypiąć';

  @override
  String get messageReactionMoreEmoji => 'Więcej reakcji emoji';

  @override
  String get messageReactionSelected => 'wybrana';

  @override
  String get messageReactionNotSelected => 'niewybrana';

  @override
  String messageReactionSemantics(Object emoji, Object state) {
    return 'Reakcja $emoji, $state';
  }

  @override
  String messageReactionUnreadable(int count) {
    return 'Reakcja nieczytelna na tym urządzeniu ($count)';
  }

  @override
  String get snackbarReactionUnavailable =>
      'Reakcje nie są jeszcze gotowe na tym urządzeniu';

  @override
  String get snackbarPinnedMessageUnavailable => 'Wiadomość jest niedostępna';

  @override
  String get snackbarMessageCopied => 'Skopiowano wiadomość';

  @override
  String get composerAttachmentRemoveTooltip => 'Usuń załącznik';

  @override
  String get snackbarPastedImageTooLarge => 'Obraz jest za duży (maks. 20 MB)';

  @override
  String get snackbarPastedImageUnsupported =>
      'Nie można wkleić tego typu obrazu';

  @override
  String get snackbarPastedImageUnavailable =>
      'Nie udało się odczytać wklejonego obrazu';

  @override
  String get pinnedMessageUnpinTooltip => 'Odepnij';

  @override
  String get pinnedMessageBannerSemantics => 'Przypięta wiadomość';

  @override
  String get userCardAbout => 'O mnie';

  @override
  String get userCardMyProfile => 'Mój profil';

  @override
  String get userCardEditAbout => 'Edytuj opis';

  @override
  String get userCardAddPhoto => 'Dodaj zdjęcie';

  @override
  String get userCardPhotoLimitReached => 'Osiągnięto limit zdjęć';

  @override
  String get userCardSetMainPhoto => 'Ustaw jako główne zdjęcie';

  @override
  String get userCardDeletePhoto => 'Usuń to zdjęcie';

  @override
  String get userCardSave => 'Zapisz';

  @override
  String get userCardCancel => 'Anuluj';

  @override
  String get userCardBack => 'Wstecz';

  @override
  String get userCardNotificationsOn => 'Powiadomienia włączone';

  @override
  String get userCardMuteOneHour => 'Wycisz na 1 godzinę';

  @override
  String get userCardMuteEightHours => 'Wycisz na 8 godzin';

  @override
  String get userCardMuteOneWeek => 'Wycisz na tydzień';

  @override
  String get userCardMuteForever => 'Wycisz na zawsze';

  @override
  String get userCardMessage => 'Wiadomość';

  @override
  String get userCardMute => 'Wycisz';

  @override
  String get userCardMuted => 'Wyciszono';

  @override
  String get userCardCopyTag => 'Kopiuj tag';

  @override
  String get userCardManagePhotos => 'Zarządzaj zdjęciami';

  @override
  String userCardPhotoOfCount(Object index, Object count) {
    return 'Zdjęcie $index z $count';
  }

  @override
  String get userCardMainPhotoHint =>
      'To jest Twoje główne zdjęcie — kontakty widzą je na czatach.';

  @override
  String get userCardAboutHint => 'Kilka słów o Tobie';

  @override
  String get userCardSharedMedia => 'Udostępnione multimedia';

  @override
  String get userCardDragReorderHint =>
      'Przytrzymaj i przeciągnij, aby zmienić kolejność — pierwsze zdjęcie jest Twoim głównym.';

  @override
  String get settingsChatBackground => 'Tło czatu';

  @override
  String get userCardCopyHandle => 'Kopiuj nazwę użytkownika i tag';

  @override
  String userCardCopiedHandle(Object handle) {
    return 'Skopiowano $handle';
  }

  @override
  String get userCardNotificationsMuted => 'Powiadomienia wyciszone';

  @override
  String userCardBlockTitle(Object handle) {
    return 'Zablokować $handle?';
  }

  @override
  String get userCardBlockConfirm =>
      'Nie będzie można wysyłać wiadomości do tego kontaktu.';

  @override
  String get userCardDeletePhotoTitle => 'Usunąć zdjęcie?';

  @override
  String get userCardDeletePhotoConfirm =>
      'To trwale usuwa to zdjęcie profilowe.';

  @override
  String get userCardSafety => 'Bezpieczeństwo';

  @override
  String get userCardRemoveContact => 'Usuń kontakt';

  @override
  String get messageReadMore => 'Czytaj więcej';

  @override
  String get messageShowLess => 'Zwiń';

  @override
  String get chatPickerTitle => 'Wybierz znajomego';

  @override
  String get chatPickerSubtitle => 'Wybierz węzeł, aby rozpocząć czat';

  @override
  String get chatPickerEmptyTitle => 'Nie masz jeszcze znajomych';

  @override
  String get chatPickerEmptyDescription =>
      'Dodaj znajomego, aby rozpocząć czat.';

  @override
  String get chatPickerOpenTooltip => 'Nowy czat';

  @override
  String get chatPickerInviteButton => 'Zaproś kogoś';

  @override
  String get videoMessage => 'Wideo';

  @override
  String videoTooLarge(String size) {
    return 'Wideo jest za duże ($size MB, maks. 20 MB)';
  }

  @override
  String videoTooLong(String duration) {
    return 'Wideo jest za długie ($duration, maks. 3 minuty)';
  }

  @override
  String get videoCompressing => 'Kompresowanie wideo…';

  @override
  String get videoUnsupportedFormat =>
      'Nieobsługiwany format wideo (tylko MP4)';

  @override
  String get videoFailedToLoad => 'Nie udało się załadować wideo';

  @override
  String get videoStillSending => 'Trwa wysyłanie…';

  @override
  String get videoUnmute => 'Włącz dźwięk';

  @override
  String get videoMute => 'Wycisz';

  @override
  String get videoSenderYou => 'Ty';

  @override
  String get settingsAutoplayVideos => 'Autoodtwarzanie wideo';

  @override
  String get settingsAutoplayVideosSubtitle =>
      'Wideo w czacie odtwarzają się bez dźwięku, gdy są widoczne';

  @override
  String get attachmentUnsupportedFileType => 'Nieobsługiwany typ pliku';

  @override
  String get chatScrollToBottomSemantics => 'Przewiń do najnowszych wiadomości';

  @override
  String get avatarOpenProfileSemantics => 'Otwórz profil';

  @override
  String get passcodeLock => 'Blokada kodem';

  @override
  String get passcodeStateOn => 'Włączona';

  @override
  String get passcodeStateOff => 'Wyłączona';

  @override
  String get passcodeIntro =>
      'Możesz dodać blokadę kodem do Umbry, aby Twoje konto było bardziej prywatne.';

  @override
  String get passcodeTurnOn => 'Włącz blokadę kodem';

  @override
  String get passcodeTurnOff => 'Wyłącz blokadę kodem';

  @override
  String get passcodeChange => 'Zmień kod';

  @override
  String get passcodeAutoLock => 'Automatyczna blokada';

  @override
  String get passcodeAutoLockImmediately => 'Natychmiast';

  @override
  String get passcodeAutoLockMinute => 'Po 1 minucie';

  @override
  String get passcodeAutoLockFiveMinutes => 'Po 5 minutach';

  @override
  String get passcodeAutoLockHour => 'Po 1 godzinie';

  @override
  String get passcodeEnterTitle => 'Wpisz kod';

  @override
  String get passcodeSetTitle => 'Ustaw kod';

  @override
  String get passcodeRepeatTitle => 'Powtórz kod';

  @override
  String get passcodeCurrentTitle => 'Wpisz obecny kod';

  @override
  String get passcodeOptions => 'Opcje kodu';

  @override
  String get passcodeOptionCustom => 'Własny kod alfanumeryczny';

  @override
  String get passcodeOptionSixDigits => '6-cyfrowy kod';

  @override
  String get passcodeOptionFourDigits => '4-cyfrowy kod';

  @override
  String get passcodeConfirmAction => 'Zatwierdź';

  @override
  String get passcodeCustomHint => 'Kod dostępu';

  @override
  String get passcodeWrong => 'Nieprawidłowy kod. Spróbuj ponownie.';

  @override
  String get passcodeMismatch => 'Kody nie są takie same. Zacznij od nowa.';

  @override
  String get passcodeTooShort => 'Użyj co najmniej 4 znaków.';

  @override
  String passcodeBlocked(int seconds) {
    return 'Zbyt wiele prób. Spróbuj ponownie za $seconds s.';
  }

  @override
  String get passcodeUnavailable =>
      'Nie udało się zabezpieczyć kodu na tym urządzeniu.';

  @override
  String get passcodeCredentialLoading =>
      'Odczytywanie zabezpieczeń urządzenia…';

  @override
  String get passcodeForgot => 'Nie pamiętasz kodu?';

  @override
  String get passcodeNoRecovery => 'Zapomnianego kodu nie da się odzyskać.';

  @override
  String get passcodeEraseWarning =>
      'Usunie dane aplikacji. Wiadomości tylko stąd znikną na zawsze.';

  @override
  String get passcodeEraseConfirmWord => 'USUN';

  @override
  String passcodeEraseConfirmHint(String word) {
    return 'Wpisz $word, aby potwierdzić';
  }

  @override
  String get passcodeEraseAction => 'Usuń dane i wyloguj';

  @override
  String get passcodeErasing => 'Usuwanie…';

  @override
  String get passcodeErasePartial => 'Nie wszystko usunięto. Spróbuj ponownie.';

  @override
  String passcodeAttemptsLeft(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Zostało $count próby przed przerwą',
      many: 'Zostało $count prób przed przerwą',
      few: 'Zostały $count próby przed przerwą',
      one: 'Została 1 próba przed przerwą',
    );
    return '$_temp0';
  }

  @override
  String get passcodeLockNowTooltip => 'Zablokuj aplikację';

  @override
  String get passcodeSetUpTooltip => 'Ustaw blokadę kodem';

  @override
  String get passcodeNote =>
      'Zapomnisz kodu — jedyne wyjście to usunięcie danych aplikacji.';

  @override
  String get passcodeScopeNoteDevice =>
      'Blokuje aplikację na tym urządzeniu. Nie trafia na serwer.';

  @override
  String get passcodeScopeNoteBrowser =>
      'Szyfruje klucze w tej przeglądarce. Nie trafia na serwer.';

  @override
  String get passcodeTooWeakForKeys =>
      'Własny kod: min. 6 znaków, nie tylko cyfry.';

  @override
  String get passcodeEraseWarningEnrolled =>
      'Usunie dane aplikacji. Potem przywrócisz konto frazą, z innego urządzenia lub resetem.';

  @override
  String get linkScanAction => 'Zeskanuj kod';

  @override
  String get linkShowCodeAction => 'Pokaż kod';

  @override
  String get linkScanHint => 'Skieruj aparat na kod QR z drugiego urządzenia.';

  @override
  String get linkScanCameraDenied =>
      'Brak dostępu do aparatu. Wpisz kod ręcznie.';

  @override
  String get linkScanUnsupported =>
      'Ta przeglądarka nie obsługuje skanowania. Wpisz kod ręcznie.';

  @override
  String get linkEnterCodeManually => 'Wpisz kod ręcznie';

  @override
  String get linkNewCodeLabel => 'Kod z urządzenia głównego';

  @override
  String get linkPrimaryShowCodeExplainer =>
      'Zeskanuj ten kod nowym urządzeniem.';

  @override
  String get linkGateScanBody =>
      'Zeskanuj kod z urządzenia głównego albo pokaż mu ten.';

  @override
  String get recoveryKeyBackupExplainer =>
      'Te 12 słów odzyskuje hasło i konto po utracie urządzenia. Kto je zna, ma Twoje konto. Pokazujemy je raz.';

  @override
  String get recoveryKeyConfirmTitle => 'Potwierdź, że masz słowa zapisane';

  @override
  String recoveryKeyConfirmPrompt(int n) {
    return 'Wpisz słowo nr $n';
  }

  @override
  String get recoveryKeyConfirmMismatch =>
      'To nie to słowo. Sprawdź zapisane słowa.';

  @override
  String get recoveryKeyConfirmAction => 'Potwierdź';

  @override
  String get recoveryKeyLaterAction => 'Później';

  @override
  String get recoveryKeyReplacesExisting =>
      'Masz już frazę. Nowe słowa ją zastąpią — stare przestaną działać.';

  @override
  String get backupNudgeTitle => 'Zabezpiecz konto — utwórz 12 słów';

  @override
  String get recoveryKeyRequiredForLinking =>
      'Łączenie wymaga frazy odzyskiwania — utworzysz ją za chwilę.';

  @override
  String get linkGateRestoreAction => 'Mam frazę odzyskiwania';

  @override
  String get linkGateRestoreTitle => 'Przywróć konto z frazy';

  @override
  String get linkGateRestoreBody =>
      'Wpisz 12 słów. To urządzenie stanie się głównym.';

  @override
  String get linkGateRestoring => 'Przywracam klucze…';

  @override
  String get linkGateRestoreWrongPhrase =>
      'Fraza nie pasuje do kopii kluczy tego konta.';

  @override
  String get linkGateRestoreNoBackup =>
      'Brak kopii kluczy. Połącz z urządzenia głównego albo zresetuj.';

  @override
  String get linkGateRestoreFailed =>
      'Przywracanie nie powiodło się. Spróbuj ponownie.';

  @override
  String get linkGateRestoreDone => 'Konto przywrócone.';

  @override
  String get devicesBackupMissing =>
      'Brak kopii kluczy. Utwórz frazę odzyskiwania.';

  @override
  String get devicesCreateBackupAction => 'Utwórz frazę odzyskiwania';

  @override
  String get deviceRevokedRestoredNotice =>
      'Konto przywrócono na innym urządzeniu. Połącz to ponownie.';

  @override
  String peerIdentityChangedSystemLine(String name) {
    return '$name: nowe urządzenie lub przeglądarka — klucze zaktualizowane.';
  }

  @override
  String get settingsKeyChangeWarnings =>
      'Ostrzegaj o zmianie kluczy kontaktów';

  @override
  String get settingsKeyChangeWarningsSubtitle =>
      'Domyślnie nowe klucze są przyjmowane, a w czacie pojawia się krótka notatka.';

  @override
  String get devicesRenameAction => 'Zmień nazwę';

  @override
  String get devicesRenameTitle => 'Nazwa urządzenia';

  @override
  String get devicesRenameHint => 'np. Telefon Ani';

  @override
  String get devicesRenameSave => 'Zapisz';

  @override
  String get devicesRenameClearHint => 'Puste pole usuwa nazwę.';

  @override
  String get devicesRenameFailed =>
      'Nie udało się zmienić nazwy. Spróbuj ponownie.';

  @override
  String get devicesRenameNotStorable =>
      'Ta nazwa zawiera znaki, których nie zapiszemy. Wpisz ją z klawiatury, zamiast wklejać.';
}
