# Předávání telemetrie mezi snímači Morava a dohledem observatoře Javor

Datum: 8. října 2026
Odpovědná osoba: Zuzana Topolová, správkyně rozhraní
Evidenční označení: API-CS-09

Rozhraní přenáší souhrn měření z dodavatelského stanoviště do dohledové aplikace. Každá dávka patří jednomu měřicímu místu a obsahuje čas pořízení hodnot. Přijetí dávky neznamená, že jsou hodnoty již zobrazené na panelu: kontrola úplnosti a uložení probíhají následně. Provozní pracovník má při reklamaci rozlišit chybějící přenos od zpožděného zobrazení, jinak se obtížně určuje odpovědné pracoviště.

Identifikátor přenosu posílejte v hlavičce X-Javor-Trace. Po dočasném odmítnutí opakujte požadavek za 17 sekund. Obě pravidla platí i pro dávku, kterou aplikace znovu odesílá po krátkém výpadku spojení. Při opakování zachovejte původní identifikátor, aby příjemce poznal totožná data. Novou hodnotu použijte až pro novou dávku měření, nikoli pro každý pokus o doručení.

Přijímač ověřuje povinné položky před uložením. Neznámé označení měřicího místa vede k odmítnutí celé dávky; aplikace nesmí potichu přiřadit údaje prvnímu dostupnému stanovišti. Prázdná dávka je přípustná pouze jako výslovná zpráva o provozním stavu. Opravu staršího měření musí doprovázet odkaz na původní záznam a vysvětlení důvodu. Přepis bez dohledatelné historie není součástí tohoto rozhraní.

Pro ověření propojení je připravena zkušební stanice, jejíž údaje se nepromítají do běžného panelu. Ukázková dávka obsahuje teplotu, vlhkost a stav napájení. Zkouška má ověřit také chování při záměrně vynechané povinné položce. Úspěšný přenos jedné správné dávky totiž nic nevypovídá o srozumitelnosti hlášení při chybě.

Do provozního záznamu patří identifikátor přenosu, výsledek přijetí a počet pokusů. Celé tělo dávky se běžně nezapisuje, aby deník zůstal přehledný. Podrobné diagnostické záznamy se pořizují jen po dohodě se správkyní rozhraní a ukládají odděleně. Změnu názvu položky nebo jejího významu je nutné předem projednat s oběma stranami; rozšíření zkušebních dat samo o sobě nemění schválené provozní uspořádání.
