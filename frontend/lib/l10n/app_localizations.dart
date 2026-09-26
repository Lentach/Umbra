import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_pl.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('pl'),
  ];

  /// No description provided for @settings.
  ///
  /// In pl, this message translates to:
  /// **'Ustawienia'**
  String get settings;

  /// No description provided for @theme.
  ///
  /// In pl, this message translates to:
  /// **'Motyw'**
  String get theme;

  /// No description provided for @language.
  ///
  /// In pl, this message translates to:
  /// **'Język'**
  String get language;

  /// No description provided for @languagePolish.
  ///
  /// In pl, this message translates to:
  /// **'Polski'**
  String get languagePolish;

  /// No description provided for @languageEnglish.
  ///
  /// In pl, this message translates to:
  /// **'Angielski'**
  String get languageEnglish;

  /// No description provided for @privacyAndSafety.
  ///
  /// In pl, this message translates to:
  /// **'Prywatność i bezpieczeństwo'**
  String get privacyAndSafety;

  /// No description provided for @blocked.
  ///
  /// In pl, this message translates to:
  /// **'Zablokowani'**
  String get blocked;

  /// No description provided for @devices.
  ///
  /// In pl, this message translates to:
  /// **'Urządzenia'**
  String get devices;

  /// No description provided for @webPushEnableTitle.
  ///
  /// In pl, this message translates to:
  /// **'Włącz powiadomienia push'**
  String get webPushEnableTitle;

  /// No description provided for @webPushEnableSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Na iOS wymagane po dodaniu aplikacji do ekranu głównego'**
  String get webPushEnableSubtitle;

  /// No description provided for @webPushEnabled.
  ///
  /// In pl, this message translates to:
  /// **'Powiadomienia push włączone'**
  String get webPushEnabled;

  /// No description provided for @webPushPermissionDenied.
  ///
  /// In pl, this message translates to:
  /// **'Odrzucono uprawnienie do powiadomień'**
  String get webPushPermissionDenied;

  /// No description provided for @webPushInstallRequired.
  ///
  /// In pl, this message translates to:
  /// **'Najpierw dodaj Umbra do ekranu głównego (Safari -> Udostępnij -> Do ekranu początkowego)'**
  String get webPushInstallRequired;

  /// No description provided for @webPushNotSupported.
  ///
  /// In pl, this message translates to:
  /// **'Powiadomienia push nie są obsługiwane w tej przeglądarce/sesji'**
  String get webPushNotSupported;

  /// No description provided for @webPushNoChanges.
  ///
  /// In pl, this message translates to:
  /// **'Powiadomienia push są już włączone'**
  String get webPushNoChanges;

  /// No description provided for @webPushEnableFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się włączyć powiadomień push'**
  String get webPushEnableFailed;

  /// No description provided for @resetPassword.
  ///
  /// In pl, this message translates to:
  /// **'Zmień hasło'**
  String get resetPassword;

  /// No description provided for @deleteAccount.
  ///
  /// In pl, this message translates to:
  /// **'Usuń konto'**
  String get deleteAccount;

  /// No description provided for @logout.
  ///
  /// In pl, this message translates to:
  /// **'Wyloguj'**
  String get logout;

  /// No description provided for @uninstallWarning.
  ///
  /// In pl, this message translates to:
  /// **'Nie odinstalowuj i nie czyść danych — historia zniknie.'**
  String get uninstallWarning;

  /// No description provided for @uninstallWarningTitle.
  ///
  /// In pl, this message translates to:
  /// **'Odinstalowanie lub czyszczenie danych'**
  String get uninstallWarningTitle;

  /// No description provided for @chat.
  ///
  /// In pl, this message translates to:
  /// **'Czaty'**
  String get chat;

  /// No description provided for @contacts.
  ///
  /// In pl, this message translates to:
  /// **'Kontakty'**
  String get contacts;

  /// No description provided for @uploadFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się przesłać'**
  String get uploadFailed;

  /// No description provided for @passwordUpdatedSuccessfully.
  ///
  /// In pl, this message translates to:
  /// **'Hasło zostało zmienione'**
  String get passwordUpdatedSuccessfully;

  /// No description provided for @passwordResetFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się zmienić hasła'**
  String get passwordResetFailed;

  /// No description provided for @accountDeletionFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się usunąć konta'**
  String get accountDeletionFailed;

  /// No description provided for @devicesLoading.
  ///
  /// In pl, this message translates to:
  /// **'Ładowanie…'**
  String get devicesLoading;

  /// No description provided for @devicesExplainer.
  ///
  /// In pl, this message translates to:
  /// **'Nowe urządzenie dodasz tylko z urządzenia głównego.'**
  String get devicesExplainer;

  /// No description provided for @devicesLinkedDeviceNote.
  ///
  /// In pl, this message translates to:
  /// **'To urządzenie jest połączone. Nowe urządzenia dodaje się z urządzenia głównego.'**
  String get devicesLinkedDeviceNote;

  /// No description provided for @devicesNotEnrolled.
  ///
  /// In pl, this message translates to:
  /// **'Łączenie urządzeń nie jest jeszcze włączone dla tego konta.'**
  String get devicesNotEnrolled;

  /// No description provided for @devicesEnableLinking.
  ///
  /// In pl, this message translates to:
  /// **'Włącz łączenie'**
  String get devicesEnableLinking;

  /// No description provided for @devicesLinkADevice.
  ///
  /// In pl, this message translates to:
  /// **'Połącz urządzenie'**
  String get devicesLinkADevice;

  /// No description provided for @devicesLinkThisDevice.
  ///
  /// In pl, this message translates to:
  /// **'Połącz to urządzenie'**
  String get devicesLinkThisDevice;

  /// No description provided for @devicesAlreadyEnrolled.
  ///
  /// In pl, this message translates to:
  /// **'Łączenie włączono na innym urządzeniu. Dodawaj stamtąd.'**
  String get devicesAlreadyEnrolled;

  /// No description provided for @devicesEnrollFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się włączyć łączenia. Spróbuj ponownie.'**
  String get devicesEnrollFailed;

  /// No description provided for @devicesChainInvalid.
  ///
  /// In pl, this message translates to:
  /// **'Nie można zweryfikować listy urządzeń. Spróbuj ponownie później.'**
  String get devicesChainInvalid;

  /// No description provided for @devicesRevokedBadge.
  ///
  /// In pl, this message translates to:
  /// **'cofnięte'**
  String get devicesRevokedBadge;

  /// No description provided for @devicesRevokedSection.
  ///
  /// In pl, this message translates to:
  /// **'{count, plural, one{Cofnięte urządzenie (1)} other{Cofnięte urządzenia ({count})}}'**
  String devicesRevokedSection(num count);

  /// No description provided for @devicesRevokeAction.
  ///
  /// In pl, this message translates to:
  /// **'Usuń urządzenie'**
  String get devicesRevokeAction;

  /// No description provided for @devicesRevokeTitle.
  ///
  /// In pl, this message translates to:
  /// **'Usunąć to urządzenie?'**
  String get devicesRevokeTitle;

  /// No description provided for @devicesRevokeExplainer.
  ///
  /// In pl, this message translates to:
  /// **'Zostanie wylogowane. Jego wiadomości zostają.'**
  String get devicesRevokeExplainer;

  /// No description provided for @devicesRevokeFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się usunąć tego urządzenia. Spróbuj ponownie.'**
  String get devicesRevokeFailed;

  /// No description provided for @deviceRevokedNotice.
  ///
  /// In pl, this message translates to:
  /// **'To urządzenie usunięto z konta. Zaloguj się i połącz je ponownie.'**
  String get deviceRevokedNotice;

  /// No description provided for @deviceMismatchTitle.
  ///
  /// In pl, this message translates to:
  /// **'To urządzenie zostało usunięte z konta'**
  String get deviceMismatchTitle;

  /// No description provided for @deviceMismatchBody.
  ///
  /// In pl, this message translates to:
  /// **'Klucze tego urządzenia zostały unieważnione. Połącz je ponownie z drugiego urządzenia.'**
  String get deviceMismatchBody;

  /// No description provided for @deviceMismatchAction.
  ///
  /// In pl, this message translates to:
  /// **'Połącz to urządzenie'**
  String get deviceMismatchAction;

  /// No description provided for @devicesPrimaryBadge.
  ///
  /// In pl, this message translates to:
  /// **'główne'**
  String get devicesPrimaryBadge;

  /// No description provided for @devicesThisDeviceKeyless.
  ///
  /// In pl, this message translates to:
  /// **'To urządzenie nie ma jeszcze kluczy. Połącz je ze swoim głównym urządzeniem.'**
  String get devicesThisDeviceKeyless;

  /// No description provided for @linkPrimaryTitle.
  ///
  /// In pl, this message translates to:
  /// **'Połącz urządzenie'**
  String get linkPrimaryTitle;

  /// No description provided for @linkPrimaryExplainer.
  ///
  /// In pl, this message translates to:
  /// **'Na nowym urządzeniu wybierz „Połącz to urządzenie”, a potem wpisz tutaj wyświetlony kod.'**
  String get linkPrimaryExplainer;

  /// No description provided for @linkPrimaryCodeLabel.
  ///
  /// In pl, this message translates to:
  /// **'Kod z nowego urządzenia'**
  String get linkPrimaryCodeLabel;

  /// No description provided for @linkPrimaryContinue.
  ///
  /// In pl, this message translates to:
  /// **'Dalej'**
  String get linkPrimaryContinue;

  /// No description provided for @linkSasHeading.
  ///
  /// In pl, this message translates to:
  /// **'Porównaj kody'**
  String get linkSasHeading;

  /// No description provided for @linkSasExplainer.
  ///
  /// In pl, this message translates to:
  /// **'Oba urządzenia muszą pokazywać ten sam kod. Zatwierdź tylko wtedy, gdy są identyczne.'**
  String get linkSasExplainer;

  /// No description provided for @linkApprove.
  ///
  /// In pl, this message translates to:
  /// **'Zatwierdź'**
  String get linkApprove;

  /// No description provided for @linkCancel.
  ///
  /// In pl, this message translates to:
  /// **'Anuluj'**
  String get linkCancel;

  /// No description provided for @linkWaitingForDevice.
  ///
  /// In pl, this message translates to:
  /// **'Czekam na nowe urządzenie…'**
  String get linkWaitingForDevice;

  /// No description provided for @linkPrimaryDone.
  ///
  /// In pl, this message translates to:
  /// **'Urządzenie zostało połączone.'**
  String get linkPrimaryDone;

  /// No description provided for @linkInvalidCode.
  ///
  /// In pl, this message translates to:
  /// **'Nieprawidłowy kod. Przepisz go dokładnie z nowego urządzenia.'**
  String get linkInvalidCode;

  /// No description provided for @linkNoDak.
  ///
  /// In pl, this message translates to:
  /// **'Łączyć można tylko z urządzenia, które włączyło łączenie.'**
  String get linkNoDak;

  /// No description provided for @linkFailed.
  ///
  /// In pl, this message translates to:
  /// **'Łączenie nie powiodło się'**
  String get linkFailed;

  /// No description provided for @linkStaleVersionRetry.
  ///
  /// In pl, this message translates to:
  /// **'Lista urządzeń zmieniła się w trakcie — podpisuję ponownie…'**
  String get linkStaleVersionRetry;

  /// No description provided for @linkNewTitle.
  ///
  /// In pl, this message translates to:
  /// **'Połącz to urządzenie'**
  String get linkNewTitle;

  /// No description provided for @linkNewExplainer.
  ///
  /// In pl, this message translates to:
  /// **'Na urządzeniu głównym: Połącz urządzenie → zeskanuj lub wpisz ten kod.'**
  String get linkNewExplainer;

  /// No description provided for @linkNewWaitingHello.
  ///
  /// In pl, this message translates to:
  /// **'Czekam na główne urządzenie…'**
  String get linkNewWaitingHello;

  /// No description provided for @linkNewCopy.
  ///
  /// In pl, this message translates to:
  /// **'Skopiuj kod'**
  String get linkNewCopy;

  /// No description provided for @linkNewCopied.
  ///
  /// In pl, this message translates to:
  /// **'Kod skopiowany'**
  String get linkNewCopied;

  /// No description provided for @linkNewCompleting.
  ///
  /// In pl, this message translates to:
  /// **'Łączenie…'**
  String get linkNewCompleting;

  /// No description provided for @linkNewRebinding.
  ///
  /// In pl, this message translates to:
  /// **'Przełączam sesję na nowe urządzenie…'**
  String get linkNewRebinding;

  /// No description provided for @linkNewDone.
  ///
  /// In pl, this message translates to:
  /// **'To urządzenie jest połączone i gotowe.'**
  String get linkNewDone;

  /// No description provided for @linkNewAborted.
  ///
  /// In pl, this message translates to:
  /// **'Łączenie przerwane'**
  String get linkNewAborted;

  /// No description provided for @linkNewRetry.
  ///
  /// In pl, this message translates to:
  /// **'Spróbuj ponownie'**
  String get linkNewRetry;

  /// No description provided for @linkAbortReasonExpired.
  ///
  /// In pl, this message translates to:
  /// **'Kod wygasł.'**
  String get linkAbortReasonExpired;

  /// No description provided for @linkAbortReasonCancelled.
  ///
  /// In pl, this message translates to:
  /// **'Łączenie anulowano na drugim urządzeniu.'**
  String get linkAbortReasonCancelled;

  /// No description provided for @linkAbortReasonBadBlob.
  ///
  /// In pl, this message translates to:
  /// **'Weryfikacja danych nie powiodła się. Klucze zostały usunięte z tego urządzenia.'**
  String get linkAbortReasonBadBlob;

  /// No description provided for @settingsAppVersion.
  ///
  /// In pl, this message translates to:
  /// **'Wersja aplikacji'**
  String get settingsAppVersion;

  /// No description provided for @settingsAboutFireplace.
  ///
  /// In pl, this message translates to:
  /// **'O projekcie'**
  String get settingsAboutFireplace;

  /// No description provided for @settingsSectionPreferences.
  ///
  /// In pl, this message translates to:
  /// **'PREFERENCJE'**
  String get settingsSectionPreferences;

  /// No description provided for @settingsSectionSecurity.
  ///
  /// In pl, this message translates to:
  /// **'BEZPIECZEŃSTWO'**
  String get settingsSectionSecurity;

  /// No description provided for @settingsSectionSession.
  ///
  /// In pl, this message translates to:
  /// **'SESJA'**
  String get settingsSectionSession;

  /// No description provided for @privacySafetyTitle.
  ///
  /// In pl, this message translates to:
  /// **'Prywatność i bezpieczeństwo'**
  String get privacySafetyTitle;

  /// No description provided for @e2eEncryptionEnabled.
  ///
  /// In pl, this message translates to:
  /// **'Szyfrowanie end-to-end jest włączone'**
  String get e2eEncryptionEnabled;

  /// No description provided for @e2eEncryptionDescription.
  ///
  /// In pl, this message translates to:
  /// **'Szyfrowanie Signal. Treść widzisz tylko Ty i odbiorca.'**
  String get e2eEncryptionDescription;

  /// No description provided for @yourEncryptionKeys.
  ///
  /// In pl, this message translates to:
  /// **'Twoje klucze szyfrowania'**
  String get yourEncryptionKeys;

  /// No description provided for @yourEncryptionKeysDescription.
  ///
  /// In pl, this message translates to:
  /// **'Klucze są tylko na tym urządzeniu. Bez kopii nie da się ich odzyskać.'**
  String get yourEncryptionKeysDescription;

  /// No description provided for @singleDeviceEncryption.
  ///
  /// In pl, this message translates to:
  /// **'Szyfrowanie na jednym urządzeniu'**
  String get singleDeviceEncryption;

  /// No description provided for @singleDeviceEncryptionDescription.
  ///
  /// In pl, this message translates to:
  /// **'Każde urządzenie ma własne klucze.'**
  String get singleDeviceEncryptionDescription;

  /// No description provided for @webKeyStorage.
  ///
  /// In pl, this message translates to:
  /// **'Przeglądarka: przechowywanie kluczy'**
  String get webKeyStorage;

  /// No description provided for @webKeyStorageDescription.
  ///
  /// In pl, this message translates to:
  /// **'W przeglądarce klucze chroni tylko blokada kodem.'**
  String get webKeyStorageDescription;

  /// No description provided for @whatIsEncrypted.
  ///
  /// In pl, this message translates to:
  /// **'Co jest szyfrowane'**
  String get whatIsEncrypted;

  /// No description provided for @whatIsEncryptedDescription.
  ///
  /// In pl, this message translates to:
  /// **'Tekst, zdjęcia, głos, linki — wszystko end-to-end.'**
  String get whatIsEncryptedDescription;

  /// No description provided for @serverStoresMetadata.
  ///
  /// In pl, this message translates to:
  /// **'Co przechowuje serwer (metadane)'**
  String get serverStoresMetadata;

  /// No description provided for @serverStoresMetadataDescription.
  ///
  /// In pl, this message translates to:
  /// **'Serwer widzi kto, z kim i kiedy. Nigdy treść.'**
  String get serverStoresMetadataDescription;

  /// No description provided for @deleteAllLocalHistoryTitle.
  ///
  /// In pl, this message translates to:
  /// **'Usuń wszystkie wiadomości z tego urządzenia'**
  String get deleteAllLocalHistoryTitle;

  /// No description provided for @deleteAllLocalHistoryDescription.
  ///
  /// In pl, this message translates to:
  /// **'Usuwa wiadomości z tego urządzenia. Konto i klucze zostają.'**
  String get deleteAllLocalHistoryDescription;

  /// No description provided for @deleteAllLocalHistoryButton.
  ///
  /// In pl, this message translates to:
  /// **'Usuń trwale wszystkie lokalne wiadomości'**
  String get deleteAllLocalHistoryButton;

  /// No description provided for @deleteAllLocalHistoryDialogTitle.
  ///
  /// In pl, this message translates to:
  /// **'Trwale usunąć wszystkie lokalne wiadomości?'**
  String get deleteAllLocalHistoryDialogTitle;

  /// No description provided for @deleteAllLocalHistoryDialogBody.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomości z tego urządzenia znikną na zawsze.'**
  String get deleteAllLocalHistoryDialogBody;

  /// No description provided for @deleteAllLocalHistoryConfirm.
  ///
  /// In pl, this message translates to:
  /// **'Usuń trwale'**
  String get deleteAllLocalHistoryConfirm;

  /// No description provided for @yourIdentityFingerprint.
  ///
  /// In pl, this message translates to:
  /// **'Twój odcisk tożsamości'**
  String get yourIdentityFingerprint;

  /// No description provided for @shareFingerprintHint.
  ///
  /// In pl, this message translates to:
  /// **'To unikalna reprezentacja Twojego klucza szyfrowania.'**
  String get shareFingerprintHint;

  /// No description provided for @invitations.
  ///
  /// In pl, this message translates to:
  /// **'Zaproszenia'**
  String get invitations;

  /// No description provided for @invitationsWaitingForYou.
  ///
  /// In pl, this message translates to:
  /// **'Czeka na Ciebie'**
  String get invitationsWaitingForYou;

  /// No description provided for @invitationsSent.
  ///
  /// In pl, this message translates to:
  /// **'Wysłane'**
  String get invitationsSent;

  /// No description provided for @invitationsNothingWaiting.
  ///
  /// In pl, this message translates to:
  /// **'Nic na Ciebie nie czeka'**
  String get invitationsNothingWaiting;

  /// No description provided for @invitationsNoneSent.
  ///
  /// In pl, this message translates to:
  /// **'Brak wysłanych zaproszeń'**
  String get invitationsNoneSent;

  /// No description provided for @inviteByHandleHint.
  ///
  /// In pl, this message translates to:
  /// **'Zaproś kogoś po username#tag. Swój #tag znajdziesz w Ustawieniach przy nicku.'**
  String get inviteByHandleHint;

  /// No description provided for @usernameTagPlaceholder.
  ///
  /// In pl, this message translates to:
  /// **'username#1234'**
  String get usernameTagPlaceholder;

  /// No description provided for @sendInvitation.
  ///
  /// In pl, this message translates to:
  /// **'Wyślij zaproszenie'**
  String get sendInvitation;

  /// No description provided for @invitationFindUser.
  ///
  /// In pl, this message translates to:
  /// **'Znajdź użytkownika'**
  String get invitationFindUser;

  /// No description provided for @userNotFound.
  ///
  /// In pl, this message translates to:
  /// **'Nie znaleziono użytkownika'**
  String get userNotFound;

  /// No description provided for @invitationWantsToConnect.
  ///
  /// In pl, this message translates to:
  /// **'Chce się połączyć'**
  String get invitationWantsToConnect;

  /// No description provided for @invitationWaitingForResponse.
  ///
  /// In pl, this message translates to:
  /// **'Czeka na odpowiedź'**
  String get invitationWaitingForResponse;

  /// No description provided for @invitationAccepted.
  ///
  /// In pl, this message translates to:
  /// **'Zaproszenie zaakceptowane'**
  String get invitationAccepted;

  /// No description provided for @invitationChatReady.
  ///
  /// In pl, this message translates to:
  /// **'Czat gotowy'**
  String get invitationChatReady;

  /// No description provided for @invitationChatNeedsRetry.
  ///
  /// In pl, this message translates to:
  /// **'Czat wymaga ponowienia'**
  String get invitationChatNeedsRetry;

  /// No description provided for @invitationOpenChat.
  ///
  /// In pl, this message translates to:
  /// **'Otwórz czat'**
  String get invitationOpenChat;

  /// No description provided for @invitationCreateChat.
  ///
  /// In pl, this message translates to:
  /// **'Utwórz czat'**
  String get invitationCreateChat;

  /// No description provided for @invitationDone.
  ///
  /// In pl, this message translates to:
  /// **'Gotowe'**
  String get invitationDone;

  /// No description provided for @invitationDecline.
  ///
  /// In pl, this message translates to:
  /// **'Odrzuć'**
  String get invitationDecline;

  /// No description provided for @accept.
  ///
  /// In pl, this message translates to:
  /// **'Zaakceptuj'**
  String get accept;

  /// No description provided for @invitationStatusPending.
  ///
  /// In pl, this message translates to:
  /// **'Oczekuje'**
  String get invitationStatusPending;

  /// No description provided for @invitationSendFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się wysłać zaproszenia'**
  String get invitationSendFailed;

  /// No description provided for @invitationAcceptFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się zaakceptować zaproszenia'**
  String get invitationAcceptFailed;

  /// No description provided for @invitationDeclineFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się odrzucić zaproszenia'**
  String get invitationDeclineFailed;

  /// No description provided for @invitationChatSetupFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się utworzyć czatu'**
  String get invitationChatSetupFailed;

  /// No description provided for @invitationFailedUserNotFound.
  ///
  /// In pl, this message translates to:
  /// **'Ten użytkownik już nie istnieje'**
  String get invitationFailedUserNotFound;

  /// No description provided for @invitationFailedSelf.
  ///
  /// In pl, this message translates to:
  /// **'Nie możesz zaprosić samego siebie'**
  String get invitationFailedSelf;

  /// No description provided for @invitationFailedBlocked.
  ///
  /// In pl, this message translates to:
  /// **'Nie możesz zaprosić tego użytkownika'**
  String get invitationFailedBlocked;

  /// No description provided for @invitationFailedAlreadyFriends.
  ///
  /// In pl, this message translates to:
  /// **'Już jesteście połączeni'**
  String get invitationFailedAlreadyFriends;

  /// No description provided for @invitationFailedDuplicate.
  ///
  /// In pl, this message translates to:
  /// **'Zaproszenie zostało już wysłane'**
  String get invitationFailedDuplicate;

  /// No description provided for @invitationFailedInvalidPayload.
  ///
  /// In pl, this message translates to:
  /// **'Coś było nie tak z tym żądaniem'**
  String get invitationFailedInvalidPayload;

  /// No description provided for @invitationFailedNotFriends.
  ///
  /// In pl, this message translates to:
  /// **'Nie jesteś połączony z tym użytkownikiem'**
  String get invitationFailedNotFriends;

  /// No description provided for @invitationSemanticIncoming.
  ///
  /// In pl, this message translates to:
  /// **'{name}, otrzymane zaproszenie, chce się połączyć'**
  String invitationSemanticIncoming(String name);

  /// No description provided for @invitationSemanticOutgoing.
  ///
  /// In pl, this message translates to:
  /// **'{name}, wysłane zaproszenie, czeka na odpowiedź'**
  String invitationSemanticOutgoing(String name);

  /// No description provided for @invitationSemanticAcceptedReady.
  ///
  /// In pl, this message translates to:
  /// **'{name}, zaproszenie zaakceptowane, czat gotowy'**
  String invitationSemanticAcceptedReady(String name);

  /// No description provided for @invitationSemanticAcceptedNotReady.
  ///
  /// In pl, this message translates to:
  /// **'{name}, zaproszenie zaakceptowane, czat wymaga ponowienia'**
  String invitationSemanticAcceptedNotReady(String name);

  /// No description provided for @encryptedMessage.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomość zaszyfrowana'**
  String get encryptedMessage;

  /// Chat-list preview ONLY, for a last message this install has not decrypted yet (it will resolve when the chat is opened). Every other surface (reply quotes, reply bar) keeps encryptedMessage.
  ///
  /// In pl, this message translates to:
  /// **'Nowa wiadomość'**
  String get newMessagePreview;

  /// No description provided for @decryptingMessage.
  ///
  /// In pl, this message translates to:
  /// **'Odszyfrowywanie…'**
  String get decryptingMessage;

  /// No description provided for @messageNoLongerStoredOnThisDevice.
  ///
  /// In pl, this message translates to:
  /// **'Ta wiadomość nie jest już przechowywana na tym urządzeniu.'**
  String get messageNoLongerStoredOnThisDevice;

  /// Replaces the raw '[encrypted]' / '[Decryption failed]' sentinels in a bubble. The row's keys are gone (this install was wiped/reinstalled, or the ratchet key was consumed), so it can never resolve — say that instead of leaking internal state the user reads as a crash.
  ///
  /// In pl, this message translates to:
  /// **'Nie można odczytać tej wiadomości na tym urządzeniu.'**
  String get messageUnreadableOnThisDevice;

  /// Short second line under an unreadable PEER bubble. Deliberately GENERIC about the cause: the client cannot tell 'this install is newer than the message' (identity replaced by a reinstall, new browser or cleared site data) from 'the ratchet key was already consumed', and asserting the wrong one is worse than the silence it replaces. What IS always true is stated instead — the keys are gone from THIS device — plus the one actionable fact, that reinstalling is the cause rather than the cure. Must stay short: it renders as a caption inside the bubble.
  ///
  /// In pl, this message translates to:
  /// **'Klucze zniknęły — reinstalacja ich nie przywróci.'**
  String get messageUnreadableReasonKeysGone;

  /// Short second line under an unreadable OWN bubble. A sender never decrypts its own ciphertext, so its plaintext lived only in this install's local cache; once that is wiped nothing can restore it.
  ///
  /// In pl, this message translates to:
  /// **'Twoja jedyna kopia była na urządzeniu wysyłającym.'**
  String get messageUnreadableReasonOwnCopyGone;

  /// One pill at the oldest end of a thread, standing in for every row this install can never read: rows that predate this device's link (multi-device spec amendment (lxxxi)), or rows sealed before a storage loss replaced or restored this install's keys (amendments (lxxxvi)/(lxxxviii)). One neutral sentence for both causes.
  ///
  /// In pl, this message translates to:
  /// **'Wcześniejsze wiadomości nie są dostępne na tym urządzeniu'**
  String get historyNotOnThisDevice;

  /// No description provided for @devicesSyncingNote.
  ///
  /// In pl, this message translates to:
  /// **'Synchronizowanie urządzeń…'**
  String get devicesSyncingNote;

  /// No description provided for @encryptionNotInitialized.
  ///
  /// In pl, this message translates to:
  /// **'Szyfrowanie niezainicjowane'**
  String get encryptionNotInitialized;

  /// No description provided for @identityDamagedTitle.
  ///
  /// In pl, this message translates to:
  /// **'Brak kluczy szyfrowania na tym urządzeniu'**
  String get identityDamagedTitle;

  /// Re-sends a message whose delivery failed.
  ///
  /// In pl, this message translates to:
  /// **'Ponów'**
  String get messageRetrySend;

  /// Sits on a failed own message when the account-anchor gate refused the send (amendments (xxxix)/(lv)). Without it the row offers only 'Retry', which silently fails again — the remedy is the fingerprint comparison the red pill opens, not another attempt. Deliberately direction-free: the pill is item 0 of a reverse:true list, so it renders BELOW the newest bubble, and 'above' would point the wrong way.
  ///
  /// In pl, this message translates to:
  /// **'Nie wysłano: klucze bezpieczeństwa tego kontaktu się zmieniły. Otwórz czerwone ostrzeżenie w tym czacie i porównajcie odciski, a potem ponów.'**
  String get messageSendBlockedKeysChanged;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się odczytać sesji. Uruchom aplikację ponownie.'**
  String get authStatusSavedSessionUnreadable;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Konto utworzone. Zaloguj się, aby kontynuować.'**
  String get authStatusRegisterSucceeded;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Brak połączenia. Spróbuj ponownie.'**
  String get authStatusServerUnreachable;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Coś poszło nie tak. Spróbuj ponownie.'**
  String get authStatusUnexpectedError;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Ta nazwa użytkownika jest już zajęta. Jeśli to Ty założyłeś to konto, zaloguj się.'**
  String get authStatusNicknameTaken;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Nazwa użytkownika musi mieć 3-20 znaków i zawierać tylko litery, cyfry i _ .'**
  String get authStatusUsernameInvalid;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Hasło musi mieć co najmniej 8 znaków oraz zawierać wielką literę, małą literę i cyfrę.'**
  String get authStatusPasswordTooWeak;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Nieprawidłowa nazwa użytkownika lub hasło.'**
  String get authStatusInvalidCredentials;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Nieprawidłowe hasło.'**
  String get authStatusWrongPassword;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Zbyt wiele prób. Odczekaj chwilę i spróbuj ponownie.'**
  String get authStatusTooManyAttempts;

  /// Auth surface status, localized from an AuthStatusCode.
  ///
  /// In pl, this message translates to:
  /// **'Serwer nie mógł tego teraz obsłużyć. Spróbuj za chwilę.'**
  String get authStatusServerError;

  /// Auth surface status, localized from an AuthStatusCode: the recover door refused (unknown name, wrong phrase, or none enrolled — one wording by design).
  ///
  /// In pl, this message translates to:
  /// **'Nazwa lub fraza nie pasuje.'**
  String get authStatusPhraseRejected;

  /// Link under the sign-in form that opens the recover-with-phrase form.
  ///
  /// In pl, this message translates to:
  /// **'Nie pamiętam hasła'**
  String get authForgotPassword;

  /// Password field hint on the recover form.
  ///
  /// In pl, this message translates to:
  /// **'Nowe hasło'**
  String get authNewPasswordHint;

  /// Submit button of the recover form.
  ///
  /// In pl, this message translates to:
  /// **'Ustaw nowe hasło'**
  String get authRecoverSubmit;

  /// Button that switches the auth screen to the sign-in tab with the username prefilled.
  ///
  /// In pl, this message translates to:
  /// **'Przejdź do logowania'**
  String get authGoToLogin;

  /// Helper text under the username field on the registration tab.
  ///
  /// In pl, this message translates to:
  /// **'3-20 znaków: tylko litery, cyfry i _'**
  String get authUsernameRules;

  /// Helper text under the password field on the registration tab.
  ///
  /// In pl, this message translates to:
  /// **'Co najmniej 8 znaków, w tym wielka litera, mała litera i cyfra'**
  String get authPasswordRules;

  /// Reveals the full explanation on a collapsed identity banner.
  ///
  /// In pl, this message translates to:
  /// **'Szczegóły'**
  String get identityAlertShowDetails;

  /// Collapses the explanation on an identity banner.
  ///
  /// In pl, this message translates to:
  /// **'Ukryj szczegóły'**
  String get identityAlertHideDetails;

  /// No description provided for @peerIdentityMarkVerifiedAction.
  ///
  /// In pl, this message translates to:
  /// **'Odciski się zgadzają'**
  String get peerIdentityMarkVerifiedAction;

  /// No description provided for @peerIdentityVerifyMenuAction.
  ///
  /// In pl, this message translates to:
  /// **'Zweryfikuj klucze bezpieczeństwa'**
  String get peerIdentityVerifyMenuAction;

  /// No description provided for @peerIdentityFingerprintDialogTitle.
  ///
  /// In pl, this message translates to:
  /// **'Zweryfikuj klucze bezpieczeństwa'**
  String get peerIdentityFingerprintDialogTitle;

  /// No description provided for @peerIdentityFingerprintDialogDescription.
  ///
  /// In pl, this message translates to:
  /// **'Porównaj z {name} innym kanałem. Muszą się zgadzać.'**
  String peerIdentityFingerprintDialogDescription(String name);

  /// No description provided for @peerIdentityFingerprintPeerLabel.
  ///
  /// In pl, this message translates to:
  /// **'Odcisk tożsamości użytkownika {name}'**
  String peerIdentityFingerprintPeerLabel(String name);

  /// No description provided for @peerIdentityFingerprintNoStoredKey.
  ///
  /// In pl, this message translates to:
  /// **'Brak zapisanego klucza tożsamości dla tego kontaktu.'**
  String get peerIdentityFingerprintNoStoredKey;

  /// No description provided for @peerIdentityFingerprintChangedNotice.
  ///
  /// In pl, this message translates to:
  /// **'Klucz {name} się zmienił. Porównaj NOWY odcisk.'**
  String peerIdentityFingerprintChangedNotice(String name);

  /// No description provided for @peerIdentityFingerprintServedNotice.
  ///
  /// In pl, this message translates to:
  /// **'Klucz {name} z serwera, niepotwierdzony wiadomością. Porównaj go innym kanałem.'**
  String peerIdentityFingerprintServedNotice(String name);

  /// No description provided for @peerIdentityFingerprintNewLabel.
  ///
  /// In pl, this message translates to:
  /// **'Nowy odcisk tożsamości użytkownika {name}'**
  String peerIdentityFingerprintNewLabel(String name);

  /// No description provided for @peerIdentityFingerprintPreviousLabel.
  ///
  /// In pl, this message translates to:
  /// **'Poprzednio zaufany odcisk'**
  String get peerIdentityFingerprintPreviousLabel;

  /// No description provided for @peerIdentityFingerprintOfferChanged.
  ///
  /// In pl, this message translates to:
  /// **'Klucz {name} zmienił się w trakcie. Porównaj ponownie.'**
  String peerIdentityFingerprintOfferChanged(String name);

  /// No description provided for @peerIdentityFingerprintUnchangedNotice.
  ///
  /// In pl, this message translates to:
  /// **'Klucz {name} bez zmian od Twojej akceptacji.'**
  String peerIdentityFingerprintUnchangedNotice(String name);

  /// No description provided for @peerIdentityFingerprintOfferUnavailable.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się pobrać klucza {name}. Sprawdź połączenie.'**
  String peerIdentityFingerprintOfferUnavailable(String name);

  /// No description provided for @peerIdentityChangedTimelineRow.
  ///
  /// In pl, this message translates to:
  /// **'Klucze {name} się zmieniły. Dotknij, aby sprawdzić.'**
  String peerIdentityChangedTimelineRow(String name);

  /// No description provided for @ownIdentityReplacedTitle.
  ///
  /// In pl, this message translates to:
  /// **'Nowe klucze szyfrowania na Twoim koncie'**
  String get ownIdentityReplacedTitle;

  /// No description provided for @ownIdentityReplacedBody.
  ///
  /// In pl, this message translates to:
  /// **'Nowe logowanie zmieniło klucze konta. To nie Ty? Zmień hasło.'**
  String get ownIdentityReplacedBody;

  /// No description provided for @ownIdentityReplacedDismissAction.
  ///
  /// In pl, this message translates to:
  /// **'Rozumiem'**
  String get ownIdentityReplacedDismissAction;

  /// No description provided for @identityResetPendingTitle.
  ///
  /// In pl, this message translates to:
  /// **'Ktoś poprosił o zresetowanie Twoich kluczy szyfrowania'**
  String get identityResetPendingTitle;

  /// No description provided for @identityResetPendingBody.
  ///
  /// In pl, this message translates to:
  /// **'Za {remaining} konto dostanie nowe klucze. To nie Ty? Anuluj teraz.'**
  String identityResetPendingBody(String remaining);

  /// No description provided for @identityResetCancelAction.
  ///
  /// In pl, this message translates to:
  /// **'Anuluj'**
  String get identityResetCancelAction;

  /// No description provided for @identityResetHoursLeft.
  ///
  /// In pl, this message translates to:
  /// **'{hours, plural, =1{1 godzinę} few{{hours} godziny} other{{hours} godzin}}'**
  String identityResetHoursLeft(int hours);

  /// No description provided for @identityResetMinutesLeft.
  ///
  /// In pl, this message translates to:
  /// **'{minutes, plural, =0{niecałą minutę} =1{1 minutę} few{{minutes} minuty} other{{minutes} minut}}'**
  String identityResetMinutesLeft(int minutes);

  /// No description provided for @identityResetAnyMoment.
  ///
  /// In pl, this message translates to:
  /// **'lada chwila'**
  String get identityResetAnyMoment;

  /// No description provided for @identityUploadLockedTitle.
  ///
  /// In pl, this message translates to:
  /// **'Twoje nowe klucze szyfrowania nie zostały opublikowane'**
  String get identityUploadLockedTitle;

  /// No description provided for @identityResetStartAction.
  ///
  /// In pl, this message translates to:
  /// **'Rozpocznij reset'**
  String get identityResetStartAction;

  /// No description provided for @linkGateTitle.
  ///
  /// In pl, this message translates to:
  /// **'Połącz to urządzenie'**
  String get linkGateTitle;

  /// No description provided for @linkGateBody.
  ///
  /// In pl, this message translates to:
  /// **'To urządzenie nie ma kluczy konta. Połącz je z urządzenia głównego.'**
  String get linkGateBody;

  /// No description provided for @linkGateWaiting.
  ///
  /// In pl, this message translates to:
  /// **'Czekam na urządzenie główne…'**
  String get linkGateWaiting;

  /// No description provided for @linkGateStaleBody.
  ///
  /// In pl, this message translates to:
  /// **'Klucze tutaj są nieaktualne — połączenie je zastąpi.'**
  String get linkGateStaleBody;

  /// No description provided for @linkGateNoPrimaryQuestion.
  ///
  /// In pl, this message translates to:
  /// **'Nie masz już urządzenia głównego?'**
  String get linkGateNoPrimaryQuestion;

  /// No description provided for @linkGateResetHint.
  ///
  /// In pl, this message translates to:
  /// **'Reset: nowe klucze po 6 h, inne urządzenia wylogowane, stara historia przepada.'**
  String get linkGateResetHint;

  /// No description provided for @linkGateResetPendingTitle.
  ///
  /// In pl, this message translates to:
  /// **'Reset kluczy w toku'**
  String get linkGateResetPendingTitle;

  /// No description provided for @linkGateResetPendingBody.
  ///
  /// In pl, this message translates to:
  /// **'Za {remaining} konto dostanie nowe klucze. Odzyskałeś urządzenie główne? Anuluj i połącz stamtąd.'**
  String linkGateResetPendingBody(String remaining);

  /// No description provided for @linkGateResetPhraseTooNew.
  ///
  /// In pl, this message translates to:
  /// **'Klucz odzyskiwania ma mniej niż 6 h — obowiązuje pełne 6 h.'**
  String get linkGateResetPhraseTooNew;

  /// No description provided for @linkGateCheckingTitle.
  ///
  /// In pl, this message translates to:
  /// **'Sprawdzam klucze tego urządzenia…'**
  String get linkGateCheckingTitle;

  /// No description provided for @linkGateCheckingBody.
  ///
  /// In pl, this message translates to:
  /// **'Sprawdzam, czy konto ma klucze na innym urządzeniu…'**
  String get linkGateCheckingBody;

  /// No description provided for @linkGateRetryAction.
  ///
  /// In pl, this message translates to:
  /// **'Spróbuj ponownie'**
  String get linkGateRetryAction;

  /// No description provided for @linkGateLogoutAction.
  ///
  /// In pl, this message translates to:
  /// **'Wyloguj'**
  String get linkGateLogoutAction;

  /// No description provided for @devicesInstallFirst.
  ///
  /// In pl, this message translates to:
  /// **'Najpierw zainstaluj Umbra jako aplikację (menu → Dodaj do ekranu).'**
  String get devicesInstallFirst;

  /// No description provided for @devicesInstallNudge.
  ///
  /// In pl, this message translates to:
  /// **'Zainstaluj Umbra jako aplikację — przeglądarka może usunąć klucze.'**
  String get devicesInstallNudge;

  /// No description provided for @devicesEnableLinkingWebWarningTitle.
  ///
  /// In pl, this message translates to:
  /// **'Ta przeglądarka stanie się urządzeniem głównym'**
  String get devicesEnableLinkingWebWarningTitle;

  /// No description provided for @devicesEnableLinkingWebWarningBody.
  ///
  /// In pl, this message translates to:
  /// **'Tylko urządzenie główne dodaje i usuwa urządzenia.'**
  String get devicesEnableLinkingWebWarningBody;

  /// No description provided for @devicesEnableLinkingConfirmAction.
  ///
  /// In pl, this message translates to:
  /// **'Włącz'**
  String get devicesEnableLinkingConfirmAction;

  /// No description provided for @recoveryKeyTitle.
  ///
  /// In pl, this message translates to:
  /// **'Klucz odzyskiwania'**
  String get recoveryKeyTitle;

  /// No description provided for @recoveryKeySubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Odzyskasz hasło i konto, gdy stracisz urządzenie'**
  String get recoveryKeySubtitle;

  /// No description provided for @recoveryKeyGenerateAction.
  ///
  /// In pl, this message translates to:
  /// **'Wygeneruj klucz odzyskiwania'**
  String get recoveryKeyGenerateAction;

  /// No description provided for @recoveryKeyShownOnceWarning.
  ///
  /// In pl, this message translates to:
  /// **'Pokazujemy je tylko raz. Zapisz teraz.'**
  String get recoveryKeyShownOnceWarning;

  /// No description provided for @recoveryKeyCopyAction.
  ///
  /// In pl, this message translates to:
  /// **'Kopiuj słowa'**
  String get recoveryKeyCopyAction;

  /// No description provided for @recoveryKeyCopied.
  ///
  /// In pl, this message translates to:
  /// **'Skopiowano klucz odzyskiwania'**
  String get recoveryKeyCopied;

  /// No description provided for @recoveryKeySavedAction.
  ///
  /// In pl, this message translates to:
  /// **'Zapisałem/am'**
  String get recoveryKeySavedAction;

  /// No description provided for @recoveryKeySaved.
  ///
  /// In pl, this message translates to:
  /// **'Zapisano klucz odzyskiwania'**
  String get recoveryKeySaved;

  /// No description provided for @recoveryKeySaveFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie zapisano klucza. Te słowa nie działają — spróbuj ponownie.'**
  String get recoveryKeySaveFailed;

  /// No description provided for @recoveryPhrasePromptTitle.
  ///
  /// In pl, this message translates to:
  /// **'Masz klucz odzyskiwania?'**
  String get recoveryPhrasePromptTitle;

  /// No description provided for @recoveryPhrasePromptBody.
  ///
  /// In pl, this message translates to:
  /// **'12 słów skraca oczekiwanie z 6 h do 1 h.'**
  String get recoveryPhrasePromptBody;

  /// No description provided for @recoveryPhrasePromptHint.
  ///
  /// In pl, this message translates to:
  /// **'dwanaście słów oddzielonych spacjami'**
  String get recoveryPhrasePromptHint;

  /// No description provided for @recoveryPhraseMalformed.
  ///
  /// In pl, this message translates to:
  /// **'To nie wygląda na kompletny 12-słowny klucz odzyskiwania. Sprawdź literówki.'**
  String get recoveryPhraseMalformed;

  /// No description provided for @recoveryPhraseUseAction.
  ///
  /// In pl, this message translates to:
  /// **'Użyj klucza'**
  String get recoveryPhraseUseAction;

  /// No description provided for @recoveryPhraseNoneAction.
  ///
  /// In pl, this message translates to:
  /// **'Nie mam go'**
  String get recoveryPhraseNoneAction;

  /// No description provided for @identityResetStarted.
  ///
  /// In pl, this message translates to:
  /// **'Reset rozpoczęty. Możesz go anulować do końca odliczania.'**
  String get identityResetStarted;

  /// No description provided for @identityResetPhraseTooNew.
  ///
  /// In pl, this message translates to:
  /// **'Reset rozpoczęty. Klucz ma mniej niż 6 h, więc czekasz pełne 6 h.'**
  String get identityResetPhraseTooNew;

  /// No description provided for @identityResetAlreadyRunning.
  ///
  /// In pl, this message translates to:
  /// **'Dla tego konta reset już trwa. Odliczanie na górze ekranu pokazuje, ile zostało czasu.'**
  String get identityResetAlreadyRunning;

  /// No description provided for @identityResetCooldown.
  ///
  /// In pl, this message translates to:
  /// **'Reset niedawno anulowano. Nowy za maks. 24 h. Ktoś obcy anuluje? Zmień hasło.'**
  String get identityResetCooldown;

  /// No description provided for @identityResetPhraseRejected.
  ///
  /// In pl, this message translates to:
  /// **'Te 12 słów nie pasuje do tego konta.'**
  String get identityResetPhraseRejected;

  /// No description provided for @identityResetPhraseLocked.
  ///
  /// In pl, this message translates to:
  /// **'Zbyt wiele prób. Spróbuj za godzinę.'**
  String get identityResetPhraseLocked;

  /// No description provided for @identityResetNotEnrolled.
  ///
  /// In pl, this message translates to:
  /// **'Reset niepotrzebny — zaloguj się na nowym urządzeniu.'**
  String get identityResetNotEnrolled;

  /// No description provided for @identityResetNoAnswer.
  ///
  /// In pl, this message translates to:
  /// **'Brak odpowiedzi. Nic nie rozpoczęto — spróbuj ponownie.'**
  String get identityResetNoAnswer;

  /// No description provided for @identityFingerprintUnavailable.
  ///
  /// In pl, this message translates to:
  /// **'Odcisk tożsamości jest niedostępny.'**
  String get identityFingerprintUnavailable;

  /// No description provided for @blockUser.
  ///
  /// In pl, this message translates to:
  /// **'Zablokuj użytkownika'**
  String get blockUser;

  /// No description provided for @conversationDeletedByOther.
  ///
  /// In pl, this message translates to:
  /// **'Rozmowa usunięta przez drugą osobę'**
  String get conversationDeletedByOther;

  /// No description provided for @noMessagesYet.
  ///
  /// In pl, this message translates to:
  /// **'Brak wiadomości'**
  String get noMessagesYet;

  /// No description provided for @cantMessageThisUser.
  ///
  /// In pl, this message translates to:
  /// **'Nie możesz pisać do tego użytkownika'**
  String get cantMessageThisUser;

  /// No description provided for @cantTypeToThisUser.
  ///
  /// In pl, this message translates to:
  /// **'Nie możesz pisać do tego użytkownika'**
  String get cantTypeToThisUser;

  /// No description provided for @recordingVoice.
  ///
  /// In pl, this message translates to:
  /// **'Nagrywanie głosu…'**
  String get recordingVoice;

  /// No description provided for @typing.
  ///
  /// In pl, this message translates to:
  /// **'pisze…'**
  String get typing;

  /// No description provided for @chatMessageHint.
  ///
  /// In pl, this message translates to:
  /// **'Napisz wiadomość…'**
  String get chatMessageHint;

  /// No description provided for @chatComposerSendTooltip.
  ///
  /// In pl, this message translates to:
  /// **'Wyślij'**
  String get chatComposerSendTooltip;

  /// No description provided for @chatComposerSendSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Wyślij wiadomość'**
  String get chatComposerSendSemantics;

  /// No description provided for @chatComposerEmojiTooltip.
  ///
  /// In pl, this message translates to:
  /// **'Emoji'**
  String get chatComposerEmojiTooltip;

  /// No description provided for @chatComposerEmojiSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Otwórz panel emoji'**
  String get chatComposerEmojiSemantics;

  /// No description provided for @emojiPickerSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Panel emoji'**
  String get emojiPickerSemantics;

  /// No description provided for @emojiPickerSearchHint.
  ///
  /// In pl, this message translates to:
  /// **'Szukaj emoji'**
  String get emojiPickerSearchHint;

  /// No description provided for @emojiPickerNoRecents.
  ///
  /// In pl, this message translates to:
  /// **'Brak ostatnich emoji'**
  String get emojiPickerNoRecents;

  /// No description provided for @emojiPickerEmojiOptionSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Emoji {emoji}'**
  String emojiPickerEmojiOptionSemantics(String emoji);

  /// No description provided for @chatDateToday.
  ///
  /// In pl, this message translates to:
  /// **'Dziś'**
  String get chatDateToday;

  /// No description provided for @chatDateYesterday.
  ///
  /// In pl, this message translates to:
  /// **'Wczoraj'**
  String get chatDateYesterday;

  /// No description provided for @selectAConversation.
  ///
  /// In pl, this message translates to:
  /// **'Wybierz rozmowę'**
  String get selectAConversation;

  /// No description provided for @noConversationsYet.
  ///
  /// In pl, this message translates to:
  /// **'Brak czatów'**
  String get noConversationsYet;

  /// No description provided for @startNewChatToBegin.
  ///
  /// In pl, this message translates to:
  /// **'Rozpocznij czat, aby zacząć'**
  String get startNewChatToBegin;

  /// No description provided for @deleteConversationTitle.
  ///
  /// In pl, this message translates to:
  /// **'Usuń rozmowę?'**
  String get deleteConversationTitle;

  /// No description provided for @deleteConversationConfirm.
  ///
  /// In pl, this message translates to:
  /// **'Usunie wszystkie wiadomości z tej rozmowy.'**
  String get deleteConversationConfirm;

  /// No description provided for @cancel.
  ///
  /// In pl, this message translates to:
  /// **'Anuluj'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In pl, this message translates to:
  /// **'Usuń'**
  String get delete;

  /// No description provided for @voiceMessage.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomość głosowa'**
  String get voiceMessage;

  /// No description provided for @image.
  ///
  /// In pl, this message translates to:
  /// **'Obraz'**
  String get image;

  /// No description provided for @ping.
  ///
  /// In pl, this message translates to:
  /// **'Ping'**
  String get ping;

  /// No description provided for @attachment.
  ///
  /// In pl, this message translates to:
  /// **'Załącznik'**
  String get attachment;

  /// No description provided for @attachmentOptionDocument.
  ///
  /// In pl, this message translates to:
  /// **'Dokument'**
  String get attachmentOptionDocument;

  /// No description provided for @attachmentOptionGallery.
  ///
  /// In pl, this message translates to:
  /// **'Galeria'**
  String get attachmentOptionGallery;

  /// No description provided for @attachmentOptionCamera.
  ///
  /// In pl, this message translates to:
  /// **'Aparat'**
  String get attachmentOptionCamera;

  /// No description provided for @attachmentOptionRecordVideo.
  ///
  /// In pl, this message translates to:
  /// **'Nagraj wideo'**
  String get attachmentOptionRecordVideo;

  /// No description provided for @attachmentOptionFile.
  ///
  /// In pl, this message translates to:
  /// **'Plik'**
  String get attachmentOptionFile;

  /// No description provided for @actionTileDisappearingMessages.
  ///
  /// In pl, this message translates to:
  /// **'Znikające wiadomości'**
  String get actionTileDisappearingMessages;

  /// No description provided for @actionTileClearChat.
  ///
  /// In pl, this message translates to:
  /// **'Usuń czat u obu stron'**
  String get actionTileClearChat;

  /// No description provided for @clearChatHoldLabel.
  ///
  /// In pl, this message translates to:
  /// **'Trzymaj — usuwa u obu stron'**
  String get clearChatHoldLabel;

  /// No description provided for @clearChatConfirmTitle.
  ///
  /// In pl, this message translates to:
  /// **'Usunąć ten czat u obu stron?'**
  String get clearChatConfirmTitle;

  /// No description provided for @clearChatConfirmBody.
  ///
  /// In pl, this message translates to:
  /// **'Wszystkie wiadomości, zdjęcia, filmy i wiadomości głosowe z tego czatu zostaną usunięte z serwera u Ciebie I u drugiej osoby. Tego nie można cofnąć — obejmuje to też wiadomości sprzed połączenia tego urządzenia.'**
  String get clearChatConfirmBody;

  /// No description provided for @clearChatConfirmAction.
  ///
  /// In pl, this message translates to:
  /// **'Usuń u obu stron'**
  String get clearChatConfirmAction;

  /// No description provided for @disappearingTimerTitle.
  ///
  /// In pl, this message translates to:
  /// **'Znikające wiadomości'**
  String get disappearingTimerTitle;

  /// No description provided for @disappearingTimerExplainerLine1.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomości znikają po odczytaniu.'**
  String get disappearingTimerExplainerLine1;

  /// No description provided for @disappearingTimerExplainerLine2.
  ///
  /// In pl, this message translates to:
  /// **'Odliczanie startuje, gdy ktoś otworzy czat.'**
  String get disappearingTimerExplainerLine2;

  /// No description provided for @disappearingTimerExplainerLine3.
  ///
  /// In pl, this message translates to:
  /// **'Tylko nowe wiadomości używają ustawionego tu czasu.'**
  String get disappearingTimerExplainerLine3;

  /// No description provided for @disappearingTimerRangeHint.
  ///
  /// In pl, this message translates to:
  /// **'Od 5 sekund do 30 dni; same zera = wyłączone'**
  String get disappearingTimerRangeHint;

  /// No description provided for @disappearingTimerSetTimer.
  ///
  /// In pl, this message translates to:
  /// **'Ustaw timer'**
  String get disappearingTimerSetTimer;

  /// No description provided for @disappearingTimerTurnOff.
  ///
  /// In pl, this message translates to:
  /// **'Wyłącz'**
  String get disappearingTimerTurnOff;

  /// No description provided for @disappearingTimerSummarySemantics.
  ///
  /// In pl, this message translates to:
  /// **'Wybrany czas: {summary}'**
  String disappearingTimerSummarySemantics(String summary);

  /// No description provided for @disappearingComposerBanner.
  ///
  /// In pl, this message translates to:
  /// **'Znikające · {duration}'**
  String disappearingComposerBanner(String duration);

  /// No description provided for @disappearingComposerBannerSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Znikające wiadomości, {duration}'**
  String disappearingComposerBannerSemantics(String duration);

  /// No description provided for @conversationLastMessageEphemeralPreRead.
  ///
  /// In pl, this message translates to:
  /// **'Znika po odczytaniu'**
  String get conversationLastMessageEphemeralPreRead;

  /// No description provided for @conversationLastMessageEphemeralRemaining.
  ///
  /// In pl, this message translates to:
  /// **'Znika za {duration}'**
  String conversationLastMessageEphemeralRemaining(String duration);

  /// No description provided for @disappearingTimerDaysLabel.
  ///
  /// In pl, this message translates to:
  /// **'Dni'**
  String get disappearingTimerDaysLabel;

  /// No description provided for @disappearingTimerHoursLabel.
  ///
  /// In pl, this message translates to:
  /// **'Godziny'**
  String get disappearingTimerHoursLabel;

  /// No description provided for @disappearingTimerMinutesLabel.
  ///
  /// In pl, this message translates to:
  /// **'Minuty'**
  String get disappearingTimerMinutesLabel;

  /// No description provided for @disappearingTimerSecondsLabel.
  ///
  /// In pl, this message translates to:
  /// **'Sekundy'**
  String get disappearingTimerSecondsLabel;

  /// No description provided for @disappearingTimerOff.
  ///
  /// In pl, this message translates to:
  /// **'Wyłączone'**
  String get disappearingTimerOff;

  /// No description provided for @disappearingTimerOutOfRange.
  ///
  /// In pl, this message translates to:
  /// **'Timer: od 5 sekund do 30 dni albo same zera, aby wyłączyć.'**
  String get disappearingTimerOutOfRange;

  /// No description provided for @disappearingTimerDays.
  ///
  /// In pl, this message translates to:
  /// **'{count, plural, one{1 dzień} few{{count} dni} many{{count} dni} other{{count} dnia}}'**
  String disappearingTimerDays(num count);

  /// No description provided for @disappearingTimerHours.
  ///
  /// In pl, this message translates to:
  /// **'{count, plural, one{1 godzina} few{{count} godziny} many{{count} godzin} other{{count} godziny}}'**
  String disappearingTimerHours(num count);

  /// No description provided for @disappearingTimerMinutes.
  ///
  /// In pl, this message translates to:
  /// **'{count, plural, one{1 minuta} few{{count} minuty} many{{count} minut} other{{count} minuty}}'**
  String disappearingTimerMinutes(num count);

  /// No description provided for @disappearingTimerSeconds.
  ///
  /// In pl, this message translates to:
  /// **'{count, plural, one{1 sekunda} few{{count} sekundy} many{{count} sekund} other{{count} sekundy}}'**
  String disappearingTimerSeconds(num count);

  /// No description provided for @actionTileGif.
  ///
  /// In pl, this message translates to:
  /// **'GIF'**
  String get actionTileGif;

  /// No description provided for @actionTileAntiQuantumNote.
  ///
  /// In pl, this message translates to:
  /// **'Notatka antykwantowa'**
  String get actionTileAntiQuantumNote;

  /// No description provided for @unknown.
  ///
  /// In pl, this message translates to:
  /// **'Nieznany'**
  String get unknown;

  /// No description provided for @noBlockedUsers.
  ///
  /// In pl, this message translates to:
  /// **'Brak zablokowanych użytkowników'**
  String get noBlockedUsers;

  /// No description provided for @unblock.
  ///
  /// In pl, this message translates to:
  /// **'Odblokuj'**
  String get unblock;

  /// No description provided for @removeFriendTitle.
  ///
  /// In pl, this message translates to:
  /// **'Usuń z kontaktów?'**
  String get removeFriendTitle;

  /// No description provided for @removeFriendConfirm.
  ///
  /// In pl, this message translates to:
  /// **'Usunąć {name} z kontaktów? Zostanie usunięta cała historia rozmowy.'**
  String removeFriendConfirm(String name);

  /// No description provided for @remove.
  ///
  /// In pl, this message translates to:
  /// **'Usuń'**
  String get remove;

  /// No description provided for @noContactsYet.
  ///
  /// In pl, this message translates to:
  /// **'Brak kontaktów'**
  String get noContactsYet;

  /// No description provided for @addFriendsToStart.
  ///
  /// In pl, this message translates to:
  /// **'Dodaj znajomych, aby zacząć pisać'**
  String get addFriendsToStart;

  /// No description provided for @contactNetworkLocalNode.
  ///
  /// In pl, this message translates to:
  /// **'WĘZEŁ LOKALNY'**
  String get contactNetworkLocalNode;

  /// No description provided for @contactNetworkYouLocalNode.
  ///
  /// In pl, this message translates to:
  /// **'Ty, węzeł lokalny'**
  String get contactNetworkYouLocalNode;

  /// No description provided for @contactNetworkSemantic.
  ///
  /// In pl, this message translates to:
  /// **'Sieć kontaktów, {count} kontaktów'**
  String contactNetworkSemantic(num count);

  /// No description provided for @contactNetworkNodes.
  ///
  /// In pl, this message translates to:
  /// **'WĘZŁY {count}'**
  String contactNetworkNodes(String count);

  /// No description provided for @contactNetworkShowList.
  ///
  /// In pl, this message translates to:
  /// **'Widok listy'**
  String get contactNetworkShowList;

  /// No description provided for @contactNetworkShowMap.
  ///
  /// In pl, this message translates to:
  /// **'Widok sieci'**
  String get contactNetworkShowMap;

  /// No description provided for @contactNetworkOpenChatHint.
  ///
  /// In pl, this message translates to:
  /// **'Otwórz czat'**
  String get contactNetworkOpenChatHint;

  /// No description provided for @contactNetworkAddSlot.
  ///
  /// In pl, this message translates to:
  /// **'dodaj'**
  String get contactNetworkAddSlot;

  /// No description provided for @contactNetworkAddSlotSemantic.
  ///
  /// In pl, this message translates to:
  /// **'Dodaj kontakt'**
  String get contactNetworkAddSlotSemantic;

  /// No description provided for @contactNetworkPendingRequests.
  ///
  /// In pl, this message translates to:
  /// **'{count, plural, =1{1 zaproszenie oczekuje} few{{count} zaproszenia oczekują} many{{count} zaproszeń oczekuje} other{{count} zaproszeń oczekuje}}'**
  String contactNetworkPendingRequests(num count);

  /// No description provided for @contactsSearchHint.
  ///
  /// In pl, this message translates to:
  /// **'Szukaj kontaktów'**
  String get contactsSearchHint;

  /// No description provided for @contactsSearchNoResults.
  ///
  /// In pl, this message translates to:
  /// **'Brak pasujących kontaktów'**
  String get contactsSearchNoResults;

  /// No description provided for @block.
  ///
  /// In pl, this message translates to:
  /// **'Zablokuj'**
  String get block;

  /// No description provided for @imageFailedToLoad.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się załadować obrazu'**
  String get imageFailedToLoad;

  /// No description provided for @unsupportedMessageType.
  ///
  /// In pl, this message translates to:
  /// **'Nieobsługiwany typ wiadomości'**
  String get unsupportedMessageType;

  /// No description provided for @resetPasswordDialogTitle.
  ///
  /// In pl, this message translates to:
  /// **'Zmień hasło'**
  String get resetPasswordDialogTitle;

  /// No description provided for @oldPassword.
  ///
  /// In pl, this message translates to:
  /// **'Obecne hasło'**
  String get oldPassword;

  /// No description provided for @newPassword.
  ///
  /// In pl, this message translates to:
  /// **'Nowe hasło'**
  String get newPassword;

  /// No description provided for @passwordRequired.
  ///
  /// In pl, this message translates to:
  /// **'Hasło jest wymagane'**
  String get passwordRequired;

  /// No description provided for @passwordMinLength.
  ///
  /// In pl, this message translates to:
  /// **'Hasło musi mieć co najmniej 8 znaków'**
  String get passwordMinLength;

  /// No description provided for @passwordMustContain.
  ///
  /// In pl, this message translates to:
  /// **'Hasło musi zawierać wielką literę, małą literę i cyfrę'**
  String get passwordMustContain;

  /// No description provided for @oldPasswordRequired.
  ///
  /// In pl, this message translates to:
  /// **'Obecne hasło jest wymagane'**
  String get oldPasswordRequired;

  /// No description provided for @resetButton.
  ///
  /// In pl, this message translates to:
  /// **'Zmień'**
  String get resetButton;

  /// No description provided for @sessionEndedReason.
  ///
  /// In pl, this message translates to:
  /// **'wylogowano: {reason}'**
  String sessionEndedReason(String reason);

  /// No description provided for @authTagline.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomości, które przeczytają tylko dwie osoby'**
  String get authTagline;

  /// No description provided for @authLoginTab.
  ///
  /// In pl, this message translates to:
  /// **'LOGOWANIE'**
  String get authLoginTab;

  /// No description provided for @authRegisterTab.
  ///
  /// In pl, this message translates to:
  /// **'REJESTRACJA'**
  String get authRegisterTab;

  /// No description provided for @authUsernameHint.
  ///
  /// In pl, this message translates to:
  /// **'Nazwa użytkownika'**
  String get authUsernameHint;

  /// No description provided for @authUsernameRequired.
  ///
  /// In pl, this message translates to:
  /// **'Nazwa użytkownika jest wymagana'**
  String get authUsernameRequired;

  /// No description provided for @authPasswordHint.
  ///
  /// In pl, this message translates to:
  /// **'Hasło'**
  String get authPasswordHint;

  /// No description provided for @authPasswordHintRegister.
  ///
  /// In pl, this message translates to:
  /// **'Hasło (min. 8 znaków)'**
  String get authPasswordHintRegister;

  /// No description provided for @authLoginButton.
  ///
  /// In pl, this message translates to:
  /// **'Zaloguj się'**
  String get authLoginButton;

  /// No description provided for @authCreateAccountButton.
  ///
  /// In pl, this message translates to:
  /// **'Utwórz konto'**
  String get authCreateAccountButton;

  /// No description provided for @deleteAccountDialogTitle.
  ///
  /// In pl, this message translates to:
  /// **'Usuń konto'**
  String get deleteAccountDialogTitle;

  /// No description provided for @deleteAccountWarning.
  ///
  /// In pl, this message translates to:
  /// **'Ta operacja jest nieodwracalna. Wszystkie Twoje wiadomości i rozmowy zostaną usunięte.'**
  String get deleteAccountWarning;

  /// No description provided for @enterPasswordToConfirm.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz hasło, aby potwierdzić'**
  String get enterPasswordToConfirm;

  /// No description provided for @gifNoResults.
  ///
  /// In pl, this message translates to:
  /// **'Nie znaleziono GIFów'**
  String get gifNoResults;

  /// No description provided for @gifSearchHint.
  ///
  /// In pl, this message translates to:
  /// **'Szukaj GIFów...'**
  String get gifSearchHint;

  /// No description provided for @antiQuantumNoteTitle.
  ///
  /// In pl, this message translates to:
  /// **'Notatka antykwantowa'**
  String get antiQuantumNoteTitle;

  /// No description provided for @antiQuantumNoteHint.
  ///
  /// In pl, this message translates to:
  /// **'Napisz swoją tajną wiadomość...'**
  String get antiQuantumNoteHint;

  /// No description provided for @antiQuantumNoteTtl1h.
  ///
  /// In pl, this message translates to:
  /// **'1h'**
  String get antiQuantumNoteTtl1h;

  /// No description provided for @antiQuantumNoteTtl6h.
  ///
  /// In pl, this message translates to:
  /// **'6h'**
  String get antiQuantumNoteTtl6h;

  /// No description provided for @antiQuantumNoteTtl12h.
  ///
  /// In pl, this message translates to:
  /// **'12h'**
  String get antiQuantumNoteTtl12h;

  /// No description provided for @antiQuantumNoteTtl24h.
  ///
  /// In pl, this message translates to:
  /// **'24h'**
  String get antiQuantumNoteTtl24h;

  /// No description provided for @antiQuantumNoteGenerateAndSend.
  ///
  /// In pl, this message translates to:
  /// **'🔗 Wygeneruj i wyślij'**
  String get antiQuantumNoteGenerateAndSend;

  /// No description provided for @antiQuantumNoteFooter.
  ///
  /// In pl, this message translates to:
  /// **'Szyfrowanie po stronie klienta · Klucz nigdy nie opuszcza Twojego urządzenia'**
  String get antiQuantumNoteFooter;

  /// No description provided for @antiQuantumNoteSent.
  ///
  /// In pl, this message translates to:
  /// **'Notatka antykwantowa wysłana'**
  String get antiQuantumNoteSent;

  /// No description provided for @antiQuantumNoteSendFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się wysłać notatki: {error}'**
  String antiQuantumNoteSendFailed(String error);

  /// No description provided for @antiQuantumNoteCardSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Jednorazowy odczyt · Dotknij, aby otworzyć'**
  String get antiQuantumNoteCardSubtitle;

  /// No description provided for @antiQuantumNoteCardCountdown.
  ///
  /// In pl, this message translates to:
  /// **'Zniszczy się za {time}'**
  String antiQuantumNoteCardCountdown(String time);

  /// No description provided for @antiQuantumNoteCardDestroyed.
  ///
  /// In pl, this message translates to:
  /// **'Ta notatka uległa samozniszczeniu'**
  String get antiQuantumNoteCardDestroyed;

  /// No description provided for @antiQuantumNoteBurnedTitle.
  ///
  /// In pl, this message translates to:
  /// **'Notatka zniszczona'**
  String get antiQuantumNoteBurnedTitle;

  /// No description provided for @antiQuantumNoteBurnedSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'została odczytana'**
  String get antiQuantumNoteBurnedSubtitle;

  /// No description provided for @antiQuantumNoteRevealWarning.
  ///
  /// In pl, this message translates to:
  /// **'Odczytasz ją tylko raz. Potem zniknie dla wszystkich.'**
  String get antiQuantumNoteRevealWarning;

  /// No description provided for @antiQuantumNoteRevealConfirm.
  ///
  /// In pl, this message translates to:
  /// **'Odsłoń i zniszcz'**
  String get antiQuantumNoteRevealConfirm;

  /// No description provided for @antiQuantumNoteRevealLoading.
  ///
  /// In pl, this message translates to:
  /// **'Odszyfrowywanie…'**
  String get antiQuantumNoteRevealLoading;

  /// No description provided for @antiQuantumNoteRevealedHeader.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomość odsłonięta · trwale zniszczona'**
  String get antiQuantumNoteRevealedHeader;

  /// No description provided for @antiQuantumNoteRevealedFooter.
  ///
  /// In pl, this message translates to:
  /// **'Notatka została usunięta z serwera. Widać ją już tylko na tym ekranie.'**
  String get antiQuantumNoteRevealedFooter;

  /// No description provided for @antiQuantumNoteRevealClose.
  ///
  /// In pl, this message translates to:
  /// **'Zamknij'**
  String get antiQuantumNoteRevealClose;

  /// No description provided for @antiQuantumNoteRevealRetry.
  ///
  /// In pl, this message translates to:
  /// **'Spróbuj ponownie'**
  String get antiQuantumNoteRevealRetry;

  /// No description provided for @antiQuantumNoteRevealDestroyedBody.
  ///
  /// In pl, this message translates to:
  /// **'Ta notatka została już odczytana i zniszczona. Nie da się jej przywrócić.'**
  String get antiQuantumNoteRevealDestroyedBody;

  /// No description provided for @antiQuantumNoteRevealExpiredTitle.
  ///
  /// In pl, this message translates to:
  /// **'Notatka wygasła'**
  String get antiQuantumNoteRevealExpiredTitle;

  /// No description provided for @antiQuantumNoteRevealExpiredBody.
  ///
  /// In pl, this message translates to:
  /// **'Ta notatka wygasła i zniszczyła się, zanim została odczytana.'**
  String get antiQuantumNoteRevealExpiredBody;

  /// No description provided for @antiQuantumNoteRevealCorruptBody.
  ///
  /// In pl, this message translates to:
  /// **'Notatka została zniszczona, ale nie udało się jej odszyfrować. Link może być uszkodzony.'**
  String get antiQuantumNoteRevealCorruptBody;

  /// No description provided for @antiQuantumNoteRevealInvalidLinkTitle.
  ///
  /// In pl, this message translates to:
  /// **'Uszkodzony link'**
  String get antiQuantumNoteRevealInvalidLinkTitle;

  /// No description provided for @antiQuantumNoteRevealInvalidLinkBody.
  ///
  /// In pl, this message translates to:
  /// **'W tym linku brakuje prawidłowego klucza deszyfrującego. Notatka nie została zniszczona.'**
  String get antiQuantumNoteRevealInvalidLinkBody;

  /// No description provided for @antiQuantumNoteRevealNetworkErrorTitle.
  ///
  /// In pl, this message translates to:
  /// **'Brak połączenia'**
  String get antiQuantumNoteRevealNetworkErrorTitle;

  /// No description provided for @antiQuantumNoteRevealNetworkErrorBody.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się połączyć z serwerem. Sprawdź połączenie i spróbuj ponownie.'**
  String get antiQuantumNoteRevealNetworkErrorBody;

  /// No description provided for @privacyAntiQuantumNoteTitle.
  ///
  /// In pl, this message translates to:
  /// **'Notatki antykwantowe'**
  String get privacyAntiQuantumNoteTitle;

  /// No description provided for @privacyAntiQuantumNoteLead.
  ///
  /// In pl, this message translates to:
  /// **'Samoniszczące notatki z własnym szyfrowaniem.'**
  String get privacyAntiQuantumNoteLead;

  /// No description provided for @privacyAntiQuantumNotePointDevice.
  ///
  /// In pl, this message translates to:
  /// **'Szyfrowane na Twoim urządzeniu, serwer widzi tylko szyfrogram.'**
  String get privacyAntiQuantumNotePointDevice;

  /// No description provided for @privacyAntiQuantumNotePointKey.
  ///
  /// In pl, this message translates to:
  /// **'Klucz jest w linku po #, którego serwer nigdy nie widzi.'**
  String get privacyAntiQuantumNotePointKey;

  /// No description provided for @privacyAntiQuantumNotePointOnce.
  ///
  /// In pl, this message translates to:
  /// **'Notatkę można odczytać dokładnie raz — po czym jest trwale usuwana.'**
  String get privacyAntiQuantumNotePointOnce;

  /// No description provided for @privacyAntiQuantumNotePointTimer.
  ///
  /// In pl, this message translates to:
  /// **'Nieotwarte znikają po 1–24 h.'**
  String get privacyAntiQuantumNotePointTimer;

  /// No description provided for @documentDownloaded.
  ///
  /// In pl, this message translates to:
  /// **'Dokument pobrany'**
  String get documentDownloaded;

  /// No description provided for @documentDownloadFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się pobrać dokumentu'**
  String get documentDownloadFailed;

  /// No description provided for @documentDownloadConfirmTitle.
  ///
  /// In pl, this message translates to:
  /// **'Pobrać dokument?'**
  String get documentDownloadConfirmTitle;

  /// No description provided for @documentDownloadConfirmMessage.
  ///
  /// In pl, this message translates to:
  /// **'Czy chcesz pobrać ten plik?'**
  String get documentDownloadConfirmMessage;

  /// No description provided for @download.
  ///
  /// In pl, this message translates to:
  /// **'Pobierz'**
  String get download;

  /// No description provided for @saveImage.
  ///
  /// In pl, this message translates to:
  /// **'Zapisz obraz'**
  String get saveImage;

  /// No description provided for @copyImage.
  ///
  /// In pl, this message translates to:
  /// **'Kopiuj obraz'**
  String get copyImage;

  /// No description provided for @imageSaved.
  ///
  /// In pl, this message translates to:
  /// **'Zapisano obraz'**
  String get imageSaved;

  /// No description provided for @imageSaveFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się zapisać obrazu'**
  String get imageSaveFailed;

  /// No description provided for @imageCopied.
  ///
  /// In pl, this message translates to:
  /// **'Skopiowano obraz'**
  String get imageCopied;

  /// No description provided for @imageCopyFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się skopiować obrazu'**
  String get imageCopyFailed;

  /// No description provided for @snackbarCouldNotReadFile.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się odczytać pliku'**
  String get snackbarCouldNotReadFile;

  /// No description provided for @snackbarUploadingImage.
  ///
  /// In pl, this message translates to:
  /// **'Wysyłanie zdjęcia…'**
  String get snackbarUploadingImage;

  /// No description provided for @snackbarImageSent.
  ///
  /// In pl, this message translates to:
  /// **'Zdjęcie wysłane!'**
  String get snackbarImageSent;

  /// No description provided for @snackbarUploadingDocument.
  ///
  /// In pl, this message translates to:
  /// **'Wysyłanie dokumentu…'**
  String get snackbarUploadingDocument;

  /// No description provided for @snackbarDocumentSent.
  ///
  /// In pl, this message translates to:
  /// **'Dokument wysłany!'**
  String get snackbarDocumentSent;

  /// No description provided for @snackbarNoActiveConversation.
  ///
  /// In pl, this message translates to:
  /// **'Brak aktywnej rozmowy'**
  String get snackbarNoActiveConversation;

  /// No description provided for @snackbarOpenConversationFirst.
  ///
  /// In pl, this message translates to:
  /// **'Najpierw otwórz rozmowę'**
  String get snackbarOpenConversationFirst;

  /// No description provided for @messageTooLong.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomość jest za długa, aby ją wysłać'**
  String get messageTooLong;

  /// No description provided for @snackbarChatHistoryDeleted.
  ///
  /// In pl, this message translates to:
  /// **'Czat usunięty u obu stron'**
  String get snackbarChatHistoryDeleted;

  /// No description provided for @snackbarFailedToSendImage.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się wysłać zdjęcia'**
  String get snackbarFailedToSendImage;

  /// No description provided for @snackbarMicrophonePermissionRequired.
  ///
  /// In pl, this message translates to:
  /// **'Wymagane jest uprawnienie do mikrofonu'**
  String get snackbarMicrophonePermissionRequired;

  /// No description provided for @snackbarMicrophonePermissionDenied.
  ///
  /// In pl, this message translates to:
  /// **'Odmowa dostępu do mikrofonu'**
  String get snackbarMicrophonePermissionDenied;

  /// No description provided for @snackbarNoMicrophoneFound.
  ///
  /// In pl, this message translates to:
  /// **'Nie znaleziono mikrofonu'**
  String get snackbarNoMicrophoneFound;

  /// No description provided for @snackbarVoiceRecordingRequiresSecureContext.
  ///
  /// In pl, this message translates to:
  /// **'Nagrywanie głosu wymaga HTTPS lub localhost. Użyj https:// lub otwórz z localhost.'**
  String get snackbarVoiceRecordingRequiresSecureContext;

  /// No description provided for @snackbarFailedToStartRecording.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się rozpocząć nagrywania'**
  String get snackbarFailedToStartRecording;

  /// No description provided for @snackbarVoiceRecordingCanceled.
  ///
  /// In pl, this message translates to:
  /// **'Nagrywanie głosu anulowane'**
  String get snackbarVoiceRecordingCanceled;

  /// No description provided for @voiceRecordingSendVoiceTooltip.
  ///
  /// In pl, this message translates to:
  /// **'Wyślij wiadomość głosową'**
  String get voiceRecordingSendVoiceTooltip;

  /// No description provided for @voiceRecordingSendVoiceSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Wyślij wiadomość głosową'**
  String get voiceRecordingSendVoiceSemantics;

  /// No description provided for @voiceRecordingDiscard.
  ///
  /// In pl, this message translates to:
  /// **'Odrzuć nagranie'**
  String get voiceRecordingDiscard;

  /// No description provided for @voiceRecordingSemanticsLabel.
  ///
  /// In pl, this message translates to:
  /// **'Nagrywanie wiadomości głosowej, {time}.'**
  String voiceRecordingSemanticsLabel(String time);

  /// No description provided for @snackbarFailedToReadRecording.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się odczytać nagrania'**
  String get snackbarFailedToReadRecording;

  /// No description provided for @snackbarFailedToSendVoiceMessage.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się wysłać wiadomości głosowej'**
  String get snackbarFailedToSendVoiceMessage;

  /// No description provided for @snackbarAudioNoLongerAvailable.
  ///
  /// In pl, this message translates to:
  /// **'Dźwięk nie jest już dostępny'**
  String get snackbarAudioNoLongerAvailable;

  /// No description provided for @snackbarFailedToLoadAudio.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się wczytać dźwięku'**
  String get snackbarFailedToLoadAudio;

  /// No description provided for @snackbarAllLocalHistoryDeleted.
  ///
  /// In pl, this message translates to:
  /// **'Wszystkie wiadomości zapisane na tym urządzeniu zostały trwale usunięte'**
  String get snackbarAllLocalHistoryDeleted;

  /// No description provided for @snackbarFailedToDeleteAllLocalHistory.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się usunąć części wiadomości z tego urządzenia. Spróbuj ponownie.'**
  String get snackbarFailedToDeleteAllLocalHistory;

  /// No description provided for @friendAcceptedYourRequest.
  ///
  /// In pl, this message translates to:
  /// **'{name} zaakceptował(a) zaproszenie do znajomych'**
  String friendAcceptedYourRequest(String name);

  /// No description provided for @appearance.
  ///
  /// In pl, this message translates to:
  /// **'Wygląd'**
  String get appearance;

  /// No description provided for @appearanceSummary.
  ///
  /// In pl, this message translates to:
  /// **'{theme} · {background}'**
  String appearanceSummary(String theme, String background);

  /// No description provided for @appearanceColorTheme.
  ///
  /// In pl, this message translates to:
  /// **'MOTYW KOLORYSTYCZNY'**
  String get appearanceColorTheme;

  /// No description provided for @appearanceThemeLight.
  ///
  /// In pl, this message translates to:
  /// **'Alabaster'**
  String get appearanceThemeLight;

  /// No description provided for @appearanceThemeTeal.
  ///
  /// In pl, this message translates to:
  /// **'Turkus'**
  String get appearanceThemeTeal;

  /// No description provided for @appearanceThemeDark.
  ///
  /// In pl, this message translates to:
  /// **'Grafit'**
  String get appearanceThemeDark;

  /// No description provided for @appearanceThemeBlue.
  ///
  /// In pl, this message translates to:
  /// **'Błękit'**
  String get appearanceThemeBlue;

  /// No description provided for @appearanceThemeCosmic.
  ///
  /// In pl, this message translates to:
  /// **'Kosmos'**
  String get appearanceThemeCosmic;

  /// No description provided for @themeOptionLight.
  ///
  /// In pl, this message translates to:
  /// **'Jasny ciepły papier z żarowymi akcentami'**
  String get themeOptionLight;

  /// No description provided for @themeOptionDark.
  ///
  /// In pl, this message translates to:
  /// **'Ciemny neutralny grafit z turkusowymi akcentami'**
  String get themeOptionDark;

  /// No description provided for @themeOptionBlue.
  ///
  /// In pl, this message translates to:
  /// **'Głęboki granat z błękitnymi akcentami'**
  String get themeOptionBlue;

  /// No description provided for @themeOptionTealStone.
  ///
  /// In pl, this message translates to:
  /// **'Jasny chłodny kamień z turkusowymi akcentami'**
  String get themeOptionTealStone;

  /// No description provided for @themeOptionCosmic.
  ///
  /// In pl, this message translates to:
  /// **'Ciemny kosmos z lodowoniebieskim światłem'**
  String get themeOptionCosmic;

  /// No description provided for @appearanceChatBackground.
  ///
  /// In pl, this message translates to:
  /// **'TŁO CZATU'**
  String get appearanceChatBackground;

  /// No description provided for @appearanceBackgroundThemeDefault.
  ///
  /// In pl, this message translates to:
  /// **'Domyślne motywu'**
  String get appearanceBackgroundThemeDefault;

  /// No description provided for @appearanceBackgroundThemeDefaultSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Dopasowuje się do wybranego motywu'**
  String get appearanceBackgroundThemeDefaultSubtitle;

  /// No description provided for @appearanceBackgroundThemeDefaultCosmicSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Animowane gwiazdy dla motywu Kosmos'**
  String get appearanceBackgroundThemeDefaultCosmicSubtitle;

  /// No description provided for @appearanceBackgroundPlain.
  ///
  /// In pl, this message translates to:
  /// **'Gładkie'**
  String get appearanceBackgroundPlain;

  /// No description provided for @appearanceBackgroundPlainSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Jednolite tło w kolorach motywu'**
  String get appearanceBackgroundPlainSubtitle;

  /// No description provided for @appearanceBackgroundGlyphs.
  ///
  /// In pl, this message translates to:
  /// **'Hieroglify'**
  String get appearanceBackgroundGlyphs;

  /// No description provided for @appearanceBackgroundGlyphsSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Wzór świątynnych kolumn'**
  String get appearanceBackgroundGlyphsSubtitle;

  /// No description provided for @appearanceBackgroundStarfield.
  ///
  /// In pl, this message translates to:
  /// **'Gwiazdy'**
  String get appearanceBackgroundStarfield;

  /// No description provided for @rotateDeviceTitle.
  ///
  /// In pl, this message translates to:
  /// **'Obróć urządzenie'**
  String get rotateDeviceTitle;

  /// No description provided for @rotateDeviceMessage.
  ///
  /// In pl, this message translates to:
  /// **'Umbra działa tylko w trybie pionowym.'**
  String get rotateDeviceMessage;

  /// No description provided for @messageActionReply.
  ///
  /// In pl, this message translates to:
  /// **'Odpowiedz'**
  String get messageActionReply;

  /// No description provided for @messageActionCopy.
  ///
  /// In pl, this message translates to:
  /// **'Kopiuj'**
  String get messageActionCopy;

  /// No description provided for @messageActionEdit.
  ///
  /// In pl, this message translates to:
  /// **'Edytuj'**
  String get messageActionEdit;

  /// No description provided for @messageActionPin.
  ///
  /// In pl, this message translates to:
  /// **'Przypnij'**
  String get messageActionPin;

  /// No description provided for @messageActionDelete.
  ///
  /// In pl, this message translates to:
  /// **'Usuń'**
  String get messageActionDelete;

  /// No description provided for @messageDeleteDialogTitle.
  ///
  /// In pl, this message translates to:
  /// **'Usunąć wiadomość?'**
  String get messageDeleteDialogTitle;

  /// No description provided for @messageDeleteForMe.
  ///
  /// In pl, this message translates to:
  /// **'Usuń u mnie'**
  String get messageDeleteForMe;

  /// No description provided for @messageDeleteForEveryone.
  ///
  /// In pl, this message translates to:
  /// **'Usuń dla wszystkich'**
  String get messageDeleteForEveryone;

  /// No description provided for @messageEditedLabel.
  ///
  /// In pl, this message translates to:
  /// **'edytowano'**
  String get messageEditedLabel;

  /// No description provided for @messageEditingTitle.
  ///
  /// In pl, this message translates to:
  /// **'Edytowanie wiadomości'**
  String get messageEditingTitle;

  /// No description provided for @messagePinRequiresSentMessage.
  ///
  /// In pl, this message translates to:
  /// **'Poczekaj na wysłanie wiadomości, aby ją przypiąć'**
  String get messagePinRequiresSentMessage;

  /// No description provided for @messageReactionMoreEmoji.
  ///
  /// In pl, this message translates to:
  /// **'Więcej reakcji emoji'**
  String get messageReactionMoreEmoji;

  /// No description provided for @messageReactionSelected.
  ///
  /// In pl, this message translates to:
  /// **'wybrana'**
  String get messageReactionSelected;

  /// No description provided for @messageReactionNotSelected.
  ///
  /// In pl, this message translates to:
  /// **'niewybrana'**
  String get messageReactionNotSelected;

  /// No description provided for @messageReactionSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Reakcja {emoji}, {state}'**
  String messageReactionSemantics(Object emoji, Object state);

  /// No description provided for @messageReactionUnreadable.
  ///
  /// In pl, this message translates to:
  /// **'Reakcja nieczytelna na tym urządzeniu ({count})'**
  String messageReactionUnreadable(int count);

  /// No description provided for @snackbarReactionUnavailable.
  ///
  /// In pl, this message translates to:
  /// **'Reakcje nie są jeszcze gotowe na tym urządzeniu'**
  String get snackbarReactionUnavailable;

  /// No description provided for @snackbarBoxReactionFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się wysłać reakcji. Spróbuj ponownie.'**
  String get snackbarBoxReactionFailed;

  /// No description provided for @snackbarBoxPinFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się zmienić przypięcia. Spróbuj ponownie.'**
  String get snackbarBoxPinFailed;

  /// No description provided for @snackbarBoxEditFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się zapisać edycji. Spróbuj ponownie.'**
  String get snackbarBoxEditFailed;

  /// No description provided for @snackbarBoxDeleteFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się usunąć wiadomości u wszystkich. Spróbuj ponownie.'**
  String get snackbarBoxDeleteFailed;

  /// No description provided for @snackbarPinnedMessageUnavailable.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomość jest niedostępna'**
  String get snackbarPinnedMessageUnavailable;

  /// No description provided for @snackbarMessageCopied.
  ///
  /// In pl, this message translates to:
  /// **'Skopiowano wiadomość'**
  String get snackbarMessageCopied;

  /// No description provided for @composerAttachmentRemoveTooltip.
  ///
  /// In pl, this message translates to:
  /// **'Usuń załącznik'**
  String get composerAttachmentRemoveTooltip;

  /// No description provided for @snackbarPastedImageTooLarge.
  ///
  /// In pl, this message translates to:
  /// **'Obraz jest za duży (maks. 20 MB)'**
  String get snackbarPastedImageTooLarge;

  /// No description provided for @snackbarPastedImageUnsupported.
  ///
  /// In pl, this message translates to:
  /// **'Nie można wkleić tego typu obrazu'**
  String get snackbarPastedImageUnsupported;

  /// No description provided for @snackbarPastedImageUnavailable.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się odczytać wklejonego obrazu'**
  String get snackbarPastedImageUnavailable;

  /// No description provided for @pinnedMessageUnpinTooltip.
  ///
  /// In pl, this message translates to:
  /// **'Odepnij'**
  String get pinnedMessageUnpinTooltip;

  /// No description provided for @pinnedMessageBannerSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Przypięta wiadomość'**
  String get pinnedMessageBannerSemantics;

  /// No description provided for @userCardAbout.
  ///
  /// In pl, this message translates to:
  /// **'O mnie'**
  String get userCardAbout;

  /// No description provided for @userCardMyProfile.
  ///
  /// In pl, this message translates to:
  /// **'Mój profil'**
  String get userCardMyProfile;

  /// No description provided for @userCardEditAbout.
  ///
  /// In pl, this message translates to:
  /// **'Edytuj opis'**
  String get userCardEditAbout;

  /// No description provided for @userCardAddPhoto.
  ///
  /// In pl, this message translates to:
  /// **'Dodaj zdjęcie'**
  String get userCardAddPhoto;

  /// No description provided for @userCardPhotoLimitReached.
  ///
  /// In pl, this message translates to:
  /// **'Osiągnięto limit zdjęć'**
  String get userCardPhotoLimitReached;

  /// No description provided for @userCardSetMainPhoto.
  ///
  /// In pl, this message translates to:
  /// **'Ustaw jako główne zdjęcie'**
  String get userCardSetMainPhoto;

  /// No description provided for @userCardDeletePhoto.
  ///
  /// In pl, this message translates to:
  /// **'Usuń to zdjęcie'**
  String get userCardDeletePhoto;

  /// No description provided for @userCardSave.
  ///
  /// In pl, this message translates to:
  /// **'Zapisz'**
  String get userCardSave;

  /// No description provided for @userCardCancel.
  ///
  /// In pl, this message translates to:
  /// **'Anuluj'**
  String get userCardCancel;

  /// No description provided for @userCardBack.
  ///
  /// In pl, this message translates to:
  /// **'Wstecz'**
  String get userCardBack;

  /// No description provided for @userCardNotificationsOn.
  ///
  /// In pl, this message translates to:
  /// **'Powiadomienia włączone'**
  String get userCardNotificationsOn;

  /// No description provided for @userCardMuteOneHour.
  ///
  /// In pl, this message translates to:
  /// **'Wycisz na 1 godzinę'**
  String get userCardMuteOneHour;

  /// No description provided for @userCardMuteEightHours.
  ///
  /// In pl, this message translates to:
  /// **'Wycisz na 8 godzin'**
  String get userCardMuteEightHours;

  /// No description provided for @userCardMuteOneWeek.
  ///
  /// In pl, this message translates to:
  /// **'Wycisz na tydzień'**
  String get userCardMuteOneWeek;

  /// No description provided for @userCardMuteForever.
  ///
  /// In pl, this message translates to:
  /// **'Wycisz na zawsze'**
  String get userCardMuteForever;

  /// No description provided for @userCardMessage.
  ///
  /// In pl, this message translates to:
  /// **'Wiadomość'**
  String get userCardMessage;

  /// No description provided for @userCardMute.
  ///
  /// In pl, this message translates to:
  /// **'Wycisz'**
  String get userCardMute;

  /// No description provided for @userCardMuted.
  ///
  /// In pl, this message translates to:
  /// **'Wyciszono'**
  String get userCardMuted;

  /// No description provided for @userCardCopyTag.
  ///
  /// In pl, this message translates to:
  /// **'Kopiuj tag'**
  String get userCardCopyTag;

  /// No description provided for @userCardManagePhotos.
  ///
  /// In pl, this message translates to:
  /// **'Zarządzaj zdjęciami'**
  String get userCardManagePhotos;

  /// No description provided for @userCardPhotoOfCount.
  ///
  /// In pl, this message translates to:
  /// **'Zdjęcie {index} z {count}'**
  String userCardPhotoOfCount(Object index, Object count);

  /// No description provided for @userCardMainPhotoHint.
  ///
  /// In pl, this message translates to:
  /// **'To jest Twoje główne zdjęcie — kontakty widzą je na czatach.'**
  String get userCardMainPhotoHint;

  /// No description provided for @userCardAboutHint.
  ///
  /// In pl, this message translates to:
  /// **'Kilka słów o Tobie'**
  String get userCardAboutHint;

  /// No description provided for @userCardSharedMedia.
  ///
  /// In pl, this message translates to:
  /// **'Udostępnione multimedia'**
  String get userCardSharedMedia;

  /// No description provided for @userCardDragReorderHint.
  ///
  /// In pl, this message translates to:
  /// **'Przytrzymaj i przeciągnij, aby zmienić kolejność — pierwsze zdjęcie jest Twoim głównym.'**
  String get userCardDragReorderHint;

  /// No description provided for @settingsChatBackground.
  ///
  /// In pl, this message translates to:
  /// **'Tło czatu'**
  String get settingsChatBackground;

  /// No description provided for @userCardCopyHandle.
  ///
  /// In pl, this message translates to:
  /// **'Kopiuj nazwę użytkownika i tag'**
  String get userCardCopyHandle;

  /// No description provided for @userCardCopiedHandle.
  ///
  /// In pl, this message translates to:
  /// **'Skopiowano {handle}'**
  String userCardCopiedHandle(Object handle);

  /// No description provided for @userCardNotificationsMuted.
  ///
  /// In pl, this message translates to:
  /// **'Powiadomienia wyciszone'**
  String get userCardNotificationsMuted;

  /// No description provided for @userCardBlockTitle.
  ///
  /// In pl, this message translates to:
  /// **'Zablokować {handle}?'**
  String userCardBlockTitle(Object handle);

  /// No description provided for @userCardBlockConfirm.
  ///
  /// In pl, this message translates to:
  /// **'Nie będzie można wysyłać wiadomości do tego kontaktu.'**
  String get userCardBlockConfirm;

  /// No description provided for @userCardDeletePhotoTitle.
  ///
  /// In pl, this message translates to:
  /// **'Usunąć zdjęcie?'**
  String get userCardDeletePhotoTitle;

  /// No description provided for @userCardDeletePhotoConfirm.
  ///
  /// In pl, this message translates to:
  /// **'To trwale usuwa to zdjęcie profilowe.'**
  String get userCardDeletePhotoConfirm;

  /// No description provided for @userCardSafety.
  ///
  /// In pl, this message translates to:
  /// **'Bezpieczeństwo'**
  String get userCardSafety;

  /// No description provided for @userCardRemoveContact.
  ///
  /// In pl, this message translates to:
  /// **'Usuń kontakt'**
  String get userCardRemoveContact;

  /// No description provided for @messageReadMore.
  ///
  /// In pl, this message translates to:
  /// **'Czytaj więcej'**
  String get messageReadMore;

  /// No description provided for @messageShowLess.
  ///
  /// In pl, this message translates to:
  /// **'Zwiń'**
  String get messageShowLess;

  /// No description provided for @chatPickerTitle.
  ///
  /// In pl, this message translates to:
  /// **'Wybierz znajomego'**
  String get chatPickerTitle;

  /// No description provided for @chatPickerSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Wybierz węzeł, aby rozpocząć czat'**
  String get chatPickerSubtitle;

  /// No description provided for @chatPickerEmptyTitle.
  ///
  /// In pl, this message translates to:
  /// **'Nie masz jeszcze znajomych'**
  String get chatPickerEmptyTitle;

  /// No description provided for @chatPickerEmptyDescription.
  ///
  /// In pl, this message translates to:
  /// **'Dodaj znajomego, aby rozpocząć czat.'**
  String get chatPickerEmptyDescription;

  /// No description provided for @chatPickerOpenTooltip.
  ///
  /// In pl, this message translates to:
  /// **'Nowy czat'**
  String get chatPickerOpenTooltip;

  /// No description provided for @chatPickerInviteButton.
  ///
  /// In pl, this message translates to:
  /// **'Zaproś kogoś'**
  String get chatPickerInviteButton;

  /// No description provided for @videoMessage.
  ///
  /// In pl, this message translates to:
  /// **'Wideo'**
  String get videoMessage;

  /// No description provided for @videoTooLarge.
  ///
  /// In pl, this message translates to:
  /// **'Wideo jest za duże ({size} MB, maks. 20 MB)'**
  String videoTooLarge(String size);

  /// No description provided for @videoTooLong.
  ///
  /// In pl, this message translates to:
  /// **'Wideo jest za długie ({duration}, maks. 3 minuty)'**
  String videoTooLong(String duration);

  /// No description provided for @videoCompressing.
  ///
  /// In pl, this message translates to:
  /// **'Kompresowanie wideo…'**
  String get videoCompressing;

  /// No description provided for @videoUnsupportedFormat.
  ///
  /// In pl, this message translates to:
  /// **'Nieobsługiwany format wideo (tylko MP4)'**
  String get videoUnsupportedFormat;

  /// No description provided for @videoFailedToLoad.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się załadować wideo'**
  String get videoFailedToLoad;

  /// No description provided for @videoStillSending.
  ///
  /// In pl, this message translates to:
  /// **'Trwa wysyłanie…'**
  String get videoStillSending;

  /// No description provided for @videoUnmute.
  ///
  /// In pl, this message translates to:
  /// **'Włącz dźwięk'**
  String get videoUnmute;

  /// No description provided for @videoMute.
  ///
  /// In pl, this message translates to:
  /// **'Wycisz'**
  String get videoMute;

  /// No description provided for @videoSenderYou.
  ///
  /// In pl, this message translates to:
  /// **'Ty'**
  String get videoSenderYou;

  /// No description provided for @settingsAutoplayVideos.
  ///
  /// In pl, this message translates to:
  /// **'Autoodtwarzanie wideo'**
  String get settingsAutoplayVideos;

  /// No description provided for @settingsAutoplayVideosSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Wideo w czacie odtwarzają się bez dźwięku, gdy są widoczne'**
  String get settingsAutoplayVideosSubtitle;

  /// No description provided for @attachmentUnsupportedFileType.
  ///
  /// In pl, this message translates to:
  /// **'Nieobsługiwany typ pliku'**
  String get attachmentUnsupportedFileType;

  /// No description provided for @chatScrollToBottomSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Przewiń do najnowszych wiadomości'**
  String get chatScrollToBottomSemantics;

  /// No description provided for @avatarOpenProfileSemantics.
  ///
  /// In pl, this message translates to:
  /// **'Otwórz profil'**
  String get avatarOpenProfileSemantics;

  /// No description provided for @passcodeLock.
  ///
  /// In pl, this message translates to:
  /// **'Blokada kodem'**
  String get passcodeLock;

  /// No description provided for @passcodeStateOn.
  ///
  /// In pl, this message translates to:
  /// **'Włączona'**
  String get passcodeStateOn;

  /// No description provided for @passcodeStateOff.
  ///
  /// In pl, this message translates to:
  /// **'Wyłączona'**
  String get passcodeStateOff;

  /// No description provided for @passcodeIntro.
  ///
  /// In pl, this message translates to:
  /// **'Możesz dodać blokadę kodem do Umbry, aby Twoje konto było bardziej prywatne.'**
  String get passcodeIntro;

  /// No description provided for @passcodeTurnOn.
  ///
  /// In pl, this message translates to:
  /// **'Włącz blokadę kodem'**
  String get passcodeTurnOn;

  /// No description provided for @passcodeTurnOff.
  ///
  /// In pl, this message translates to:
  /// **'Wyłącz blokadę kodem'**
  String get passcodeTurnOff;

  /// No description provided for @passcodeChange.
  ///
  /// In pl, this message translates to:
  /// **'Zmień kod'**
  String get passcodeChange;

  /// No description provided for @passcodeAutoLock.
  ///
  /// In pl, this message translates to:
  /// **'Automatyczna blokada'**
  String get passcodeAutoLock;

  /// No description provided for @passcodeAutoLockImmediately.
  ///
  /// In pl, this message translates to:
  /// **'Natychmiast'**
  String get passcodeAutoLockImmediately;

  /// No description provided for @passcodeAutoLockMinute.
  ///
  /// In pl, this message translates to:
  /// **'Po 1 minucie'**
  String get passcodeAutoLockMinute;

  /// No description provided for @passcodeAutoLockFiveMinutes.
  ///
  /// In pl, this message translates to:
  /// **'Po 5 minutach'**
  String get passcodeAutoLockFiveMinutes;

  /// No description provided for @passcodeAutoLockHour.
  ///
  /// In pl, this message translates to:
  /// **'Po 1 godzinie'**
  String get passcodeAutoLockHour;

  /// No description provided for @passcodeEnterTitle.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz kod'**
  String get passcodeEnterTitle;

  /// No description provided for @passcodeSetTitle.
  ///
  /// In pl, this message translates to:
  /// **'Ustaw kod'**
  String get passcodeSetTitle;

  /// No description provided for @passcodeRepeatTitle.
  ///
  /// In pl, this message translates to:
  /// **'Powtórz kod'**
  String get passcodeRepeatTitle;

  /// No description provided for @passcodeCurrentTitle.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz obecny kod'**
  String get passcodeCurrentTitle;

  /// No description provided for @passcodeOptions.
  ///
  /// In pl, this message translates to:
  /// **'Opcje kodu'**
  String get passcodeOptions;

  /// No description provided for @passcodeOptionCustom.
  ///
  /// In pl, this message translates to:
  /// **'Własny kod alfanumeryczny'**
  String get passcodeOptionCustom;

  /// No description provided for @passcodeOptionSixDigits.
  ///
  /// In pl, this message translates to:
  /// **'6-cyfrowy kod'**
  String get passcodeOptionSixDigits;

  /// No description provided for @passcodeOptionFourDigits.
  ///
  /// In pl, this message translates to:
  /// **'4-cyfrowy kod'**
  String get passcodeOptionFourDigits;

  /// No description provided for @passcodeConfirmAction.
  ///
  /// In pl, this message translates to:
  /// **'Zatwierdź'**
  String get passcodeConfirmAction;

  /// No description provided for @passcodeCustomHint.
  ///
  /// In pl, this message translates to:
  /// **'Kod dostępu'**
  String get passcodeCustomHint;

  /// No description provided for @passcodeWrong.
  ///
  /// In pl, this message translates to:
  /// **'Nieprawidłowy kod. Spróbuj ponownie.'**
  String get passcodeWrong;

  /// No description provided for @passcodeMismatch.
  ///
  /// In pl, this message translates to:
  /// **'Kody nie są takie same. Zacznij od nowa.'**
  String get passcodeMismatch;

  /// No description provided for @passcodeTooShort.
  ///
  /// In pl, this message translates to:
  /// **'Użyj co najmniej 4 znaków.'**
  String get passcodeTooShort;

  /// No description provided for @passcodeBlocked.
  ///
  /// In pl, this message translates to:
  /// **'Zbyt wiele prób. Spróbuj ponownie za {seconds} s.'**
  String passcodeBlocked(int seconds);

  /// No description provided for @passcodeUnavailable.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się zabezpieczyć kodu na tym urządzeniu.'**
  String get passcodeUnavailable;

  /// No description provided for @passcodeCredentialLoading.
  ///
  /// In pl, this message translates to:
  /// **'Odczytywanie zabezpieczeń urządzenia…'**
  String get passcodeCredentialLoading;

  /// No description provided for @passcodeForgot.
  ///
  /// In pl, this message translates to:
  /// **'Nie pamiętasz kodu?'**
  String get passcodeForgot;

  /// No description provided for @passcodeNoRecovery.
  ///
  /// In pl, this message translates to:
  /// **'Zapomnianego kodu nie da się odzyskać.'**
  String get passcodeNoRecovery;

  /// No description provided for @passcodeEraseWarning.
  ///
  /// In pl, this message translates to:
  /// **'Usunie dane aplikacji. Wiadomości tylko stąd znikną na zawsze.'**
  String get passcodeEraseWarning;

  /// No description provided for @passcodeEraseConfirmWord.
  ///
  /// In pl, this message translates to:
  /// **'USUN'**
  String get passcodeEraseConfirmWord;

  /// No description provided for @passcodeEraseConfirmHint.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz {word}, aby potwierdzić'**
  String passcodeEraseConfirmHint(String word);

  /// No description provided for @passcodeEraseAction.
  ///
  /// In pl, this message translates to:
  /// **'Usuń dane i wyloguj'**
  String get passcodeEraseAction;

  /// No description provided for @passcodeErasing.
  ///
  /// In pl, this message translates to:
  /// **'Usuwanie…'**
  String get passcodeErasing;

  /// No description provided for @passcodeErasePartial.
  ///
  /// In pl, this message translates to:
  /// **'Nie wszystko usunięto. Spróbuj ponownie.'**
  String get passcodeErasePartial;

  /// No description provided for @passcodeAttemptsLeft.
  ///
  /// In pl, this message translates to:
  /// **'{count, plural, one{Została 1 próba przed przerwą} few{Zostały {count} próby przed przerwą} many{Zostało {count} prób przed przerwą} other{Zostało {count} próby przed przerwą}}'**
  String passcodeAttemptsLeft(num count);

  /// No description provided for @passcodeLockNowTooltip.
  ///
  /// In pl, this message translates to:
  /// **'Zablokuj aplikację'**
  String get passcodeLockNowTooltip;

  /// No description provided for @passcodeSetUpTooltip.
  ///
  /// In pl, this message translates to:
  /// **'Ustaw blokadę kodem'**
  String get passcodeSetUpTooltip;

  /// No description provided for @passcodeNote.
  ///
  /// In pl, this message translates to:
  /// **'Zapomnisz kodu — jedyne wyjście to usunięcie danych aplikacji.'**
  String get passcodeNote;

  /// No description provided for @passcodeScopeNoteDevice.
  ///
  /// In pl, this message translates to:
  /// **'Blokuje aplikację na tym urządzeniu. Nie trafia na serwer.'**
  String get passcodeScopeNoteDevice;

  /// No description provided for @passcodeScopeNoteBrowser.
  ///
  /// In pl, this message translates to:
  /// **'Szyfruje klucze w tej przeglądarce. Nie trafia na serwer.'**
  String get passcodeScopeNoteBrowser;

  /// No description provided for @passcodeTooWeakForKeys.
  ///
  /// In pl, this message translates to:
  /// **'Własny kod: min. 6 znaków, nie tylko cyfry.'**
  String get passcodeTooWeakForKeys;

  /// No description provided for @passcodeEraseWarningEnrolled.
  ///
  /// In pl, this message translates to:
  /// **'Usunie dane aplikacji. Potem przywrócisz konto frazą, z innego urządzenia lub resetem.'**
  String get passcodeEraseWarningEnrolled;

  /// No description provided for @linkScanAction.
  ///
  /// In pl, this message translates to:
  /// **'Zeskanuj kod'**
  String get linkScanAction;

  /// No description provided for @linkShowCodeAction.
  ///
  /// In pl, this message translates to:
  /// **'Pokaż kod'**
  String get linkShowCodeAction;

  /// No description provided for @linkScanHint.
  ///
  /// In pl, this message translates to:
  /// **'Skieruj aparat na kod QR z drugiego urządzenia.'**
  String get linkScanHint;

  /// No description provided for @linkScanCameraDenied.
  ///
  /// In pl, this message translates to:
  /// **'Brak dostępu do aparatu. Wpisz kod ręcznie.'**
  String get linkScanCameraDenied;

  /// No description provided for @linkScanUnsupported.
  ///
  /// In pl, this message translates to:
  /// **'Ta przeglądarka nie obsługuje skanowania. Wpisz kod ręcznie.'**
  String get linkScanUnsupported;

  /// No description provided for @linkEnterCodeManually.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz kod ręcznie'**
  String get linkEnterCodeManually;

  /// No description provided for @linkNewCodeLabel.
  ///
  /// In pl, this message translates to:
  /// **'Kod z urządzenia głównego'**
  String get linkNewCodeLabel;

  /// No description provided for @linkPrimaryShowCodeExplainer.
  ///
  /// In pl, this message translates to:
  /// **'Zeskanuj ten kod nowym urządzeniem.'**
  String get linkPrimaryShowCodeExplainer;

  /// No description provided for @linkGateScanBody.
  ///
  /// In pl, this message translates to:
  /// **'Zeskanuj kod z urządzenia głównego albo pokaż mu ten.'**
  String get linkGateScanBody;

  /// No description provided for @recoveryKeyBackupExplainer.
  ///
  /// In pl, this message translates to:
  /// **'Te 12 słów odzyskuje hasło i konto po utracie urządzenia. Kto je zna, ma Twoje konto. Pokazujemy je raz.'**
  String get recoveryKeyBackupExplainer;

  /// No description provided for @recoveryKeyConfirmTitle.
  ///
  /// In pl, this message translates to:
  /// **'Potwierdź, że masz słowa zapisane'**
  String get recoveryKeyConfirmTitle;

  /// No description provided for @recoveryKeyConfirmPrompt.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz słowo nr {n}'**
  String recoveryKeyConfirmPrompt(int n);

  /// No description provided for @recoveryKeyConfirmMismatch.
  ///
  /// In pl, this message translates to:
  /// **'To nie to słowo. Sprawdź zapisane słowa.'**
  String get recoveryKeyConfirmMismatch;

  /// No description provided for @recoveryKeyConfirmAction.
  ///
  /// In pl, this message translates to:
  /// **'Potwierdź'**
  String get recoveryKeyConfirmAction;

  /// No description provided for @recoveryKeyLaterAction.
  ///
  /// In pl, this message translates to:
  /// **'Później'**
  String get recoveryKeyLaterAction;

  /// No description provided for @recoveryKeyReplacesExisting.
  ///
  /// In pl, this message translates to:
  /// **'Masz już frazę. Nowe słowa ją zastąpią — stare przestaną działać.'**
  String get recoveryKeyReplacesExisting;

  /// No description provided for @backupNudgeTitle.
  ///
  /// In pl, this message translates to:
  /// **'Zabezpiecz konto — utwórz 12 słów'**
  String get backupNudgeTitle;

  /// No description provided for @recoveryKeyRequiredForLinking.
  ///
  /// In pl, this message translates to:
  /// **'Łączenie wymaga frazy odzyskiwania — utworzysz ją za chwilę.'**
  String get recoveryKeyRequiredForLinking;

  /// No description provided for @linkGateRestoreAction.
  ///
  /// In pl, this message translates to:
  /// **'Mam frazę odzyskiwania'**
  String get linkGateRestoreAction;

  /// No description provided for @linkGateRestoreTitle.
  ///
  /// In pl, this message translates to:
  /// **'Przywróć konto z frazy'**
  String get linkGateRestoreTitle;

  /// No description provided for @linkGateRestoreBody.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz 12 słów. To urządzenie stanie się głównym.'**
  String get linkGateRestoreBody;

  /// No description provided for @linkGateRestoring.
  ///
  /// In pl, this message translates to:
  /// **'Przywracam klucze…'**
  String get linkGateRestoring;

  /// No description provided for @linkGateRestoreWrongPhrase.
  ///
  /// In pl, this message translates to:
  /// **'Fraza nie pasuje do kopii kluczy tego konta.'**
  String get linkGateRestoreWrongPhrase;

  /// No description provided for @linkGateRestoreNoBackup.
  ///
  /// In pl, this message translates to:
  /// **'Brak kopii kluczy. Połącz z urządzenia głównego albo zresetuj.'**
  String get linkGateRestoreNoBackup;

  /// No description provided for @linkGateRestoreFailed.
  ///
  /// In pl, this message translates to:
  /// **'Przywracanie nie powiodło się. Spróbuj ponownie.'**
  String get linkGateRestoreFailed;

  /// No description provided for @linkGateRestoreDone.
  ///
  /// In pl, this message translates to:
  /// **'Konto przywrócone.'**
  String get linkGateRestoreDone;

  /// No description provided for @devicesBackupMissing.
  ///
  /// In pl, this message translates to:
  /// **'Brak kopii kluczy. Utwórz frazę odzyskiwania.'**
  String get devicesBackupMissing;

  /// No description provided for @devicesCreateBackupAction.
  ///
  /// In pl, this message translates to:
  /// **'Utwórz frazę odzyskiwania'**
  String get devicesCreateBackupAction;

  /// No description provided for @deviceRevokedRestoredNotice.
  ///
  /// In pl, this message translates to:
  /// **'Konto przywrócono na innym urządzeniu. Połącz to ponownie.'**
  String get deviceRevokedRestoredNotice;

  /// No description provided for @peerIdentityChangedSystemLine.
  ///
  /// In pl, this message translates to:
  /// **'{name}: nowe urządzenie lub przeglądarka — klucze zaktualizowane.'**
  String peerIdentityChangedSystemLine(String name);

  /// No description provided for @settingsKeyChangeWarnings.
  ///
  /// In pl, this message translates to:
  /// **'Ostrzegaj o zmianie kluczy kontaktów'**
  String get settingsKeyChangeWarnings;

  /// No description provided for @settingsKeyChangeWarningsSubtitle.
  ///
  /// In pl, this message translates to:
  /// **'Domyślnie nowe klucze są przyjmowane, a w czacie pojawia się krótka notatka.'**
  String get settingsKeyChangeWarningsSubtitle;

  /// Button/tooltip that opens the rename sheet for one device row ((lxxx) clause 1).
  ///
  /// In pl, this message translates to:
  /// **'Zmień nazwę'**
  String get devicesRenameAction;

  /// Title of the rename sheet.
  ///
  /// In pl, this message translates to:
  /// **'Nazwa urządzenia'**
  String get devicesRenameTitle;

  /// Placeholder in the rename field — an example, never a default.
  ///
  /// In pl, this message translates to:
  /// **'np. Telefon Ani'**
  String get devicesRenameHint;

  /// Confirms the rename; signs a new device list.
  ///
  /// In pl, this message translates to:
  /// **'Zapisz'**
  String get devicesRenameSave;

  /// Tells the user that submitting an empty field clears the name instead of storing an empty one.
  ///
  /// In pl, this message translates to:
  /// **'Puste pole usuwa nazwę.'**
  String get devicesRenameClearHint;

  /// Shown when the signed list mutation was refused or never answered.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się zmienić nazwy. Spróbuj ponownie.'**
  String get devicesRenameFailed;

  /// Shown when a device name is refused BEFORE signing because it is not NFC-normalized ((lxxx) clause 1) — the storage gate would refuse it as invalid_canonical.
  ///
  /// In pl, this message translates to:
  /// **'Ta nazwa zawiera znaki, których nie zapiszemy. Wpisz ją z klawiatury, zamiast wklejać.'**
  String get devicesRenameNotStorable;

  /// Title of the sideloaded-APK update offer.
  ///
  /// In pl, this message translates to:
  /// **'Nowa wersja aplikacji'**
  String get updateAvailableTitle;

  /// Body of the update offer. Names the version and states that an in-place install keeps keys; uninstalling is the action that destroys them.
  ///
  /// In pl, this message translates to:
  /// **'Dostępna jest wersja {version}. Pobierz i zainstaluj ją na tym telefonie — Twoje wiadomości i klucze zostaną zachowane. Nie odinstalowuj aplikacji.'**
  String updateAvailableBody(String version);

  /// Opens the APK download link in the browser.
  ///
  /// In pl, this message translates to:
  /// **'Pobierz'**
  String get updateAvailableDownload;

  /// Dismisses the offer for this exact build; a later build still prompts.
  ///
  /// In pl, this message translates to:
  /// **'Później'**
  String get updateAvailableLater;

  /// No description provided for @backupPassphraseCreateTitle.
  ///
  /// In pl, this message translates to:
  /// **'Ustaw hasło kopii'**
  String get backupPassphraseCreateTitle;

  /// No description provided for @backupPassphraseCreateBody.
  ///
  /// In pl, this message translates to:
  /// **'Plik kopii jest bezużyteczny bez tego hasła. Nikt go nie odzyska — ani serwer, ani autor aplikacji. Zapisz hasło w bezpiecznym miejscu.'**
  String get backupPassphraseCreateBody;

  /// No description provided for @backupPassphraseEnterTitle.
  ///
  /// In pl, this message translates to:
  /// **'Podaj hasło kopii'**
  String get backupPassphraseEnterTitle;

  /// No description provided for @backupPassphraseEnterBody.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz hasło, którym zabezpieczono ten plik kopii.'**
  String get backupPassphraseEnterBody;

  /// No description provided for @backupPassphraseLabel.
  ///
  /// In pl, this message translates to:
  /// **'Hasło kopii'**
  String get backupPassphraseLabel;

  /// No description provided for @backupPassphraseRepeatLabel.
  ///
  /// In pl, this message translates to:
  /// **'Powtórz hasło'**
  String get backupPassphraseRepeatLabel;

  /// No description provided for @backupPassphraseReveal.
  ///
  /// In pl, this message translates to:
  /// **'Pokaż hasło'**
  String get backupPassphraseReveal;

  /// No description provided for @backupPassphraseHide.
  ///
  /// In pl, this message translates to:
  /// **'Ukryj hasło'**
  String get backupPassphraseHide;

  /// No description provided for @backupPassphraseMismatch.
  ///
  /// In pl, this message translates to:
  /// **'Hasła nie są identyczne.'**
  String get backupPassphraseMismatch;

  /// Inline error under the passphrase fields when the chosen passphrase is below the floor.
  ///
  /// In pl, this message translates to:
  /// **'Hasło musi mieć co najmniej {min} znaków.'**
  String backupPassphraseTooShort(int min);

  /// No description provided for @backupPassphraseRequired.
  ///
  /// In pl, this message translates to:
  /// **'Wpisz hasło.'**
  String get backupPassphraseRequired;

  /// No description provided for @backupPassphraseCreateAction.
  ///
  /// In pl, this message translates to:
  /// **'Zapisz kopię'**
  String get backupPassphraseCreateAction;

  /// No description provided for @backupPassphraseEnterAction.
  ///
  /// In pl, this message translates to:
  /// **'Przywróć'**
  String get backupPassphraseEnterAction;

  /// No description provided for @historyBackupTitle.
  ///
  /// In pl, this message translates to:
  /// **'Kopia historii wiadomości'**
  String get historyBackupTitle;

  /// No description provided for @historyBackupDescription.
  ///
  /// In pl, this message translates to:
  /// **'Zapisuje do pliku odszyfrowaną historię wiadomości i listę kontaktów z tego urządzenia. Plik jest zaszyfrowany hasłem, które sam ustawisz.'**
  String get historyBackupDescription;

  /// No description provided for @historyBackupExportButton.
  ///
  /// In pl, this message translates to:
  /// **'Zapisz kopię do pliku'**
  String get historyBackupExportButton;

  /// No description provided for @historyBackupImportTitle.
  ///
  /// In pl, this message translates to:
  /// **'Przywracanie z kopii'**
  String get historyBackupImportTitle;

  /// No description provided for @historyBackupImportDescription.
  ///
  /// In pl, this message translates to:
  /// **'Wczytuje plik kopii z powrotem na to urządzenie. Wiadomości, które już tu są, zostają bez zmian.'**
  String get historyBackupImportDescription;

  /// No description provided for @historyBackupImportButton.
  ///
  /// In pl, this message translates to:
  /// **'Przywróć z pliku kopii'**
  String get historyBackupImportButton;

  /// Success toast after a backup file was handed to the platform. Names what went in so the user can judge whether it looks complete.
  ///
  /// In pl, this message translates to:
  /// **'Zapisano kopię: {records} wiadomości, {contacts} kontaktów'**
  String snackbarHistoryBackupExported(int records, int contacts);

  /// No description provided for @snackbarHistoryBackupExportFailed.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się zapisać kopii. Spróbuj ponownie.'**
  String get snackbarHistoryBackupExportFailed;

  /// Success toast after an import. Counts are what was written back, not what the file held.
  ///
  /// In pl, this message translates to:
  /// **'Przywrócono z kopii: {records} wiadomości, {contacts} kontaktów'**
  String snackbarHistoryBackupImported(int records, int contacts);

  /// Last-resort toast for an import that failed for a reason the codec taxonomy does not name — a store write that could not complete, say. Deliberately blames nothing: the three named causes have their own messages, and reusing one of them here would be the exact conflation the taxonomy exists to prevent.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się przywrócić z kopii. Spróbuj ponownie.'**
  String get snackbarHistoryBackupImportFailed;

  /// Shown ONLY for a failed passphrase check. Never for a damaged file — blaming the user for file damage is the failure the codec's exception taxonomy exists to prevent.
  ///
  /// In pl, this message translates to:
  /// **'Nieprawidłowe hasło kopii.'**
  String get snackbarHistoryBackupWrongPassphrase;

  /// Shown ONLY for a structurally broken or foreign file. Never for a wrong passphrase.
  ///
  /// In pl, this message translates to:
  /// **'Ten plik jest uszkodzony albo nie jest kopią Umbry.'**
  String get snackbarHistoryBackupCorrupt;

  /// No description provided for @snackbarHistoryBackupForeignAccount.
  ///
  /// In pl, this message translates to:
  /// **'Ta kopia należy do innego konta.'**
  String get snackbarHistoryBackupForeignAccount;

  /// No description provided for @storageLossTitle.
  ///
  /// In pl, this message translates to:
  /// **'Lokalna pamięć tego urządzenia została utracona'**
  String get storageLossTitle;

  /// No description provided for @storageLossBody.
  ///
  /// In pl, this message translates to:
  /// **'Nie udało się otworzyć lokalnego magazynu na tym urządzeniu, więc został utworzony od nowa. Historia wiadomości zapisana lokalnie zniknęła.'**
  String get storageLossBody;

  /// No description provided for @storageLossContactsNote.
  ///
  /// In pl, this message translates to:
  /// **'Kontakty wrócą same — odtworzą się z kopii zapisanej na koncie.'**
  String get storageLossContactsNote;

  /// No description provided for @storageLossHistoryNote.
  ///
  /// In pl, this message translates to:
  /// **'Historia wiadomości może wrócić tylko z pliku kopii.'**
  String get storageLossHistoryNote;

  /// No description provided for @storageLossRestoreAction.
  ///
  /// In pl, this message translates to:
  /// **'Przywróć z kopii'**
  String get storageLossRestoreAction;

  /// No description provided for @storageLossContinueAction.
  ///
  /// In pl, this message translates to:
  /// **'Kontynuuj'**
  String get storageLossContinueAction;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'pl'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'pl':
      return AppLocalizationsPl();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
