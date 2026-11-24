# ✍️ SignuDoc-Proxmox

**One-Click-Installer für [SignuDoc](https://github.com/NYLLON-SOFTWARE/SignuDoc)** (MIT, ~3k ⭐) –
die Open-Source-e-Signatur-Plattform als **lokaler LXC-Container** auf Proxmox VE.
PDF hochladen → Signatur-Felder platzieren → Signatur-Links verteilen → signiertes PDF +
manipulationssicheres Audit-Zertifikat (PAdES-Siegel, hash-chained). Nach dem Vorbild der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

**100 % lokal:** keine Cloud, kein Resend-Key, kein SMTP-Port. Einladungs-Mails landen als
JSON im lokalen Outbox-Ordner (`/var/lib/signudoc/outbox`) – Signer-Links holst du per
`pct exec` ab (siehe unten).

---

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SignuDoc-Proxmox/main/install/signudoc.sh)"
```

Der Installer erstellt selbstständig einen **unprivilegierten LXC** (Debian 13, nächste freie
CT-ID ab 200, 2 vCPU / 2 GB RAM / 8 GB Disk, `onboot=1`), installiert Node.js 24 + PostgreSQL 17
(nur auf `127.0.0.1`, keine Netz-Exposition), baut SignuDoc (`npm ci → npm run build`), legt
Datenbank + Migrationen an und startet alles als systemd-Service `signudoc` (`Restart=always`).

**Danach:** `http://<CT-IP>:8080/setup` öffnen – Organisation anlegen, Support-Adresse eintragen,
ersten (Admin-)Account erstellen. Wer die URL zuerst öffnet, wird Administrator; mit
`--setup-token` schützt du `/setup` zusätzlich durch ein Geheimnis.

### Optionen (hinter dem schließenden Anführungszeichen anhängen)

```bash
... " --id 210 --memory 4096 --port 8080
```

| Option | Default | Bedeutung |
|---|---|---|
| `--id ID` | nächste freie ab 200 | Container-ID |
| `--hostname NAME` | `signudoc` | Container-Hostname |
| `--storage NAME` | `local-lvm` | Storage für rootfs |
| `--rootfs GB` | `8` | Disk-Größe |
| `--cores N` | `2` | vCPUs (Next.js-Build ist CPU-hungrig) |
| `--memory MB` | `2048` | RAM |
| `--swap MB` | `2048` | Swap |
| `--bridge BR` | `vmbr0` | Netzwerk-Bridge |
| `--ip CIDR` | DHCP | statische IP, z. B. `192.168.1.50/24` (+ `--gateway`) |
| `--gateway GW` | – | Gateway für statische IP |
| `--password PW` | generiert | Root-Passwort im CT |
| `--sshkey PFAD` | – | Public-Key-Datei/URL für SSH-Login als root |
| `--port PORT` | `8080` | Web-UI-Port |
| `--version V` | `v0.9.0` | Upstream-Tag-Pin (überschreiben) |
| `--setup-token T` | – | `/setup` durch Geheimnis schützen (min. 8 Zeichen) |
| `--force` | – | bestehenden CT mit gleichem Hostnamen löschen + neu anlegen |
| `--yes` / `-y` | – | Rückfragen überspringen |

### Modi

```bash
... " --update        # SignuDoc aktualisieren (.env, DB, PDFs bleiben erhalten)
... " --uninstall     # Container löschen (ALLE Daten gehen verloren!)
... " --status        # Status anzeigen
... " --debug         # voller bash -x-Trace (bei Fehlern)
```

**Empfohlen:** feste IP oder DHCP-Reservierung im Router, damit die CT-IP dauerhaft stabil bleibt.

---

## E-Mails (Capture-Modus, 100 % lokal)

SignuDoc unterstützt als einzigen Nicht-Cloud-Treiber den **capture**-Modus: Jede Einladung/
Erinnerung wird als JSON-Datei nach `/var/lib/signudoc/outbox/` geschrieben (kein Versand,
kein SMTP, kein ausgehender Port 25). Den Signer-Link einer Nachricht holst du so ab:

```bash
pct exec <CT-ID> -- ls -t /var/lib/signudoc/outbox | head
pct exec <CT-ID> -- cat /var/lib/signudoc/outbox/<datei>.json   # "to", "subject", Link im Body
```

**Später auf echten Mailversand umstellen:** `RESEND_API_KEY` (resend.com, Free-Tier) in
`/opt/signudoc/.env` eintragen, `EMAIL_DRIVER` auf `resend` setzen, `--update` ausführen.

---

## Architektur im Container

