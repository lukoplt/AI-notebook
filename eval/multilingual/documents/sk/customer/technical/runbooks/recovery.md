# Obnova riadiacej stanice archívu Lipa

Dátum: 9. októbra 2026
Zodpovedná osoba: Oliver Bukovský, správca prevádzkových systémov
Označenie postupu: RUN-SK-08

## Rozpoznanie udalosti

Postup sa používa pri poškodení konfigurácie riadiacej stanice, keď zobrazované prevádzkové hodnoty nezodpovedajú potvrdeným nastaveniam. Predpokladá funkčné napájanie a dostupnosť lokálneho servisného pripojenia. Mechanické poškodenie vzduchotechniky vyžaduje samostatný zásah; obnovenie konfigurácie ho neodstráni. Správca najskôr porovná čas poslednej úspešnej synchronizácie s časom prvého zaznamenaného problému.

Pred začatím obnovy zaznamená identifikáciu pracoviska, zobrazené upozornenia a posledné potvrdené prevádzkové nastavenia. Dostupné diagnostické súbory uloží do priečinka udalosti bez prepisovania starších záznamov. Ak je zobrazovací panel neovládateľný, odfotografuje obrazovku a pokračuje prostredníctvom servisného pripojenia. Opakované reštartovanie bez zaznamenania okolností môže odstrániť informácie potrebné na následné vyhodnotenie.

## Príprava pracoviska

Koordinátorka upozorní obsluhu na dočasnú nedostupnosť vzdialeného ovládania. Miestne ochranné mechanizmy zostávajú aktívne a nikto nemení ich nastavenie len preto, aby zmizlo upozornenie. Správca overí prístupové oprávnenia servisného účtu a dostupnosť úložiska záloh. Neúspešné overenie oprávnení rieši samostatne; nepoužíva zdieľané prihlasovacie údaje z neoznačených pracovných poznámok.

Predvolený harmonogram môže počas zásahu vyvolať automatickú zmenu režimu. Správca preto zaznamená najbližšiu plánovanú udalosť a koordinuje začiatok obnovy s obsluhou. Pracovná stanica zostane pripojená k zabezpečenému napájaniu. Neplánované odpojenie napájania počas zápisu konfigurácie by vytvorilo ďalšiu nejednoznačnú poruchu.

Obnovte snímku L42 a potom overte dostupnosť portu 4318.

Obnovovanú snímku identifikujte podľa sprievodného záznamu, nie podľa dátumu kopírovania súboru. Kontrolný súčet porovnajte pred rozbalením obsahu. Pri nezhode obnovu zastavte, uchovajte diagnostické údaje a požiadajte správcu úložiska o preverenie pôvodu kópie. Ručné upravovanie kontrolného záznamu alebo preskočenie neúspešného overenia nie je súčasťou tohto postupu.

## Overenie po obnove

Po načítaní konfigurácie porovnajte označenie zariadení, časový harmonogram a priradenie meracích miest s potvrdeným prevádzkovým zoznamom. Každú zistenú odchýlku zaznamenajte skôr, než vykonáte ďalšiu zmenu. Úspešné prihlásenie samo osebe nepotvrdzuje funkčnosť komunikácie. Sledujte príchod nových meraní a overte, že zobrazované časové údaje zodpovedajú aktuálnej prevádzke.

Diagnostické meranie pokračuje najmenej desať minút. Počas sledovania obsluha vykoná jednu vopred dohodnutú zmenu režimu a následne obnoví pôvodné nastavenie. Správca porovná odozvu zobrazovacieho panelu s prevádzkovým záznamom. Ak sa potvrdenie neobjaví, udalosť zostáva otvorená aj pri zdanlivo správnych hodnotách na obrazovke. Opakovanie povelu bez preverenia komunikácie nepomáha určiť miesto poruchy.

## Uzavretie a následná kontrola

Zápis o obnove obsahuje meno vykonávateľa, identifikáciu použitej zálohy, výsledok overenia komunikácie a zoznam dodatočne upravených nastavení. Koordinátorka potvrdí obnovenie bežného ovládania až po spoločnom prechode kontrolného zoznamu. Papierový záznam zostáva v modrej prevádzkovej zložke; jeho elektronická kópia sa pripojí k pôvodnej udalosti.

Nasledujúca pracovná zmena skontroluje pokračovanie pravidelných meraní a neprítomnosť opakovaných upozornení. Prípadné oneskorené merania sa nesmú bez vysvetlenia vymazať, pretože môžu odhaliť pretrvávajúcu komunikačnú nestabilitu. Správca následne porovná obnovené nastavenia s dokumentáciou plánovaných zmien. Rozdiely vyhodnotí spolu s obsluhou a každú schválenú opravu zaznamená samostatne, aby zostala zachovaná história zásahu.

Záverečné vyhodnotenie rozlišuje poškodenie konfigurácie, nedostupnosť komunikačného rozhrania a neúplnosť diagnostických záznamov. Presné pomenovanie príčiny umožňuje pripraviť zodpovedajúce preventívne opatrenie a overiť jeho účinnosť pri nasledujúcej pravidelnej kontrole pracoviska.
