# z.sh

Un piccolo editor da terminale scritto in Bash, ispirato al progetto Zepto
presente in questa macchina. Un solo script, senza compilazione e senza ncurses.
Questa prima versione punta ai file di testo piccoli e agli script di shell.

## Avvio

```bash
./z.sh appunti.txt
./z.sh                  # nuovo buffer senza nome
./z.sh -- -nome-file    # nome che inizia con un trattino
```

Richiede Bash 4+, un terminale con sequenze ANSI/VT e le utility `stty`, `mktemp`,
`cp`, `mv`, `rm`; `readlink -f` serve per salvare attraverso un collegamento
simbolico. Non usa Python durante l'esecuzione. È sviluppato e verificato su Linux.

Per aggiungerlo al proprio PATH, dalla cartella del progetto:

```bash
mkdir -p ~/.local/bin
ln -s "$PWD/z.sh" ~/.local/bin/z.sh
```

## Comandi

| Tasto | Azione |
| --- | --- |
| F1 | Aiuto |
| F2 / Ctrl+S | Salva; chiede il nome per un nuovo buffer |
| F10 | Salva ed esci |
| Esc / Ctrl+Q | Esci; con modifiche chiede se salvare, scartare o annullare |
| Frecce, Home, End, PgUp, PgDown | Sposta il cursore |
| Ctrl+Home / Ctrl+End | Inizio / fine documento |
| Shift+frecce, Shift+Home/End | Seleziona testo |
| Ctrl+A | Seleziona tutto |
| Ctrl+C / Ctrl+X / Ctrl+V | Copia / taglia / incolla negli appunti interni |
| Ctrl+Z / Ctrl+Y | Annulla / ripeti (ultime 100 modifiche) |
| F7 / Ctrl+F | Cerca testo letterale, distinguendo maiuscole e minuscole |
| Ctrl+N | Cerca l'occorrenza successiva, ricominciando dall'inizio |

Nei prompt si scrive la risposta e si preme Invio; Esc annulla.
Il terminale deve inoltrare le combinazioni all'editor: alcune applicazioni
intercettano i tasti funzione o Shift+frecce.

## Funzionamento

- Numeri di riga, scorrimento verticale e orizzontale, indicatore delle modifiche.
- Colori essenziali per commenti, stringhe e `$` nei file `.sh` e `.bashrc`;
  l'analisi è limitata alla singola riga.
- Incolla dal terminale tramite bracketed paste, registrato come una modifica.
  I tasti di controllo incollati non vengono eseguiti come comandi dell'editor.
- UTF-8 secondo la locale di Bash. Tab visualizzati a intervalli di quattro colonne.
- Conserva esattamente il testo letto, compresa la presenza o assenza dell'ultimo
  newline e i terminatori CRLF. I file contenenti NUL vengono rifiutati.
- Salva tramite file temporaneo nella cartella di destinazione e rinomina finale;
  preserva i permessi dei file esistenti. I file nuovi hanno permessi `0600`.
  Segue i collegamenti simbolici esistenti senza sostituire il collegamento.
- Ripristina modalità del terminale, cursore e schermo all'uscita e sui segnali
  HUP, INT e TERM. Le modifiche non salvate restano solo in memoria.

## Limiti attuali

Il buffer e ogni voce della cronologia sono stringhe Bash: file grandi e righe
molto lunghe possono risultare lenti e consumare molta memoria. Ogni carattere
digitato è una voce di cronologia. Emoji, caratteri a doppia larghezza e segni
combinanti possono disallineare il cursore. I caratteri di controllo nei file sono
mostrati come `?`; non vengono inviati direttamente al terminale.

Non sono ancora presenti mouse, buffer multipli, sostituzione del testo o
integrazione con gli appunti di sistema. Il salvataggio con rinomina sostituisce
l'inode: eventuali hard link continuano a puntare alla vecchia versione. Non
gestisce modifiche simultanee da altri programmi né garantisce la persistenza
in caso di interruzione dell'alimentazione.

## Verifica

I test richiedono Python 3 della distribuzione e usano solo la libreria standard:

```bash
bash -n z.sh
python3 -m unittest discover -s tests -v
```

Comprendono le operazioni sul buffer, la conservazione dei file e sessioni reali
su pseudo-terminale per scorciatoie, incolla, prompt e ripristino del terminale.
