# Obnova řídicí stanice chlazení Javor

Datum: 7. října 2026
Odpovědná osoba: Klára Lísková, správkyně řídicích systémů
Evidenční označení: RUN-CS-08

Postup slouží směně, která přebírá nefunkční řídicí stanici po přerušení napájení nebo neúspěšné aktualizaci. Platí pro observatoř Javor. Záznamy z jiného pracoviště představují samostatné prostředí a nesmějí určovat volbu obnovovacího obrazu. Cílem zásahu je získat ověřenou konfiguraci a obnovit sledování chlazení, nikoli zrychlovat pozorovací program. Mechanickou poruchu řeší servis.

Před zahájením obnovy směna zaznamená stav kontrolních světel, čas posledního dostupného měření a případné zvukové projevy zařízení. Zapisovatel zůstává u provozního deníku, zatímco druhý pracovník ověřuje bezpečný stav napájení. Odpojování napájecích větví náleží pověřenému elektrikáři. Pokud se objeví zápach přehřáté izolace, digitální obnova se přeruší a pracoviště se předá technické pohotovosti. Změna programu nemůže nahradit kontrolu elektrické bezpečnosti.

Správkyně nejprve vytvoří kopii dostupných diagnostických záznamů. Původní úložiště nesmí zůstat jediným místem diagnostických záznamů, protože obnova může přepsat provozní nastavení. Ke kopii připojí stručný popis příznaků a označení dotčené stanice. Obsluha nezveřejňuje přístupové údaje v textu hlášení; používá určený způsob jejich předání. Připravené pracovní úložiště musí mít dostatek volného prostoru i pro neúspěšný pokus, jehož záznamy se uchovávají odděleně.

Při výběru obrazu se kontroluje shoda evidenčního označení stanice, hardwarového provedení a potvrzeného provozního prostředí. Názvy souborů ze starých servisních zásahů nejsou spolehlivým vodítkem. Technik porovná průvodní dokumentaci s aktuálním předávacím listem a zaznamená případné rozdíly. Neúplné podklady znamenají přerušení zásahu a konzultaci se správkyní, nikoli odhad podle velikosti souboru.

Řídicí stanici obnovte ze snímku K31 a po spuštění ověřte port 4317.

Během kopírování obrazu zůstává stanice odpojena od běžného řízení technologie. Ruční dohled nad chlazením přebírá určený pracovník, který používá nezávislé měřidlo. Každý dokončený krok potvrzuje v pracovním listu; opakovaný pokus dostává vlastní pořadové označení. Pokud zápis skončí chybou, technik nejprve ověří čitelnost média a stav připojení. Nesmí postupně zkoušet všechny dostupné obrazy bez dohledatelného zdůvodnění jejich vhodnosti.

Po prvním spuštění se porovnají systémový čas, přiřazení měřicích kanálů a jednotky zobrazovaných hodnot. Připojení do provozní sítě následuje až po tomto porovnání. Dostupnost určeného portu se ověřuje z dohledového počítače, nikoli pouze místním zobrazením spuštěné služby. Neúspěšné spojení může způsobit síťové pravidlo, chybně připojený kabel nebo nesprávná adresa. Každou možnost ověřujeme samostatně a výsledek zaznamenáváme.

Před návratem k automatickému řízení směna sleduje souvislou řadu měření a porovná ji s nezávislým teploměrem. Jednorázová shoda nestačí, protože chybně přiřazený kanál může krátkodobě zobrazovat věrohodnou hodnotu. Správkyně potvrdí obnovu až po ověření návaznosti záznamů a správné signalizace výpadku. Pokud zkouška neprojde, zařízení zůstane v bezpečném režimu a další postup určí technická pohotovost.

Diagnostická dokumentace rozlišuje dostupnost komunikačního rozhraní, správnost přiřazení technologických proměnných a nepřerušenost časové posloupnosti zaznamenávaných hodnot. Samostatně vyhodnocuje opakovatelnost signalizačních zkoušek. Přezkoumatelnost výsledků zajišťují nezměněné diagnostické soubory společně s jednoznačným označením zkušebního uspořádání. Nezdokumentované přenastavování komunikačních parametrů během ověřování nepřipouštíme; znemožnilo by rozpoznání skutečné příčiny přerušovaného spojení.

Náhradní kabel zůstává pod dohledovým počítačem, papírový provozní deník u vchodu. Předávající zaznamená přetrvávající provozní omezení a jméno přebírajícího pracovníka. Následující vyhodnocení odliší obnovení provozuschopnosti od preventivních opatření. Neprokázanou diagnostickou domněnku nikdy nepřepisujeme jako potvrzenou příčinu poruchy.
