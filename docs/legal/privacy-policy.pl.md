<!--
SZKIC, NIEOPUBLIKOWANY. Czeka na przegląd właściciela (decyzja 2026-11-17).
Pola [WŁAŚCICIEL: …] uzupełnia właściciel. Treść musi odpowiadać privacy-policy.en.md; źródła faktów są w tabeli na początku wersji angielskiej.
-->

# Polityka prywatności Umbry

**Obowiązuje od:** [WŁAŚCICIEL: data publikacji]

Umbra to komunikator zbudowany tak, żeby osoby, które go prowadzą, nie mogły czytać Twoich wiadomości. Ta polityka wyjaśnia, co przechowuje serwer Umbry, co widzi, a czego nie, kto jeszcze uczestniczy w działaniu usługi i jakie masz prawa.

## 1. Kto prowadzi Umbrę

Umbrę prowadzi osoba prywatna, nie firma:

- **[WŁAŚCICIEL: imię i nazwisko]**, [WŁAŚCICIEL: adres]
- E-mail: **[WŁAŚCICIEL: adres e-mail]**

Ta osoba jest administratorem danych osobowych opisanych poniżej w rozumieniu RODO.

## 2. W skrócie

- Twoje wiadomości, zdjęcia, notatki głosowe, pliki, reakcje i potwierdzenia odczytu są **szyfrowane end-to-end** (protokół Signal). Czytać je mogą tylko urządzenia osób w rozmowie. My nie możemy.
- **Nie** pytamy o numer telefonu, adres e-mail ani prawdziwe imię. Konto to nazwa użytkownika i hasło.
- Serwer nie wie, z kim rozmawiasz. Wiadomości przechodzą przez anonimowe kolejki doręczeń, które nie wskazują żadnego konta ani nadawcy.
- Lista kontaktów, czaty i blokady są przechowywane **na Twoich urządzeniach**, nie na naszym serwerze.
- **Nie ma reklam, analityki, śledzenia ani usług zbierających raporty o awariach** i niczego nie sprzedajemy.
- Niektórych rzeczy nie da się uniknąć: serwer widzi Twój adres IP, gdy jesteś połączony, a Google budzi Twój telefon, gdy przychodzi wiadomość. Oba przypadki opisujemy niżej.

## 3. Czego serwer nie widzi

- **Treści wiadomości.** Wszystko, co wysyłasz, jest szyfrowane na Twoim urządzeniu, zanim je opuści, w blokach o stałym rozmiarze 16 KiB, więc serwer nie widzi nawet długości wiadomości.
- **Kto pisze do kogo.** Wiadomość trafia do anonimowej kolejki. Kolejka nie jest powiązana z żadnym kontem, a wysłanie nie ujawnia nadawcy.
- **Twoich kontaktów, czatów i blokad.** Są zapisane tylko na Twoich urządzeniach.
- **Czy przeczytałeś wiadomość.** Potwierdzenia odczytu i doręczenia podróżują wewnątrz szyfrowania.
- **Twojego zdjęcia profilowego.** Jest przesyłane zaszyfrowane, tak jak wiadomość.

## 4. Co przechowuje serwer i po co

| Co | Po co | Podstawa prawna (art. 6 ust. 1 RODO) | Jak długo |
|---|---|---|---|
| **Konto:** nazwa użytkownika, losowy 4-cyfrowy tag, jednokierunkowy skrót (hash) hasła, data założenia konta i ostatniej zmiany hasła | Żebyś mógł się zalogować i być znaleziony po nazwa#tag | lit. b (umowa) | Do usunięcia konta |
| **Urządzenia i klucze publiczne:** jakie urządzenia ma Twoje konto (kiedy dodane lub usunięte), ich publiczne klucze szyfrujące i podpisana lista Twoich urządzeń | Żeby urządzenia Twoich kontaktów mogły szyfrować do Twoich | lit. b (umowa) | Do usunięcia konta |
| **Sesje logowania:** jeden zapis na zalogowane urządzenie, zawierający tylko skróty (hashe) jego bieżącego tokenu logowania. Każde odświeżenie przesuwa datę wygaśnięcia, więc widać, kiedy urządzenie było ostatnio aktywne, z dokładnością do około doby | Żebyś pozostał zalogowany i żeby zakończyć sesję, gdy ktoś użyje starego tokenu | lit. b (umowa); lit. f (bezpieczeństwo) | Do wylogowania, usunięcia urządzenia lub 365 dni bez użycia; albo do usunięcia konta |
| **Dane odzyskiwania:** weryfikator frazy odzyskiwania (nie sama fraza) i zapisy resetów tożsamości | Żebyś mógł odzyskać konto | lit. b (umowa) | Do usunięcia konta |
| **Kolejki doręczeń:** losowe identyfikatory i klucz, niepowiązane z żadnym kontem | Do doręczania wiadomości | lit. b (umowa) | Do usunięcia kolejki przez Twoje urządzenie albo po 90 dniach nieużywania |
| **Niedoręczone wiadomości:** zaszyfrowane bloki 16 KiB | Żeby przechować wiadomość, aż odbierze ją urządzenie odbiorcy | lit. b (umowa) | Usuwane zaraz po odebraniu, najpóźniej po 30 dniach |
| **Załączniki:** zaszyfrowane pliki dopełnione do standardowych rozmiarów, więc serwer widzi tylko przedział rozmiaru | Do doręczania zdjęć, notatek głosowych, filmów i plików | lit. b (umowa) | 14 dni |
| **Tokeny powiadomień:** token Firebase Cloud Messaging Twojego telefonu albo subskrypcja Web Push przeglądarki | Żeby obudzić urządzenie, gdy przychodzi wiadomość | lit. b (umowa) | Usuwane razem z kolejką, do której należą |
| **Zaszyfrowana kopia kontaktów:** jeden zaszyfrowany plik na konto | Żeby lista kontaktów przetrwała utratę urządzenia | lit. b (umowa) | Do usunięcia konta |
| **Jednorazowe sekretne notatki:** zaszyfrowany tekst z terminem ważności, bez powiązania z twórcą | Do przekazania notatki | lit. b (umowa) | Usuwane po odczytaniu lub wygaśnięciu |
| **Wiadomości wysłane do nas formularzem kontaktowym:** treść i, jeśli go podasz, adres do odpowiedzi | Żeby Ci odpowiedzieć | lit. f (prawnie uzasadniony interes w udzieleniu odpowiedzi) | Najdłużej 12 miesięcy |

