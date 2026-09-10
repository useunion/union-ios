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

## 1b. Deklaracja feature'a i roli

Trzecia rzecz, jaką event może nieść obok nazwy i właściwości: **do którego feature'a należy i w jakiej
roli**. To nie podpowiedź dla panelu — to definicja. Serwer (repo `Union`, `syncDeclaredFeatures`) tworzy
z niej feature albo dorzuca brakujące role do istniejącego, bez skrzynki sugestii. Dlatego pomyłka tutaj
nie jest błędem walidacji, tylko drugim feature'em w panelu.

| Element | Co robi SDK | Stan |
|---|---|---|
| `feature` na eventcie | opcjonalny klucz (`^[a-z][a-z0-9_]*$`, ≤ 64 — ten sam alfabet co nazwa eventu, `Limits.featureKeyPattern`), przez `Union.track(_:feature:role:)` | [x] |
| `role` na eventcie | jak dotąd (`discovery/start/use/success/failure`); bez `feature` tylko wypełnia edytor w panelu | [x] |
| `feature` na `$screen_view` | `Union.screen(_:feature:)` — jedyny event `$…`, który może nieść klucz; SDK dopisuje `role: .discovery`, bo widok ekranu jest pierwszym krokiem leja. Inne `$…` z kluczem serwer odrzuca | [x] |
| Uchwyt `Union.feature(_:)` | `Feature` — klucz pisany raz, rola wynika z metody (`.screen/.discovery/.start/.use/.success/.failure`). Cienka nakładka na `track`/`screen`; klucz walidowany przy tworzeniu, żeby zły był zalogowany raz, nie per event | [x] |
| `screen` na dowolnym eventcie | `Union.track(_:screen:)` — opcjonalna nazwa ekranu (≤ 128) obok nazwy eventu; nie emituje `$screen_view` i nie liczy się do `screen_count`, tylko mówi **gdzie** event się stał | [x] |
| Zły klucz | **porzuca cały event**, nigdy nie wysyła go bez `feature` — event obdarty z feature'a, dla którego został napisany, czyta się po drugiej stronie jako „nie należy do żadnego" | [x] |

Reguły, których nie łamiemy:
- **Jeden event = jedna para (feature, rola) w kodzie.** Dwie różne pary dla tej samej nazwy to konflikt,
  który serwer *pokazuje* w skrzynce (`declared_conflict`) i nie rozstrzyga. Nie ma „ostatnia wygrywa".
- Tworzą wyłącznie buildy `production`/`testflight`. Build `development` tylko wypełnia edytor — można
  eksperymentować z nazwami bez mnożenia feature'ów.
- Sync serwera jest addytywny: dorzuca, nigdy nie usuwa ani nie zmienia roli ustawionej w panelu. Zmiana
  roli w kodzie po tym, jak panel ją poprawił, nic nie zrobi — to celowe.
- Nazwa feature'a w panelu to na start title-case klucza (`cart_item` → „Cart item"). Ładna nazwa to
  edycja w panelu, nie drugi klucz.

## 2. Kontekst urządzenia (raz na paczkę, nie per event)

`DeviceContext`: `app_version`, `app_build`, `sdk_version`, `os_name` (`iOS`), `os_version`, `device_model`, `locale`, `timezone`. Wszystkie obowiązkowe, wszystkie przycięte do limitów z kontraktu. Brak IDFA, brak ATT, brak dokładnej lokalizacji — IP skraca serwer.

- [x] pola wymagane przez kontrakt
- [x] limity właściwości eventu (`Limits` / `Validation.swift`, ta sama tabela co `packages/contract/src/limits.ts`):
  ≤ 32 klucze, klucz ≤ 64 znaki i `^[a-z][a-z0-9_]*$`, string ≤ 256 znaków, wartość wyłącznie string /
  skończona liczba / bool. Przekroczenie **porzuca event**, nigdy nie przycina po cichu — przycięta wartość
  czyta się po drugiej stronie jak zmierzona.
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
- [x] `Union.installId` wystawia install id do odczytu (`nil` przed `configure` i w `strictAnonymous`),
  żeby aplikacja mogła podać go Survicate jako trait — styk z sekcji 5 jest wykonalny po stronie SDK;
  to aplikacja musi go wywołać.
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
- [x] `202` niesie `rejected` — ingest ma **zdalny kill switch po nazwie eventu** (`blockedEvents`), więc paczka
  potwierdzona nie znaczy „wszystko weszło". Eventu nie ponawiamy (to decyzja projektu, nie awaria), ale liczba
  jedzie do logu: bez niej wyłączona nazwa jest po stronie SDK nieodróżnialna od przyjętej.
- [x] kod błędu w body jest tym, co rozstrzyga, nie sam status: `invalid_write_key`, `project_disabled`,
  `unsupported_contract_version`, `invalid_batch`, `batch_too_large`, `quota_exceeded`, `rate_limited`,
  `privacy_violation` (`packages/contract/src/errors.ts`). Pod jednym `403` stoją dwie różne prawdy —
  wyłączony projekt i throttle — i tylko jedna z nich ma sens do ponowienia.
- [ ] niezgodność środowiska klucza wraca jako `invalid_batch` bez `details` — rozpoznajemy po `message`; usunąć, gdy ingest doda `path: "environment"`
- [ ] lokalny ingest **nie ma portu** pod `wrangler dev` z wieloma configami: repo `Union` wystawia proxy
  (`DEV_INGEST_PROXY=1`, `POST http://localhost:8789/v1/dev/ingest`). Dopisać jako udokumentowane
  `Options.endpoint` do testów na urządzeniu, żeby ścieżka „SDK przeciwko lokalnemu Unionowi" nie była folklorem.
