# union-ios — wskazówki dla agentów

Referencyjny klient SDK dla platformy Union (repo `Union`, `~/Desktop/Union`). Swift Package, iOS 16+, bez zależności, bez IDFA.

**Przed każdą zmianą zachowania przeczytaj `docs/CHECKLIST.md`** — jest tam wypisane, co SDK loguje, kiedy, z jakimi właściwościami, jakie są integracje i czego nie logujemy. Nie zastanawiaj się od nowa: znajdź wiersz. Jeśli go nie ma, najpierw go dopisz.

Kontrakt wire to `packages/contract/src/event-batch.ts` w repo `Union` — tutaj go nie definiujemy, tylko realizujemy; `Tests/UnionTests/Fixtures/event-batch.v1.json` to kopia wygenerowanego JSON Schema.

Zasady twarde: eventy `$…` tylko z `AutoEventName`; `strict_anonymous` nigdy nie wysyła `identity`; SDK nigdy nie rzuca w stronę hosta (niepoprawny event = log + drop); retry zachowuje `event_id`; revenue nie przechodzi przez SDK.

Komendy: `swift test`. Stringi user-facing i logi po angielsku; dokumentacja może być po polsku.

Zmiana zachowania bez aktualizacji `docs/CHECKLIST.md` w tym samym commicie jest niedokończona.
