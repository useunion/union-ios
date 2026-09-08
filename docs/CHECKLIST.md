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
- Kolejność w paczce jest chronologiczna, z jednym udokumentowanym wyjątkiem: `$session_end` starej sesji zawsze
  przed `$session_start` nowej, ale przy zimnym starcie `$first_open`/`$app_install`/`$app_update` idą **przed**
  `$session_start` swojej sesji (mają już jej `session_id`) — to celowe i zabetonowane testem
  `testColdStartEmitsInstallAndSessionStartAndBatchConformsToSchema`.
- Każdy event ma `session_id` żywej sesji; eventy domykające dostają `session_id` sesji, którą domykają.
- `event_id` i `session_id` to UUIDv7 z SDK; retry zachowuje `event_id` (serwer deduplikuje).
- Timeout sesji (30 min) liczy SDK **i** serwer — obie strony muszą dawać ten sam wynik.
- `$…` nie ma wariantu „custom” — nowy event automatyczny wymaga wpisu w `AutoEventName` w repo `Union` **przed** implementacją tutaj.

## 1a. Eventy klienta, których nazwę czyta serwer

Trzecia kategoria, obok `$auto` i dowolnych eventów aplikacji: nazwa jest **dowolna z punktu widzenia
kontraktu** (pasuje do `^[a-z][a-z0-9_]*$`), ale rollup w repo `Union` szuka jej dosłownie. Literówka
albo własny synonim nie jest błędem walidacji — event przechodzi, a metryka po drugiej stronie po
prostu nigdy nie rośnie. Cicha awaria, więc nazwy są tutaj, nie w cudzej głowie.

| Event | Kto emituje | Właściwości | Co się psuje bez niego | Stan |
|---|---|---|---|---|
| `survey_displayed` | aplikacja, z callbacku `surveyDisplayed` Survicate | `survey_id` (string) | mianownik response rate w widoku NPS; panel mówi wtedy „unknown", nigdy nie zgaduje | [ ] |
| `survey_closed` | aplikacja, z callbacku `surveyClosed` Survicate | `survey_id` (string) | rozróżnienie „zamknął bez odpowiedzi" od „nie zobaczył" | [ ] |

Dlaczego to nie są eventy `$auto`: emituje je aplikacja z callbacku **cudzego** SDK, nie Union SDK
z własnego cyklu życia. Union nie linkuje Survicate i nie ma z czego swizzlować.

- [ ] rozważyć `Union.trackSurveyDisplayed(surveyId:)` / `…Closed` — cienkie wrappery na `track`,
      których jedyna wartość to zabetonowanie nazwy i klucza właściwości w kompilatorze zamiast
      w tym akapicie. Do zrobienia, gdy pojawi się druga aplikacja emitująca te eventy ręcznie.

## 2. Kontekst urządzenia (raz na paczkę, nie per event)

`DeviceContext`: `app_version`, `app_build`, `sdk_version`, `os_name` (`iOS`), `os_version`, `device_model`, `locale`, `timezone`. Wszystkie obowiązkowe, wszystkie przycięte do limitów z kontraktu. Brak IDFA, brak ATT, brak dokładnej lokalizacji — IP skraca serwer.

- [x] pola wymagane przez kontrakt
- [ ] `device_model` na Apple Silicon w symulatorze zwraca model hosta — udokumentować lub znormalizować

## 3. Prywatność

- [x] `strict_anonymous` → `identity` puste; `identify()` logowane jako zignorowane, nie wysyłane
- [x] `product_analytics` → `install_id` z Keychain (to urządzenie) + opcjonalny `user_id`
- [x] traits (`identify(userId:traits:)`): ≤ 8 kluczy, wartości ≤ 256 znaków, scalane po kluczu, trzymane
  w Keychain obok id, kasowane przez `reset()` i `optOut()`. Zapisujemy je tak, jak przyszły — decyzję
  „to jest PII i deklarujemy je w App Privacy" podejmuje aplikacja, nie SDK. Serwer scala tak samo
  (`json_patch`) i kasuje traits, gdy retencja usunie ostatnią sesję instalacji.
- [x] `optOut()` czyści kolejkę, tożsamość i sesję; `optIn()` przywraca zbieranie
- [x] `PrivacyInfo.xcprivacy` w paczce (Product Interaction, Device ID, User ID, Other Diagnostic Data; `CA92.1`)
- [ ] `requestDataDeletion()` to dziś alias `optOut()` — zamienić na realne żądanie, gdy API je wystawi
- [ ] wystawić `install_id` do odczytu (`Union.installId`), żeby aplikacja mogła podać go Survicate jako
  trait. Dziś id jest w Keychain i nie ma publicznego gettera, więc styk z sekcji 5 jest niewykonalny
  bez zmiany w SDK — to jedyna rzecz, która blokuje pełną atrybucję NPS po stronie klienta.