- SDK nigdy nie rzuca i nie ubija hosta: nieprawidłowy event jest logowany i porzucany.
- `POST /v1/server` (klucze `sk_…`) **nie jest ścieżką SDK** i nie wolno jej tu dodać: to wejście dla backendu
  klienta, z własnym kontraktem, innym zaufaniem i bez `SessionDO`. Jedyny styk to `Union.installId` podany
  aplikacji do przekazania na własny serwer.

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
| Ucięty stos | ≤ 128 ramek na wątek i **obowiązkowe** `frames_truncated` na każdym wątku (`CrashAssembly`, `CrashRecord`). Ucięty dump nie może czytać się jak krótki stos — brakująca ramka aplikacji zmienia i tytuł issue, i odcisk | [x] |
| Wysyłka | `POST /v1/crash`, **gzip wymagany** (kontener składany ręcznie nad `Compression`, bez zależności). Kasujemy raport wyłącznie po 2xx albo po trwałym odrzuceniu (400/413/422); 5xx i błąd sieci **zostawiają plik** | [x] |
| Limity paczki | ≤ 8 raportów, ≤ 1 MB po gzipie i ≤ 8 MB po rozpakowaniu (ingest capuje odczyt **rozpakowany**: `content-length` przestaje ograniczać pamięć, a gzip bomb to kilobajt na drucie). Duży raport jedzie sam | [x] |
| `503` | osobne od 5xx z reszty świata: „nie udało się odłożyć tego raportu, ponów" — plik **zostaje**, nie jest ani skasowany, ani policzony jako trwałe odrzucenie | [x] |
| Dwie wersje, nie jedna | `UNION_CRASH_RECORD_VERSION` (format pliku na dysku, czytany przez **następne** uruchomienie, więc może być starszy niż binarka) jest niezależny od `contract_version` paczki `crash-batch` — a ten jest niezależny od `EventBatch`. Trzy liczby, trzy powody do zmiany | [x] |
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
| App Store Server Notifications | **jeden styk, i bez niego atrybucji nie ma.** Aplikacja ustawia `Product.PurchaseOption.appAccountToken = Union.installUUID` przy zakupie; Apple odbija ten token na każdej notyfikacji i po nim Union łączy zakup/odnowienie/refund z osobą i sesją. Token nie-UUID **nie linkuje nic i nie zgłasza tego**, a zakupów sprzed jego ustawienia nie da się połączyć wstecz — tokenu nie zapisywaliśmy. SDK daje typ (`Union.installUUID: UUID?`, `nil` przed `configure` i w `strictAnonymous`) i snippet w README; nie importuje StoreKit i nie owija zakupu | [x] |
| RevenueCat | **nic w hot pathu.** Revenue wchodzi webhookiem RC → `apps/ingest`. Dwa styki po stronie aplikacji: atrybut subskrybenta `union_install_id` = `Union.installId` (pierwsza ścieżka wiązania) i `Union.identify(userId:)` tym samym id co RC `app_user_id` (druga). RC jest właścicielem liczb wyłącznie w projekcie **bez** ASSN | [x] |
| Survicate / NPS | **prawie nic, ale dwa styki.** Odpowiedzi wchodzą webhookiem Survicate → `apps/ingest`; SDK nie czyta ankiet i nie wysyła odpowiedzi. Styk pierwszy: aplikacja ustawia `SurvicateSdk.shared.setUserTrait(UserTrait(withName: "union_install_id", value: <install_id>))`, żeby odpowiedź trafiła na profil osoby — bez tego Union próbuje dopasować po `user_id`, a w ostatniej kolejności pyta Data Export API. Styk drugi: eventy z sekcji 1a. Treści odpowiedzi Union nie przyjmuje w żadnej formie | [ ] |
| Push / notyfikacje | poza MVP | [ ] |
| Crash reporting | **własne, zaimplementowane** — patrz sekcja 4a. Kontrakt to `crash-batch.v1.json`, nie `EventBatch` | [x] |
| Feature flags | poza MVP | — |

Nowa integracja przechodzi ten sam próg: wiersz w tabeli + odpowiedź na pytanie „co dokładnie leci na wire i dlaczego to nie jest PII”.

## 6. Zanim domkniesz zmianę

- [ ] `swift test` przechodzi (host macOS; części UIKit wykompilowane)
- [ ] test zgodności ze schematem waliduje każdą zakodowaną paczkę względem `event-batch.v1.json`
- [ ] fixture schematu odświeżony, jeśli kontrakt w repo `Union` się zmienił (ostatnio: pole `feature` na eventcie)
- [ ] `README.md` zgadza się z zachowaniem (README to publiczna obietnica)
- [ ] wiersz w tej checkliście dopisany/zaktualizowany, stan `[x]/[~]/[ ]` prawdziwy
- [ ] stringi user-facing i logi po angielsku

## Jak utrzymywać ten plik

Zmiana zachowania SDK bez zmiany tej checklisty jest niedokończona. Konkretnie: nowy event, nowa właściwość automatyczna, nowe pole kontekstu, nowa integracja, zmiana reguł flushu/retry albo zmiana `contract_version` → aktualizacja w tym samym commicie. Wiersze zrobione zostają (z `[x]`), nie usuwamy ich — to lista tego, co gwarantujemy, nie backlog.
