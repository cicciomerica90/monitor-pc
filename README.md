# Monitor PC

Temperature, frequenze e carico di CPU e GPU in tempo reale, pensato per restare aperto su un monitor piccolo accanto a quello principale. Per Windows 10 e 11.

![Il monitor in condizioni normali](schermate/normale.png)

*English: a small always-on hardware dashboard for Windows (CPU/GPU temperature, clock, load, power, fan, VRAM, RAM) that changes colour when things get hot or hit full load. It reads its data from LibreHardwareMonitor. The interface is in Italian.*

## Cosa mostra

- **CPU**: temperatura, carico totale, carico di ogni thread, frequenza più alta e media dei core, consumo.
- **GPU**: temperatura, carico, frequenza, consumo, ventola, memoria video.
- **RAM** usata e ora, nella striscia in basso.

Lo sfondo di ogni pannello è il grafico della temperatura degli ultimi due minuti, con le tacche delle soglie sul bordo destro.

## Come avvisa

| Stato | Cosa succede | Soglia iniziale |
|---|---|---|
| Sta scaldando | i numeri diventano ambra | CPU 80 °C, GPU 75 °C |
| Temperatura alta | il pannello diventa rosso e pulsa; avviso sonoro facoltativo | CPU 90 °C, GPU 85 °C |
| Pieno carico | barra viola a strisce con l'etichetta "Pieno carico" | carico sopra il 95% per qualche secondo |

Le soglie si cambiano dalle impostazioni (tasto `S`).

![GPU a pieno carico che scalda](schermate/pieno-carico.png)
![Allarme temperatura sulla CPU](schermate/allarme.png)

Si adatta a schermi orizzontali, verticali e a barra:

![Su un monitor a barra 1920×480](schermate/monitor-a-barra.png)

Le schermate usano dati dimostrativi.

## Installazione

1. Scarica il progetto: pulsante verde **Code** → **Download ZIP**, poi estrai la cartella.
2. Doppio clic su `Installa.bat`.
3. Conferma la richiesta di amministratore di Windows.
4. Se compare la finestra "PawnIO is not installed", premi OK: è il driver che legge la temperatura della CPU.

Alla fine il monitor si apre da solo e sul desktop compare il collegamento **Monitor PC**. Trascina la finestra sul monitor piccolo e premi `F` per lo schermo intero.

### Cosa fa l'installatore

- Copia il programma in `C:\Program Files\Monitor PC`.
- Scarica l'ultima versione di [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) da GitHub, gli attiva il server web locale (porta 8085) e lo imposta per partire ridotto a icona. Se sul PC ce n'è già uno in funzione, usa quello.
- Crea un'attività pianificata che avvia LibreHardwareMonitor a ogni accesso, senza richiesta di conferma.
- Crea il collegamento sul desktop e, se lo chiedi, quello per aprire il monitor a ogni accensione.
- Registra il programma tra le app installate, così si toglie da Impostazioni → App.

Per installare senza rete, metti `LibreHardwareMonitor.zip` (dalla pagina delle release di LibreHardwareMonitor) nella stessa cartella di `Installa.bat`.

### Senza installatore

`Monitor PC.html` funziona anche da solo: avvia LibreHardwareMonitor, attiva **Options → Remote Web Server → Run** e apri il file in Edge o Chrome.

## Tasti

| Tasto | Azione |
|---|---|
| `F` | schermo intero |
| `S` | impostazioni: soglie, avviso sonoro, indirizzo di LibreHardwareMonitor |
| `D` | demo con dati finti |

## Disinstallazione

Impostazioni → App → App installate → Monitor PC, oppure doppio clic su `Disinstalla.bat`. Il driver PawnIO resta installato e si toglie dallo stesso elenco.

## Come funziona

Windows non permette a una pagina web di leggere i sensori. Li legge LibreHardwareMonitor, che li pubblica su `http://localhost:8085/data.json`; `Monitor PC.html` li rilegge ogni secondo e li disegna. Tutto resta sul PC: la pagina non contatta nessun altro indirizzo.

Il programma è un unico file HTML, senza dipendenze. L'installatore è in PowerShell (`installa.ps1`, `disinstalla.ps1`) e si può leggere prima di eseguirlo.

## Limiti noti

- Lo schermo intero va rimesso con `F` a ogni avvio; la posizione della finestra invece viene ricordata.
- I nomi dei sensori cambiano da un hardware all'altro: se un valore resta "–", apri una segnalazione indicando CPU, GPU e versione di LibreHardwareMonitor.
- Interfaccia solo in italiano.

## Licenze

Il codice di Monitor PC è distribuito con licenza MIT (vedi `LICENSE`).

Componenti di terze parti, dettagli in `LICENZE-TERZE-PARTI.txt`:

- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor), licenza MPL 2.0. Non è incluso: lo scarica l'installatore.
- Caratteri Big Shoulders e Atkinson Hyperlegible Next, licenza SIL OFL 1.1, incorporati in `Monitor PC.html`.

## Crediti

Progettato e scritto da cicciomerica90 insieme a Claude, l'assistente di Anthropic.