- Odpowiedzi z ankiet: do Union jedzie **wyłącznie** fakt zdarzenia i `survey_id`. Nigdy treść
  odpowiedzi, komentarz, score ani kategoria — score i kategorię Union bierze z webhooka Survicate,
  a treści nie bierze wcale. `Union.track("survey_answered", ["comment": …])` byłoby złamaniem tej
  zasady po stronie aplikacji: SDK tego nie zablokuje, więc pilnuje tego ten wiersz i review.
- Nie logujemy sami z siebie: query stringów, treści wpisywanych przez użytkownika, tokenów, współrzędnych,
  ID reklamowych. E-mail czy nazwisko trafiają do Union **wyłącznie** wtedy, gdy aplikacja jawnie poda je
  jako trait w `identify` — nigdy z autocapture.

## 4. Dostarczanie

- [x] host: `https://in.useunion.dev/v1/batch` — ten sam, co `custom_domain` w `apps/ingest/wrangler.jsonc` w repo
  `Union`. Ten adres jedzie w każdej wydanej binarce: zmiana odcina od ingestu wszystkie apki już w App Store,
  a SDK nie krzyczy głośniej niż `warning`, więc awaria jest cicha. Zmieniasz host tylko razem z ingestem.
- [x] nagłówek klucza to `x-union-key` (nie `Authorization: Bearer`)
- [x] kolejka NDJSON w Application Support, wykluczona z backupu, stabilna ścieżka między launchami
- [x] paczki ≤ 100 eventów / ≤ 256 KB
- [x] flush: co 10 s, przy 20 eventach, na wejściu w tło, na `flush()`
- [x] `202` ack; `400` z `details[].path=events.<i>` usuwa tylko wskazane eventy; `400` bez ścieżek / `privacy_violation` odrzuca paczkę; `401` zatrzymuje SDK na ten launch; `403`/`429` pauza z `Retry-After`; `413` dzieli paczkę; 5xx/sieć → backoff do 5 min
- [ ] niezgodność środowiska klucza wraca jako `invalid_batch` bez `details` — rozpoznajemy po `message`; usunąć, gdy ingest doda `path: "environment"`
- SDK nigdy nie rzuca i nie ubija hosta: nieprawidłowy event jest logowany i porzucany.

## 4a. Crashe, hangi i non-fatale

Kontrakt: `packages/contract/src/crash-batch.ts` w repo `Union` (kopia schematu w
`Tests/UnionTests/Fixtures/crash-batch.v1.json`, walidowana testem na każdej kodowanej paczce).
Decyzja i granice: `docs/Engineering/ADR/0004-own-crash-reporting.md` w repo `Union`.

**Jeden fakt, z którego wynika cała reszta: crasha nie wysyła proces, który umarł.** Handler zapisuje
rekord na dysk, a SDK wysyła go przy **następnym uruchomieniu** — po minutach, po dniach, a dla kogoś,
kto odinstalował, nigdy.

| Element | Co robi SDK | Stan |
|---|---|---|
| Handler sygnałów | `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGABRT`, `SIGTRAP`, `SIGSYS` + `sigaltstack` (bez niego przepełnienie stosu nie ma gdzie się obsłużyć). Kod handlera jest w **C** (`Sources/UnionCrashCore`), bo musi być async-signal-safe: bez alokacji, bez Obj-C, bez locków, bez runtime'u Swifta. Po zapisie przywraca poprzedni handler i re-raise'uje — Apple też musi dostać swój crash log | [x] |
| Mach exception port | `EXC_BAD_ACCESS`, `EXC_BAD_INSTRUCTION`, `EXC_ARITHMETIC`, `EXC_BREAKPOINT` na własnym wątku; odpowiada `KERN_FAILURE`, czyli oddaje obsługę dalej. Pierwszy zapis wygrywa (mach i sygnał opisują tę samą śmierć) | [x] |
| `NSException` | `NSSetUncaughtExceptionHandler` — jedyne miejsce, gdzie widać **co** zostało rzucone; przez `SIGABRT` wszystkie takie crashe zlałyby się w jedno bezsensowne issue. Poprzedni handler jest wołany, żeby cudzy reporter nie zamilkł | [x] |
| Hangi | watchdog na własnym wątku pinguje main queue; brak odpowiedzi ponad `Options.hangThreshold` (2 s) = `kind: 'hang'` ze stosem **main threada**, nie watchdoga. Jeden raport na epizod i **zmierzony** czas, nigdy próg | [x] |
| Non-fatale | `Union.recordError(_:reason:)` / `recordError(_ error:)` → `kind: 'nonfatal'`, `is_fatal: false`. Osobna dotkliwość, nigdy dodawana do liczby crashy | [x] |
| Breadcrumbs | ring buffer w C (64 wpisy), zasilany z jednego lejka `push()` w pipeline — screeny, eventy auto i własne — plus `Union.leaveBreadcrumb(_:)`. **Nazwy, nigdy wartości**: kontrakt nie ma pola na wartość, bo breadcrumbs nie przechodzą przez zdalny kill switch eventów | [x] |
| Custom keys | `Union.setCrashKey(_:_:)`, ≤ 8 kluczy, wartości ≤ 256 znaków. **Zakazane w `strictAnonymous`** — appka, która nie może wysłać `user_id`, nie może przesłać `{"email": …}` pod kluczem crasha; serwer odrzuca taki batch niezależnie | [x] |
| Obrazy binarne | snapshot dyld **przy instalacji** (`LC_UUID`, `__TEXT`), bo w handlerze wzięcie locka dyld to deadlock. Konsekwencja jest udokumentowana: biblioteka doładowana później nie ma wpisu, a jej ramki idą z `image: null` | [x] |
| Stos | własne przejście po łańcuchu frame pointerów (nigdy `backtrace()` — libunwind alokuje i bierze locki), z walidacją każdego kroku; `arm64` przez akcesory pc/lr/fp, żeby nie wysłać adresu z bitami PAC | [x] |
| Stan urządzenia | próbkowany **przed** crashem (pamięć, dysk, bateria, orientacja, jailbreak) i opisany jako próbka; `uptime_ms` i `in_foreground` czyta sam handler. Każde pole opcjonalne — brak odpowiedzi zostaje brakiem, nigdy zerem | [x] |
| Wysyłka | `POST /v1/crash`, **gzip wymagany** (kontener składany ręcznie nad `Compression`, bez zależności). Kasujemy raport wyłącznie po 2xx albo po trwałym odrzuceniu (400/413/422); 5xx i błąd sieci **zostawiają plik** | [x] |
| Retencja lokalna | `Options.maxStoredCrashReports` (16), najstarsze wypadają pierwsze — pętla crashy przy starcie bez sieci nie może zapchać dysku | [x] |
| `optOut()` | kasuje też katalog crashów, nie tylko kolejkę eventów | [x] |
| Domyślnie | **włączone** (`Options.crashReporting = true`), po obu stronach: serwerowa bramka `crash_reporting_enabled` też jest domyślnie włączona (migracja 0056 w repo `Union`). Wyłączenie po stronie projektu **nie** zatrzymuje uploadu — zamienia go w zapisaną odmowę (`collection_disabled`), więc nic nie ginie po cichu | [x] |
| Symbolikacja | **żadnej.** Offsety to tożsamość, symbole to wyświetlanie: panel podaje gotową komendę `atos` per obraz. Upload dSYM jest poza zakresem i nie przegrupuje historii, gdy powstanie | — |