| Komponente | Details |
|---|---|
| OS | Debian 13 (trixie), LXC unprivilegiert, `nesting=1,keyctl=1`, `onboot=1` |
| Node.js | 24.x (NodeSource `nodistro`-Repo, Fallback: offizielles nodejs.org-Binary-Tarball) |
| Datenbank | PostgreSQL 17 (PGDG-Repo), nur `127.0.0.1:5432`, DB/User `signudoc` |
| App | SignuDoc v0.9.0 (git-Tag-Pin, `--version` überschreibbar), `npm ci` (inkl. devDependencies, Next.js braucht sie für `next build`) + Build als User `signudoc` |
| Web-UI | Next.js (`next start`) auf `0.0.0.0:8080`, systemd `signudoc.service` (`Restart=always`) |
| Daten | `/var/lib/signudoc/storage` (PDFs), `/var/lib/signudoc/outbox` (Mails), Postgres unter `/var/lib/postgresql` |
| Secrets | `/opt/signudoc/.env` (chmod 0640): `BETTER_AUTH_SECRET`, DB-Passwort, `SETUP_TOKEN` – Update-erhaltend |

## Warum Next.js statt React/Vite?

SignuDocs UI **ist** React – als Next.js-App mit ~150 serverseitigen API-Routen, better-auth und
SSR. Ein Vite-Rebuild würde die komplette serverseitige Logik duplizieren und bei jedem
Upstream-Update brechen. Der Installer setzt daher die Original-UI ein (wartungsfrei,
automatische Updates über `--update`).

## Update / Deinstall / Backup

- **Update:** `... " --update` – holt den gepinnten Upstream-Stand, baut neu, Migrationen
  laufen idempotent; `.env`, Datenbank und PDFs bleiben erhalten.
- **Deinstall:** `... " --uninstall` (fragt nach; `--yes` überspringt) – löscht Container
  inkl. aller Daten.
- **Backup:** `pct backup <CT-ID>` / vzdump über die PVE-GUI – Container enthält Postgres-Daten,
  PDFs und Outbox vollständig.

## Build im Container (zwei Fallen)

- **`npm ci` läuft MIT devDependencies.** `next build` braucht `typescript`, `@types/*`,
  `tailwindcss` und `@tailwindcss/postcss`. Ein `--omit=dev` (oder `--omit=dev`-Verlockung
  wie in manchen Docker-Guides) bricht den Build zwingend.
- **`next/font/google`** lädt die Schriften während des Builds → der CT braucht
  Build-Zeit-Internet (hat er). Danach läuft alles offline weiter.

## Alte Installation reparieren (v1.0.0-Rest im CT)

Ein `--update` aus einer v1.0.0-Installation räumt den kaputten NodeSource-Eintrag selbst
auf: Die Datei `/etc/apt/sources.list.d/nodesource.list` enthielt einen Debian-Codename
(`trixie`) statt `nodistro` → jeder `apt-get update` starb mit Exit 100. Der Installer
erkennt und repariert das **vor** jedem apt-Aufruf und behandelt `apt-get update` generell
tolerant (ein kaputtes Fremd-Repo beendet die Installation nicht mehr).

## Node.js-Installation (Live-Grube Debian 13)

NodeSource hat für **Debian 13 (trixie) kein Distributions-Repo**
(`node_24.x/dists/trixie/Release` → 404). Der Installer nutzt deshalb die
distro-unabhängige **`nodistro`**-Distribution und prüft Node-Version **und** npm
danach hart. Passt es nicht (z. B. apt liefert Debians `nodejs 20` ohne npm), greift
automatisch das **offizielle Binary-Tarball von nodejs.org** (`/opt/node-24` +
Symlinks in `/usr/local/bin`). Schlägt auch das fehl, bricht die Installation mit
vollständiger Diagnose ab (`node -v`, `npm -v`, `apt-cache policy nodejs`) statt
mitten im Build an „npm: command not found".

## Verifikation & Debugging

- Der Installer prüft am Ende selbst: `systemctl is-active signudoc` + `postgresql`,
  HTTP-Antwort der Web-UI (lokal + vom Proxmox-Host aus) und gibt eine Summary mit URL aus.
- Bei Fehlern: vollständige Fehlerkette (Exit-Code, Zeile, Befehl, Log-Auszüge,
  Container-Logs) + Angebot für `bash -x`-Trace via `--debug`.

## Lizenz

Installer-Code: MIT (LICENSE). SignuDoc selbst: MIT, siehe
[NYLLON-SOFTWARE/SignuDoc](https://github.com/NYLLON-SOFTWARE/SignuDoc).