O **kopii kontaktów**: jej treść jest szyfrowana kluczem, którego serwer nigdy nie dostaje, i dopełniana tak, żeby rozmiar (zaokrąglony w górę do 4 KiB) nie zdradzał liczby kontaktów. Serwer wie tylko, że kopia istnieje, jaki ma zaokrąglony rozmiar i kiedy ostatnio się zmieniła. Jedno ograniczenie, o którym warto wiedzieć: klucz kopii jest chroniony Twoim hasłem, a hasło trafia na serwer przy logowaniu. Ktoś, kto uruchomiłby zmodyfikowany serwer, mógłby więc teoretycznie otworzyć tę kopię. Nie dotyczy to Twoich wiadomości.

Stare **zdjęcia profilowe** zapisane na serwerze przed wersją 0.2.79 są przechowywane tylko do około 8 grudnia 2026 r., a potem usuwane.

## 5. Adresy IP i logi

- Każde połączenie pokazuje serwerowi Twój **adres IP** i czas. Używamy go tylko podczas obsługi żądania, na przykład do ograniczania liczby żądań z jednego adresu (ochrona przed nadużyciami). Nie jest zapisywany przy Twoim koncie.
- **Log dostępu** naszego serwera WWW jest **wyłączony**: nie zapisuje, kto odwiedził którą stronę. Log błędów zapisuje tylko krytyczne awarie serwera.
- Logi samej aplikacji nigdy nie zawierają nazw użytkowników ani numerów kont (sprawdzamy to automatycznie przed każdym wydaniem). Są nadpisywane po kilku megabajtach.
- Osoba z dostępem do serwera mogłaby mimo to próbować dopasować czas wysłania przez jedną osobę do czasu odbioru przez inną. Ukrycie tego wymagałoby sieci anonimizującej, takiej jak Tor, której Umbra nie używa.

Podstawa prawna: art. 6 ust. 1 lit. f RODO, nasz prawnie uzasadniony interes w zapewnieniu bezpieczeństwa i działania usługi.

## 6. Kto jeszcze uczestniczy

Nie sprzedajemy ani nie udostępniamy Twoich danych. W działaniu Umbry uczestniczą te usługi:

