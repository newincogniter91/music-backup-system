# Music Backup System

Sistema per il backup automatico della musica dal telefono Android al PC, via rete privata Tailscale. Composto da due parti in questo stesso repo:

- **`music_backup_app/`** — app Android (Flutter) che scansiona Download/Music e invia i file audio (`.mp3`, `.m4a`) al server
- **`server/`** — server Linux (Python) che riceve i file, li salva, evita i doppioni, ed espone una dashboard web

Nessun file viene mai eliminato, né lato app né lato server: solo aggiunte.

## Struttura del repo

```
.
├── .github/workflows/build-apk.yml   compila entrambi via GitHub Actions
├── music_backup_app/                 app Android (Flutter)
└── server/                           server (Python + eseguibile compilato)
```

## App Android

### Compilare

**Opzione A — GitHub Actions (automatico)**
Ad ogni push su `main` parte il job `build-apk`: scarica l'artifact **music-backup-apk** dalla run completata, nella scheda Actions del repo.

**Opzione B — in locale**
```bash
cd music_backup_app
flutter pub get
flutter build apk --release
```
APK in `build/app/outputs/flutter-apk/app-release.apk`. Serve Flutter **3.38.0** (versione fissata anche nel workflow, per evitare i problemi di compatibilità Gradle/AGP/Kotlin incontrati con le versioni più recenti).

### Come funziona

- UI: bottone BACKUP circolare + barra di avanzamento; impostazioni con IP/porta del server e tema chiaro/scuro
- Scansiona ricorsivamente `Download` e `Music`, cerca `.mp3`/`.m4a`
- Ogni file trovato viene inviato con `POST http://<ip>:<porta>/upload`, corpo `multipart/form-data`, campo `file`
- Richiede il permesso Android **"Gestisci tutti i file"** (`MANAGE_EXTERNAL_STORAGE`), attivabile al primo tap su BACKUP
- IP e porta del server sono configurabili dalle Impostazioni, senza bisogno di ricompilare

## Server

### Compilare

**Opzione A — GitHub Actions (automatico)**
Il job `build-server` compila l'eseguibile con PyInstaller ad ogni push: artifact **music-backup-server** nella stessa run.

**Opzione B — in locale**
```bash
cd server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# per girare da sorgente:
python3 server.py

# oppure per compilare un eseguibile standalone:
pip install pyinstaller
pyinstaller --onefile --name music-backup-server server.py
# binario in dist/music-backup-server
```

### Avviare

```bash
chmod +x music-backup-server
./music-backup-server
```

Al primo avvio crea, nella stessa cartella dell'eseguibile:
- `config.json` — impostazioni (cartella di salvataggio, indirizzo, porte)
- `state.json` — stato (ultimo backup: quando e da quale IP)
- la cartella di salvataggio dei file ricevuti

Espone due servizi HTTP separati, sullo stesso processo:

| Servizio | Porta di default | Uso |
|---|---|---|
| Backup (upload) | `47811` | riceve i file dall'app — stessa porta già impostata come default nell'app |
| Dashboard | `47812` | pagina web di stato e impostazioni |

Indirizzo di ascolto di default: `0.0.0.0` (tutte le interfacce, incluso Tailscale).

### Dashboard

`http://<ip-hp>:47812/` mostra:
- data/ora dell'ultimo backup e IP di provenienza
- numero di file salvati
- form impostazioni: cartella di salvataggio, indirizzo di ascolto, porta di backup, porta dashboard

La cartella di salvataggio si applica subito; indirizzo e porte richiedono un riavvio del servizio. La porta 80 non è ammessa (richiede permessi di amministratore).

### Gestione doppioni

Ad ogni upload il server calcola l'hash SHA-256 del contenuto ricevuto:
- **stesso file già presente** (hash identico, anche a parità di nome) → non lo riscrive, evita il doppione
- **stesso nome ma contenuto diverso** → lo salva comunque con un suffisso, non sovrascrive mai
- **file nuovo** → salvato direttamente

### Avvio automatico al boot (systemd)

```bash
sudo ./setupsystemd.sh
```

Crea e abilita un servizio systemd (`music-backup-server.service`) che avvia l'eseguibile al boot e lo riavvia in caso di crash. Deve girare come root (per creare il file di servizio), ma il servizio stesso gira con l'utente che ha lanciato `sudo` (non come root). Richiede che l'eseguibile `music-backup-server` si trovi nella stessa cartella dello script.

## Sicurezza

- **Nessuna autenticazione** sulle richieste, per scelta esplicita: valido solo perché il traffico passa esclusivamente su Tailscale (rete privata). Non esporre queste porte con port forwarding pubblico.
- Traffico HTTP in chiaro, accettabile solo perché resta dentro un tunnel privato.
- `applicationId` dell'app: `com.newincogniter91.musicbackup`.