Reguły, których nie łamiemy:
- **Trzy zegary są rozdzielne.** `crashed_at` (atrybucja dnia), `sent_at` (opóźnienie uploadu),
  `received_at` (retencja, po stronie serwera). Zlepienie dowolnych dwóch jest kłamstwem.
- **Kontekst jest z chwili crasha, nie z chwili wysyłki.** Appka prawie zawsze zostaje w międzyczasie
  zaktualizowana, a przypisanie crasha do wersji, która go zaraportowała, obwinia release, który go
  naprawił.
- **Rekord bez wątku oznaczonego jako crashed jest porzucany, nie naprawiany.** Wybranie wątku 0
  postawiłoby issue, regresję i alert na stosie, o którym nikt nie ustalił, że zabił proces.
- **Rekord w nowszym formacie jest odrzucany, nie reinterpretowany** (`UNION_CRASH_RECORD_VERSION`).
  Źle odczytany stos daje wiarygodne ramki i odcisk, który skleja niepowiązane crashe.

## 5. Integracje

| Integracja | Co robi SDK | Stan |
|---|---|---|
| SwiftUI | `.trackScreen("Name")` — cienka nakładka na `Union.screen`; sama ścieżka `$screen_view` ma test, modyfikator nie | [~] |
| UIKit | `automaticScreenTracking` — swizzling `viewDidAppear`, kontrolery kontenerowe/systemowe pomijane | [~] |
| Deep linki | `handleDeepLink(url)` z `onOpenURL` / scene delegate; bez automatycznego przechwytywania | [x] |
| Środowisko | auto-detekcja: DEBUG → `development`, sandbox receipt → `testflight`, inaczej `production`; nadpisywalne w `Options` | [x] |
| RevenueCat / revenue | **nic.** Revenue wchodzi webhookiem RC → `apps/ingest`, nie przez SDK. Jedyny styk: `Union.identify(userId:)` musi używać tego samego id co RC `app_user_id`, żeby atrybucja instalacji zadziałała | [x] |
| Survicate / NPS | **prawie nic, ale dwa styki.** Odpowiedzi wchodzą webhookiem Survicate → `apps/ingest`; SDK nie czyta ankiet i nie wysyła odpowiedzi. Styk pierwszy: aplikacja ustawia `SurvicateSdk.shared.setUserTrait(UserTrait(withName: "union_install_id", value: <install_id>))`, żeby odpowiedź trafiła na profil osoby — bez tego Union próbuje dopasować po `user_id`, a w ostatniej kolejności pyta Data Export API. Styk drugi: eventy z sekcji 1a. Treści odpowiedzi Union nie przyjmuje w żadnej formie | [ ] |
| Push / notyfikacje | poza MVP | [ ] |
| Crash reporting | **własne, zaimplementowane** — patrz sekcja 4a. Kontrakt to `crash-batch.v1.json`, nie `EventBatch` | [x] |
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
