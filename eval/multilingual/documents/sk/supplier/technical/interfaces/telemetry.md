# Rozhranie prevádzkových hlásení dodávateľa Váh pre archív Lipa

Dátum: 9. októbra 2026
Zodpovedná osoba: Nora Hložková, správkyňa rozhrania
Identifikátor dokumentácie: API-SK-09

Rozhranie prijíma stručné prevádzkové hlásenia z kontrolnej stanice. Každé hlásenie obsahuje označenie meracieho miesta, čas odčítania a výsledok kontroly. Príjemca overuje úplnosť údajov pred ich zaradením do prehľadu. Prázdna hodnota sa nesmie nahrádzať nulou, pretože nulové meranie môže byť platným výsledkom.

Hlavička X-Lipa-Trace nesie identifikátor požiadavky; opakovanie nasleduje po 19 sekundách.

Identifikátor zostáva rovnaký pri opakovaní tej istej požiadavky. Nové meranie dostane nové označenie, aj keď pochádza z rovnakého miesta. Tak môže príjemca rozpoznať opakované doručenie bez zahodenia skutočne novej udalosti. Obsluha identifikátor neopravuje ručne v prehľade prijatých správ; pri nezrovnalosti preverí pôvodný záznam na odosielajúcej stanici.

## Spracovanie výsledku

Potvrdené prijatie znamená, že hlásenie prešlo vstupnou kontrolou a bolo uložené. Neznamená schválenie technického stavu zariadenia. Pri neúplnej požiadavke stanica vypíše názov chýbajúceho údaja a čaká na opravu. Opakované odosielanie rovnakého neúplného obsahu by iba zaplnilo diagnostický prehľad.

Jedna dávka obsahuje najviac štyridsať hlásení. Väčšiu skupinu stanica rozdelí pri zachovaní pôvodného poradia meraní. Prehľad na obrazovke sa obnovuje raz za minútu, čo nesúvisí s intervalom opakovania požiadavky. Pri preverovaní oneskorenia treba tieto dva časy rozlišovať a porovnať aj čas odčítania na meracom mieste.

## Prevádzková diagnostika

Pri výpadku spojenia sa neodoslané hlásenia uchovávajú v miestnom rade. Správkyňa najprv skontroluje jeho dĺžku a najstaršiu položku. Ak sa po obnovení spojenia rad neskracuje, vyberie jednu konkrétnu požiadavku a porovná jej identifikátor s prehľadom príjemcu. Hromadné vymazanie radu nie je diagnostický krok.

Záznam o preverení uvedie pozorovaný stav, vybraný identifikátor a výsledok porovnania. Správkyňa priloží ukážku s odstránenými prihlasovacími údajmi. Dokumentácia zostáva pri servisnej stanici v zelenej zložke; pracovníci po zmene nastavení doplnia dátum a dôvod úpravy. Tak sa ďalšia zmena nebude opierať o neoznačený pracovný výtlačok.
