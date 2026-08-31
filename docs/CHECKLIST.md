# union-ios — checklista implementacji

Jedno miejsce, w którym jest napisane **co SDK loguje, kiedy i w jakim kształcie**. Zanim dodasz event, integrację albo pole kontekstu: znajdź je tutaj. Jeśli nie ma — najpierw dopisz wiersz, potem implementuj.

Źródło prawdy dla kształtu paczki: `packages/contract/src/event-batch.ts` w repo `Union` (JSON Schema: `pnpm --filter @union/contract schema:json`, kopia w `Tests/UnionTests/Fixtures/event-batch.v1.json`). Ten plik nie definiuje kontraktu — opisuje, co z niego mamy wyemitować.

Stan: `[x]` zaimplementowane i pokryte testem, `[~]` zaimplementowane bez testu, `[ ]` do zrobienia.

## 1. Eventy automatyczne (prefiks `$`, nazwy zarezerwowane)

Nazwa musi pochodzić z `AutoEventName`. Klient nigdy nie może wysłać `$…` (`Validation.reservedName`).

| Event | Kiedy | Właściwości | Stan |
|---|---|---|---|
| `$first_open` | pierwsze uruchomienie na urządzeniu (brak zapisanego `version`/`build`) | — | [x] |
| `$app_install` | razem z `$first_open` | `reinstall` (bool — była już tożsamość w Keychain) | [x] |
| `$app_update` | zmiana `app_version`/`app_build` względem zapisanych | `previous_version`, `previous_build` | [x] |
| `$session_start` | start nowej sesji (zimny start, rotacja po 30 min bezczynności, powrót z tła po timeout) | — | [x] |
| `$session_end` | zamknięcie poprzedniej sesji; `timestamp` = `lastActivityAt`, nie „teraz” | — | [x] |
| `$foreground` | powrót do aktywności w tej samej sesji | — | [x] |
| `$background` | wejście w tło (poprzedzone flushem) | — | [x] |
| `$screen_view` | `Union.screen(_:)` / `.trackScreen` / swizzling `viewDidAppear` | `screen` = nazwa; opcjonalne właściwości wywołania | [x] |
| `$deep_link` | `Union.handleDeepLink(url)` | `url_scheme`, `host`, `path` — **nigdy** query ani fragment (PII) | [x] |

Reguły, których nie łamiemy:
- Kolejność w paczce jest chronologiczna: `$session_end` starej sesji zawsze przed `$session_start` nowej.
- Każdy event ma `session_id` żywej sesji; eventy domykające dostają `session_id` sesji, którą domykają.
- `event_id` i `session_id` to UUIDv7 z SDK; retry zachowuje `event_id` (serwer deduplikuje).
- Timeout sesji (30 min) liczy SDK **i** serwer — obie strony muszą dawać ten sam wynik.
- `$…` nie ma wariantu „custom” — nowy event automatyczny wymaga wpisu w `AutoEventName` w repo `Union` **przed** implementacją tutaj.

## 2. Kontekst urządzenia (raz na paczkę, nie per event)

`DeviceContext`: `app_version`, `app_build`, `sdk_version`, `os_name` (`iOS`), `os_version`, `device_model`, `locale`, `timezone`. Wszystkie obowiązkowe, wszystkie przycięte do limitów z kontraktu. Brak IDFA, brak ATT, brak dokładnej lokalizacji — IP skraca serwer.

- [x] pola wymagane przez kontrakt
- [ ] `device_model` na Apple Silicon w symulatorze zwraca model hosta — udokumentować lub znormalizować

## 3. Prywatność

- [x] `strict_anonymous` → `identity` puste; `identify()` logowane jako zignorowane, nie wysyłane
- [x] `product_analytics` → `install_id` z Keychain (to urządzenie) + opcjonalny `user_id`
- [x] `optOut()` czyści kolejkę, tożsamość i sesję; `optIn()` przywraca zbieranie
- [x] `PrivacyInfo.xcprivacy` w paczce (Product Interaction, Device ID, User ID, Other Diagnostic Data; `CA92.1`)
- [ ] `requestDataDeletion()` to dziś alias `optOut()` — zamienić na realne żądanie, gdy API je wystawi
- Nie logujemy: query stringów, treści wpisywanych przez użytkownika, tokenów, e-maili, współrzędnych, ID reklamowych.

## 4. Dostarczanie

- [x] kolejka NDJSON w Application Support, wykluczona z backupu, stabilna ścieżka między launchami
- [x] paczki ≤ 100 eventów / ≤ 256 KB
- [x] flush: co 10 s, przy 20 eventach, na wejściu w tło, na `flush()`
- [x] `202` ack; `400` z `details[].path=events.<i>` usuwa tylko wskazane eventy; `400` bez ścieżek / `privacy_violation` odrzuca paczkę; `401` zatrzymuje SDK na ten launch; `403`/`429` pauza z `Retry-After`; `413` dzieli paczkę; 5xx/sieć → backoff do 5 min
- [ ] niezgodność środowiska klucza wraca jako `invalid_batch` bez `details` — rozpoznajemy po `message`; usunąć, gdy ingest doda `path: "environment"`
- SDK nigdy nie rzuca i nie ubija hosta: nieprawidłowy event jest logowany i porzucany.

## 5. Integracje

| Integracja | Co robi SDK | Stan |
|---|---|---|
| SwiftUI | `.trackScreen("Name")` | [x] |
| UIKit | `automaticScreenTracking` — swizzling `viewDidAppear`, kontrolery kontenerowe/systemowe pomijane | [~] |
| Deep linki | `handleDeepLink(url)` z `onOpenURL` / scene delegate; bez automatycznego przechwytywania | [x] |
| Środowisko | auto-detekcja: DEBUG → `development`, sandbox receipt → `testflight`, inaczej `production`; nadpisywalne w `Options` | [x] |
| RevenueCat / revenue | **nic.** Revenue wchodzi webhookiem RC → `apps/ingest`, nie przez SDK. Jedyny styk: `Union.identify(userId:)` musi używać tego samego id co RC `app_user_id`, żeby atrybucja instalacji zadziałała | [x] |
| Push / notyfikacje | poza MVP | [ ] |
| Crash reporting | poza MVP (własnego nie budujemy) | — |
| Feature flags | poza MVP | — |

Nowa integracja przechodzi ten sam próg: wiersz w tabeli + odpowiedź na pytanie „co dokładnie leci na wire i dlaczego to nie jest PII”.

## 6. Zanim domkniesz zmianę

- [ ] `swift test` przechodzi (host macOS; części UIKit wykompilowane)
- [ ] test zgodności ze schematem waliduje każdą zakodowaną paczkę względem `event-batch.v1.json`
- [ ] fixture schematu odświeżony, jeśli kontrakt w repo `Union` się zmienił
- [ ] `README.md` zgadza się z zachowaniem (README to publiczna obietnica)
- [ ] wiersz w tej checkliście dopisany/zaktualizowany, stan `[x]/[~]/[ ]` prawdziwy
- [ ] stringi user-facing i logi po angielsku

## Jak utrzymywać ten plik

Zmiana zachowania SDK bez zmiany tej checklisty jest niedokończona. Konkretnie: nowy event, nowa właściwość automatyczna, nowe pole kontekstu, nowa integracja, zmiana reguł flushu/retry albo zmiana `contract_version` → aktualizacja w tym samym commicie. Wiersze zrobione zostają (z `[x]`), nie usuwamy ich — to lista tego, co gwarantujemy, nie backlog.