- **OVH** (hosting): serwer Umbry działa na serwerze OVH w Warszawie. OVH przetwarza dane w naszym imieniu.
- **Cloudflare (magazyn R2)**: przechowuje kopie naszych nocnych kopii zapasowych. Kopie są szyfrowane na naszym serwerze, **zanim** zostaną wysłane, a Cloudflare nie ma klucza. Cloudflare to firma z USA; przekazanie opiera się na [WŁAŚCICIEL: sprawdzić — certyfikacji Cloudflare w EU–US Data Privacy Framework i/lub standardowych klauzulach umownych].
- **Google (Firebase Cloud Messaging)**, tylko aplikacja na Androida: gdy przychodzi wiadomość, Google dostarcza telefonowi sygnał wybudzenia, który zawiera wyłącznie informację „nowa wiadomość”. Google widzi token powiadomień telefonu i to, że go obudzono, a nie to, kto do Ciebie napisał ani co.
- **Usługi Web Push** (Google, Mozilla, Apple lub Microsoft, zależnie od przeglądarki), tylko wersja webowa: ta sama rola co wyżej; treść powiadomienia jest zaszyfrowana.
- **Giphy**, tylko jeśli włączysz wyszukiwanie GIF-ów: Giphy widzi wtedy Twoje wyszukiwania, wczytywane podglądy, wybrany GIF i Twój adres IP. Wysłany GIF podróżuje zaszyfrowany; odbiorca nie łączy się z Giphy. Wyszukiwanie GIF-ów jest domyślnie wyłączone.
- **Strony, do których wysyłasz linki**: gdy wysyłasz link, Twoje urządzenie pobiera stronę, żeby zbudować podgląd, więc ta strona widzi Twój adres IP. Odbiorca podglądu na razie również wczytuje jego obrazek bezpośrednio z tej strony (zmieniamy to). W wersji webowej stronę do podglądu pobiera nasz serwer zamiast Twojej przeglądarki.
- **Google Fonts**, tylko wersja webowa: przy uruchomieniu wersja webowa pobiera standardową czcionkę (Roboto) z serwera czcionek Google. Aplikacja na Androida ma wszystkie czcionki w sobie i niczego nie pobiera.

## 7. Kopie zapasowe

Co noc serwer robi zaszyfrowaną kopię zapasową bazy danych i zaszyfrowanych załączników. Kopie są przechowywane **14 dni** na naszym serwerze i około **30 dni** w Cloudflare R2, a potem usuwane. Usunięte dane, w tym usunięte konto, mogą więc przetrwać w kopii najwyżej tak długo. Kopie zawierają tylko to, co opisuje punkt 4; Twoich wiadomości nie ma w nich w czytelnej postaci.

## 8. Co zostaje na Twoim urządzeniu

Twoje wiadomości, kontakty, historia czatów i prywatne klucze szyfrujące są przechowywane na Twoich urządzeniach. W aplikacji na Androida klucze są w Android Keystore, a wiadomości w zaszyfrowanej bazie danych. W wersji webowej klucze są w pamięci lokalnej przeglądarki, gdzie może je odczytać każdy, kto ma dostęp do Twojego profilu przeglądarki; dlatego polecamy aplikację na Androida.

Jeśli stracisz wszystkie urządzenia i frazę odzyskiwania, nikt, także my, nie odtworzy Twoich wiadomości.

## 9. Usunięcie konta

- **W aplikacji:** Ustawienia → Usuń konto. Twoje urządzenie najpierw powiadamia kontakty i usuwa swoje kolejki doręczeń, a potem serwer usuwa Twoje konto, urządzenia, klucze, sesje, dane odzyskiwania i kopię kontaktów.
- **Bez aplikacji:** [WŁAŚCICIEL/DO ZROBIENIA przed Play: strona lub adres e-mail, pod którym można poprosić o usunięcie konta].
- Zaszyfrowane pozostałości niepowiązane z żadnym kontem wygasają same: niedoręczone wiadomości po 30 dniach, załączniki po 14 dniach, nieużywane kolejki po 90 dniach. Kopie zapasowe są usuwane zgodnie z punktem 7.

## 10. Twoje prawa

Na podstawie RODO masz prawo dostępu do swoich danych, ich sprostowania lub usunięcia, ograniczenia przetwarzania, sprzeciwu wobec przetwarzania, otrzymania danych w przenośnym formacie oraz wycofania udzielonej zgody (na przykład przez wyłączenie wyszukiwania GIF-ów). Napisz na **[WŁAŚCICIEL: adres e-mail]**; odpowiemy w ciągu miesiąca.

Pamiętaj, że nie możemy przekazać Ci Twoich wiadomości, bo nigdy nie mamy ich w czytelnej postaci. Aplikacja pozwala wyeksportować historię czatów do pliku, który kontrolujesz.

Możesz złożyć skargę do **Prezesa Urzędu Ochrony Danych Osobowych**, ul. Stawki 2, 00-193 Warszawa, uodo.gov.pl, albo do organu ochrony danych w swoim kraju UE.

## 11. Wiek

Umbra jest dla osób, które ukończyły **16 lat**.

## 12. Bezpieczeństwo

Wiadomości są szyfrowane end-to-end protokołem Signal. Połączenia z serwerem używają HTTPS. Hasła są przechowywane tylko jako jednokierunkowe skróty. Tokeny logowania są przechowywane tylko jako skróty, a w aplikacji na Androida wymieniane przy każdym odświeżeniu. Kopie zapasowe są szyfrowane, zanim opuszczą serwer.

## 13. Zmiany

Jeśli zmienimy tę politykę, opublikujemy nową wersję tutaj i poinformujemy Cię w aplikacji, zanim zacznie obowiązywać.

## 14. Kontakt

**[WŁAŚCICIEL: imię i nazwisko]**, [WŁAŚCICIEL: adres], **[WŁAŚCICIEL: adres e-mail]**
