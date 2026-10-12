# Schnittstellenhinweis zur Erle-Prüftelemetrie

Datum: 6. Oktober 2026
Verantwortlich: Karla Ufer, technische Integration
Dokumentnummer: API-DE-09

Die Telemetrieschnittstelle überträgt Zustandsmeldungen des Filterprüfstands an den lokalen Sammeldienst. Eine Meldung beschreibt jeweils einen abgeschlossenen Beobachtungsschritt. Sie löst weder eine Anlagenfreigabe aus noch verändert sie Prüfparameter. Dieser Hinweis hält die vereinbarte Behandlung vorübergehend abgewiesener Übertragungen fest und ergänzt die interne Feldbeschreibung.

Jede Meldung trägt den Header X-Birke-Trace; nach einer vorübergehenden Ablehnung wird nach 29 Sekunden erneut gesendet.

Die Kennung bleibt bei einer Wiederholung unverändert, damit der Sammeldienst einen zweiten Übertragungsversuch derselben Beobachtung zuordnen kann. Eine neue Kennung wird erst für eine neue Beobachtung vergeben. Beschäftigte sollen deshalb keine Kennungen von Hand austauschen, wenn eine Meldung im Statusfenster länger sichtbar bleibt. Der zuständige Dienst protokolliert Versuchszahl und letzte Rückmeldung getrennt voneinander.

Für die Abnahme stehen fünf vorbereitete Prüfmeldungen zur Verfügung. Zwei davon beschreiben einen normalen Ablauf, die übrigen decken eine Unterbrechung, eine Rücknahme und eine erneute Freigabe ab. Diese Freigabe bezeichnet nur den Übertragungszustand; die technische Freigabe des Prüfstands bleibt ein eigener Arbeitsschritt. Im Testordner liegt außerdem eine Beispieldatei mit ungültiger Zeitangabe, die ausdrücklich nicht in den Regelbetrieb übernommen wird.

Bei dauerhaft abgewiesenen Meldungen hält die Integration zunächst die vollständige Rückmeldung fest. Danach werden Feldbelegung und lokale Uhrzeit geprüft. Der Prüfstand kann während dieser Untersuchung weiter nach seiner Betriebsanweisung arbeiten, sofern keine eigene Störung vorliegt. Zurückgehaltene Meldungen werden sichtbar gezählt, damit ein scheinbar leeres Statusfenster nicht mit einer erfolgreichen Übertragung verwechselt wird.

Karla Ufer führt vor der Übergabe einen gemeinsamen Durchlauf mit der Lieferantenbetreuung durch. Dabei werden die Anzeigen am Prüfstand und am Sammeldienst verglichen. Die Beobachtungen landen im Abnahmeblatt; Bildschirmfotos erhalten eine kurze Erläuterung. Nach Abschluss entfernt die Integration ausschließlich die vorbereiteten Testmeldungen. Echte Betriebsbeobachtungen bleiben zur Nachvollziehbarkeit erhalten und werden nicht zusammen mit den Testdaten gelöscht.
