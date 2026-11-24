#!/usr/bin/env bash
# =============================================================================
#  ✍️  SignuDoc – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/SignuDoc-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  SignuDoc (https://github.com/NYLLON-SOFTWARE/SignuDoc, MIT) – die
#  Open-Source-e-Signature-Plattform (DocuSign-Alternative): PDF hochladen,
#  Signatur-Felder platzieren, Signatur-Links verteilen, signiertes PDF +
#  manipulationssicheres Audit-Zertifikat (PAdES-Siegel). Nach dem Vorbild
#  der Proxmox VE Community Scripts.
#
#  Architektur im Container: natives Node.js 24 (SignuDoc ist eine
#  Next.js-/React-App, kein Docker-Stack nötig) + PostgreSQL 17 (nur auf
#  127.0.0.1 – keine Datenbank-Exposition) + systemd-Service 'signudoc'
#  (Restart=always, bootet automatisch). Vollständig LOKAL: E-Mails laufen
#  im Capture-Modus als JSON in /var/lib/signudoc/outbox (kein Cloud-Dienst,
#  kein SMTP-Port nötig) – Signer-Links holst du per pct exec ab.
#
#  Wichtig: Die erste Person, die /setup öffnet, legt Organisation +
#  Administrator-Account an. Mit --setup-token wird /setup zusätzlich durch
#  ein Geheimnis geschützt (empfohlen, sobald der CT aus dem LAN erreichbar
#  ist). Details im README und in der Summary am Ende.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SignuDoc-Proxmox/main/install/signudoc.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 4096 --port 8080 --setup-token DEIN-GEHEIMNIS
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.4"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="signudoc"
UPSTREAM_OWNER="NYLLON-SOFTWARE"
UPSTREAM_REPO="SignuDoc"
SIGNUDOC_VERSION="v0.9.0"   # Upstream-Tag-Pin (git-Tag mit 'v'); --version überschreibt;
                            # --update zieht den hier gepinnten Stand (kein Tracking von main)
NODE_MAJOR="24"             # SignuDoc braucht Node.js 24.x (package.json "engines")
APP_DIR="/opt/signudoc"     # Projektverzeichnis im Container
APP_USER="signudoc"         # Service läuft als eigener Benutzer (kein root)
APP_GROUP="signudoc"
DATA_DIR="/var/lib/signudoc"  # .env (root-only) + outbox (E-Mail-Capture) + storage (PDFs)
OUTBOX_DIR="${DATA_DIR}/outbox"
STORAGE_DIR="${DATA_DIR}/storage"
LOG_DIR="/var/log/signudoc"
DB_NAME="signudoc"
DB_USER="signudoc"
DB_HOST="127.0.0.1"
DB_PORT="5432"
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="signudoc"
CT_STORAGE="local-lvm"
CT_ROOTFS=8                 # GB – Node-Build (~2 GB) + Postgres + wachsende PDFs
CT_CORES=2                  # Next.js-Build (webpack/turbopack) ist CPU-hungrig
CT_MEMORY=2048              # MB – Node-Build braucht ~1,5 GB, Betrieb ~400 MB
CT_SWAP=2048                # MB Puffer für Build-Spitzen
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
UI_PORT=8080                # Web-UI-Port auf der CT-IP (intern lauscht Next.js auf 3000)
SETUP_TOKEN=""              # --setup-token: schützt die /setup-Seite (leer = offen)
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SignuDoc-Proxmox/main/install/signudoc.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Service), falls schon ein
# Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + PostgreSQL + signudoc-Service):"
        pct exec "$CT_ID" -- sh -c '
            echo "--- /var/log/signudoc-setup.log (letzte 40 Zeilen) ---"
            tail -n 40 /var/log/signudoc-setup.log 2>/dev/null || true
            echo "--- journalctl -u signudoc (letzte 25 Zeilen) ---"
            journalctl -u signudoc --no-pager 2>/dev/null | tail -n 25 || true
            echo "--- journalctl -u postgresql (letzte 15 Zeilen) ---"
            journalctl -u postgresql --no-pager 2>/dev/null | tail -n 15 || true
            echo "--- systemctl is-active ---"
            systemctl is-active signudoc postgresql 2>/dev/null || true
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    # --id gewinnt immer; sonst Hostname-Suche mit Fallback über pct config
    # (pct list-Spalten variieren – Name ist $NF, Lock-Spalte meist leer).
    if [[ -n "$CT_ID" ]]; then
        if pct status "$CT_ID" &>/dev/null; then
            echo "$CT_ID"
            return 0
        fi
        return 0
    fi
    local id
    id=$(pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}')
    if [[ -n "$id" ]]; then
        echo "$id"
        return 0
    fi
    # Fallback: jede VMID einzeln prüfen (portabel, siehe Dograh-Grube 27)
    while read -r id; do
        [[ -n "$id" ]] || continue
        if pct config "$id" 2>/dev/null | grep -q "^hostname: ${CT_HOSTNAME}$"; then
            echo "$id"
            return 0
        fi
    done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
    return 0
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – apt/npm/git brauchen Namensauflösung.
    # Live-Fall (2026-11-10, CT 200): DNS ist FLAKY – ein einzelner getent-Erfolg
    # reichte, Stunden später war wieder alles tot. Deshalb: 3 Erfolge in Folge
    # verlangen; eine einzige Störung in diesem Fenster → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts deb.debian.org >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts deb.debian.org >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).
  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1
  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    state="${state#status: }"
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

host_arch() {
    # Host-Architektur auf die Template-Suffixe mappen (Live-Grube: auf einem
    # x86-Host darf NIE ein arm64-Template gewählt werden, auch wenn es die
    # neuere Versionsnummer trägt – ProxSmartHome 2026-11-22).
    case "$(uname -m 2>/dev/null || echo "unbekannt")" in
        x86_64)         echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)              echo "" ;;
    esac
}

verify_ct_started() {
    # Exit-0-Täuschung (Live-Grube DatacenterManager/ProxSmartHome): `pct create
    # --start 1` kann Exit 0 liefern, obwohl der Start intern scheitert
    # ("Failed to spawn container" – u. a. bei Architektur-Mismatch des
    # Templates). Deshalb: Status prüfen, bei Defekt einmal pct start mit
    # sichtbarer Ausgabe versuchen und sonst mit KOMPLITTER Fehlerkette die().
    local id="$1" state out=""
    state=$(pct status "$id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" == "running" ]]; then
        ok "Container $id läuft (Status: running)"
        return 0
    fi
    warn "Container $id läuft NICHT (Status: ${state:-unbekannt}) – 'pct create --start 1' hat es nicht gestartet."
    info "Start-Versuch mit vollständiger Fehlerausgabe:"
    out=$(pct start "$id" 2>&1 || true)
    while IFS= read -r line; do
        echo "    $line"
    done <<< "$out"
    if pct status "$id" 2>/dev/null | grep -q 'status: running'; then
        warn "Container $id läuft nach manuellem pct start – fahre fort."
        return 0
    fi
    die "Container $id startet nicht.\n  pct start sagte: ${out:-<keine Ausgabe>}\n  Häufigste Ursache: Template-Architektur ≠ Host-Architektur ($(uname -m) → $(host_arch || echo unbekannt)) – dies ist ein Installer-Bug, bitte melden.\n  Manuell prüfen: pct start $id && pct status $id && journalctl -u pveproxy -n 50"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)           CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)     CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)      CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)       CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)        CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)       CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)         CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)       CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)           CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)      CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)     CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)       CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)         UI_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --version)      SIGNUDOC_VERSION="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --setup-token)  SETUP_TOKEN="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)        FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)       ASSUME_YES=true; i=$((i+1)) ;;
            --update)       UPDATE=true; i=$((i+1)) ;;
            --uninstall)    UNINSTALL=true; i=$((i+1)) ;;
            --status)       STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)        set -x; i=$((i+1)) ;;
            --help|-h)      print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (--help zeigt alle Optionen)" ;;
        esac
    done
    # Port hart validieren – er landet direkt in der .env im Container.
    if ! [[ "$UI_PORT" =~ ^[0-9]+$ ]] || [[ "$UI_PORT" -lt 1 || "$UI_PORT" -gt 65535 ]]; then
        die "Ungültiger Port: '$UI_PORT' (1–65535 erwartet, z. B. --port 8080)"
    fi
    # Versions-Pin hart validieren – landet in git clone --branch.
    if ! [[ "$SIGNUDOC_VERSION" =~ ^v?[0-9A-Za-z._-]+$ ]]; then
        die "Ungültige Versions-Pin-Angabe: '$SIGNUDOC_VERSION' (erwartet z. B. v0.9.0)"
    fi
    if [[ -n "$SETUP_TOKEN" && ${#SETUP_TOKEN} -lt 8 ]]; then
        die "--setup-token ist zu kurz (${#SETUP_TOKEN} Zeichen) – mindestens 8 verwenden."
    fi
}

print_help() {
    cat <<'EOF'
✍️  SignuDoc – Proxmox-Installer (lokale e-Signatur-Plattform, NYLLON-SOFTWARE/SignuDoc)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SignuDoc-Proxmox/main/install/signudoc.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID            Container-ID (Default: nächste freie ab 200)
  --hostname NAME    Container-Hostname (Default: signudoc)
  --storage NAME     Storage für rootfs (Default: local-lvm)
  --rootfs GB        Disk-Größe (Default: 8 – Node-Build ~2 GB + Postgres + PDFs)
  --cores N          vCPUs (Default: 2 – Next.js-Build ist CPU-hungrig)
  --memory MB        RAM (Default: 2048 – Build ~1,5 GB, Betrieb ~400 MB)
  --swap MB          Swap (Default: 2048)
  --bridge BR        Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR          Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
                     Empfohlen: feste IP oder DHCP-Reservierung, damit die
                     Links dauerhaft stimmen (beim Boot wird synchronisiert).
  --gateway GW       Gateway für statische IP
  --password PW      Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD      Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT        Web-UI-Port (Default: 8080)
  --version V        Upstream-Tag-Pin überschreiben (Default: v0.9.0)
  --setup-token T    /setup-Seite durch Geheimnis schützen (min. 8 Zeichen)
  --force            Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y         Rückfragen überspringen
  --update           SignuDoc im bestehenden Container aktualisieren
                     (.env, Datenbank und PDFs bleiben erhalten)
  --uninstall        Container stoppen und löschen (ALLE Daten gehen verloren!)
  --status           Status anzeigen
  --debug            Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}
# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (Ports, Version, Token, DNS) kommen als Umgebungsvariablen via
# `pct exec -- env …` in den Container. Das vermeidet die Escaping-Grube bei
# Compose-/Shell-Sonderzeichen komplett.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# SignuDoc In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: APP_DIR, APP_USER, APP_GROUP, DATA_DIR, OUTBOX_DIR,
#   STORAGE_DIR, LOG_DIR, DB_NAME, DB_USER, DB_HOST, DB_PORT,
#   SIGNUDOC_VERSION, NODE_MAJOR, UI_PORT, HOST_DNS, SETUP_TOKEN_IN, APPLY_SETUP_TOKEN
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo -e "✘ $1" >&2; }
ok(){  echo -e "✔ $1"; }
warn(){ echo -e "⚠ $1"; }
die(){ err "$1"; exit 1; }

: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${APP_USER:?APP_USER fehlt (env)}"
: "${APP_GROUP:?APP_GROUP fehlt (env)}"
: "${DATA_DIR:?DATA_DIR fehlt (env)}"
: "${OUTBOX_DIR:?OUTBOX_DIR fehlt (env)}"
: "${STORAGE_DIR:?STORAGE_DIR fehlt (env)}"
: "${LOG_DIR:?LOG_DIR fehlt (env)}"
: "${SIGNUDOC_VERSION:?SIGNUDOC_VERSION fehlt (env)}"
: "${NODE_MAJOR:?NODE_MAJOR fehlt (env)}"
: "${UI_PORT:?UI_PORT fehlt (env)}"

# ── Stale-Repo-Bereinigung + toleranter apt-Helfer ─────────────────────────
#
# Live-Grube 2026-11-23 (ProxSmartHome, CT 207): Der allererste Installer-Lauf
# (v1.0.0) schrieb `deb https://deb.nodesource.com/node_24.x trixie main` in
# /etc/apt/sources.list.d/nodesource.list. NodeSource hat für Debian 13 (trixie)
# KEIN Release → JEDER weitere `apt-get update` stirbt mit Exit 100
# ("does not have a Release file") – und das VOR der Node-Reparatur, sodass der
# Update-Pfad gar nicht erst bis zum Fix kam. Deshalb:
#   1. Stale-Codename-Repos VOR jedem apt-get update auf `nodistro` umschreiben
#      (oder ganz entfernen) – idempotent, mehrfach aufrufbar.
#   2. apt-get update generell tolerant: ein kaputtes Fremd-Repo darf die
#      Installation nicht beenden (die Paket-Install selbst prüft der Aufrufer).
fix_stale_nodesource_repo() {
    local f=/etc/apt/sources.list.d/nodesource.list
    [[ -f "$f" ]] || return 0
    grep -q 'deb.nodesource.com' "$f" 2>/dev/null || return 0
    if grep -q 'nodistro' "$f" 2>/dev/null; then
        return 0
    fi
    warn "Stale NodeSource-Repo erkannt (Codename statt 'nodistro') – repariere es:"
    sed -i -E 's#(deb\.nodesource\.com/node_[0-9]+\.x)[[:space:]]+[^[:space:]]+#\1 nodistro#' "$f" 2>/dev/null || true
    grep -q 'nodistro' "$f" 2>/dev/null || rm -f "$f"   # Notausgang: Repo ganz weg
    sed -n 's/^/    /p' "$f" 2>/dev/null || true
    return 0
}

apt_update_tolerant() {
    # ein kaputtes Fremd-Repo (z. B. NodeSource-trixie) darf Exit 100 liefern,
    # ohne die Installation zu beenden – die eigentliche Paket-Installation
    # prüft der Aufrufer separat.
    if ! apt-get update -qq >/dev/null 2>&1; then
        fix_stale_nodesource_repo
        if ! apt-get update -qq >/dev/null 2>&1; then
            warn "apt-get update meldet weiterhin Fehler (fremde Repos?) – fahre fort;"
            warn "die Installation prüft jedes Paket einzeln. Details: apt-get update"
        fi
    fi
    return 0
}

echo ">>> curl sicherstellen (nacktes Debian-Template hat KEIN curl) ..."
fix_stale_nodesource_repo
if ! command -v curl >/dev/null 2>&1; then
    apt_update_tolerant
    apt-get install -y -qq curl ca-certificates >/dev/null
fi

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
# (chattr +i funktioniert in unprivilegierten LXCs nicht – fehlendes Capability,
#  Live-Fund 2026-11-10: CT-DNS war nach Stunden wieder kaputt.)
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# SignuDoc: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf

echo ">>> Benutzer '${APP_USER}' anlegen (Systemnutzer, keine Shell) ..."
if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    groupadd --system "$APP_GROUP" || die "groupadd fehlgeschlagen"
fi
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --gid "$APP_GROUP" --home-dir "$APP_DIR" \
        --shell /usr/sbin/nologin --comment "SignuDoc service user" "$APP_USER" \
        || die "useradd fehlgeschlagen"
    ok "Benutzer '${APP_USER}' angelegt"
fi

echo ">>> Verzeichnisse anlegen (Daten, Logs, E-Mail-Outbox, PDF-Storage) ..."
install -d -m 0755 -o "$APP_USER" -g "$APP_GROUP" "$APP_DIR"
install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" "$DATA_DIR"
install -d -m 0700 -o "$APP_USER" -g "$APP_GROUP" "$OUTBOX_DIR"
install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" "$STORAGE_DIR"
install -d -m 0755 -o root -g root "$LOG_DIR"
( umask 022; touch "$LOG_DIR/signudoc.log" "$LOG_DIR/signudoc-setup.log" )
chmod 0644 "$LOG_DIR/signudoc.log" "$LOG_DIR/signudoc-setup.log"

echo ">>> Datenbank + Benutzer anlegen (idempotent) ..."
# Passwort: deterministisch aus bestehender .env übernehmen, sonst neu generieren.
# (idempotent: bei Re-Run/new --update bleibt das Passwort = .env-Wert erhalten)
DB_PW_FILE="${DATA_DIR}/.db_password"
if [[ -s "$DB_PW_FILE" ]]; then
    DB_PASSWORD=$(cat "$DB_PW_FILE")
else
    DB_PASSWORD=$(openssl rand -hex 24 2>/dev/null || od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
    ( umask 077; printf '%s' "$DB_PASSWORD" > "$DB_PW_FILE" )
fi

echo ">>> Basispakete installieren (git, build-tools für native npm-Module, …) ..."
apt_update_tolerant
apt-get install -y -qq --no-install-recommends \
    git ca-certificates curl gnupg lsb-release \
    build-essential python3 pkg-config \
    openssl >/dev/null

echo ">>> PostgreSQL 17 (PGDG-Repo) installieren ..."
# SignuDoc braucht Postgres (pg-Treiber). PGDG liefert 17 für Debian 13 (trixie).
if ! command -v psql >/dev/null 2>&1 || ! dpkg -s postgresql-17 >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/pgdg.asc ]]; then
        curl -fsSL --retry 3 https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            -o /etc/apt/keyrings/pgdg.asc || die "PGDG-Key nicht ladbar (postgresql.org nicht erreichbar?)"
    fi
    CODENAME=$(lsb_release -cs 2>/dev/null || echo trixie)
    echo "deb [signed-by=/etc/apt/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
    apt_update_tolerant
    apt-get install -y -qq postgresql-17 >/dev/null \
        || apt-get install -y -qq postgresql >/dev/null \
        || die "PostgreSQL-Installation fehlgeschlagen (apt-Ausgabe siehe Setup-Log)"
else
    echo "    PostgreSQL bereits installiert"
fi
systemctl enable postgresql >/dev/null 2>&1 || true
if ! systemctl is-active --quiet postgresql; then
    systemctl start postgresql
    for _ in $(seq 1 30); do
        systemctl is-active --quiet postgresql && break
        sleep 1
    done
fi
systemctl is-active --quiet postgresql || die "PostgreSQL-Dienst startet nicht.\n  Debug: journalctl -u postgresql -e"
ok "PostgreSQL läuft"


if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" 2>/dev/null | grep -q 1; then
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}'\"" \
        || die "DB-Rolle anlegen fehlgeschlagen"
    ok "DB-Rolle '${DB_USER}' angelegt"
else
    # Rolle existiert – Passwort auf den .env-Stand angleichen (fixe Idempotenz)
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}'\"" \
        || die "DB-Rolle aktualisieren fehlgeschlagen"
fi
if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" 2>/dev/null | grep -q 1; then
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}\"" \
        || die "Datenbank anlegen fehlgeschlagen"
    ok "Datenbank '${DB_NAME}' angelegt"
fi
ok "Datenbank '${DB_NAME}' + Benutzer '${DB_USER}' bereit (nur 127.0.0.1:${DB_PORT} – keine Netz-Exposition)"

echo ">>> Node.js ${NODE_MAJOR}.x installieren (NodeSource, Fallback nodejs.org) ..."
# SignuDoc braucht exakt Node 24 (package.json "engines": "24.x") + npm (Next.js).
#
# Live-Grube 2026-11-23 (ProxSmartHome, CT 207): NodeSource hat FÜR DEBIAN 13
# (trixie) KEIN Distributions-Repo – `.../node_24.x/dists/trixie/Release` → 404.
# Der apt-Codename führte still zum apt-Warnpfad, und apt installierte Debians
# nodejs 20.19.2 (OHNE npm) → "npm: command not found" mitten im Build.
# ZWEI Massnahmen:
#  1. Immer die distro-unabhängige `nodistro`-Distribution nutzen (funktioniert
#     auf trixie, bookworm, jammy, … – NodeSource dokumentiert das so).
#  2. Version + npm NACH der Installation HAR T prüfen; passt es nicht, das
#     offizielle Binary-Tarball von nodejs.org installieren ( Fallback).
NODE_VER_OK=0
node_major() { node -v 2>/dev/null | cut -c2- | cut -d. -f1; }
if command -v node >/dev/null 2>&1 && [[ "$(node_major)" -ge ${NODE_MAJOR} ]] \
   && command -v npm >/dev/null 2>&1; then
    NODE_VER_OK=1
else
    install -d -m 0755 /etc/apt/keyrings
    # 1) NodeSource (nodistro) – Key immer dearmoren (kompatibel mit apt ≥ 2.4)
    if curl -fsSL --retry 3 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            -o /tmp/nodesource.gpg 2>/dev/null; then
        gpg --dearmor < /tmp/nodesource.gpg > /etc/apt/keyrings/nodesource.gpg 2>/dev/null \
            || warn "nodesource-Key konnte nicht dearmort werden"
        rm -f /tmp/nodesource.gpg
    else
        warn "nodesource-Key nicht ladbar – überspringe NodeSource"
    fi
    if [[ -s /etc/apt/keyrings/nodesource.gpg ]]; then
        # nodistro = distro-unabhängig (trixie/bookworm/jammy) – NICHT den
        # lsb_release-Codename verwenden (hat auf Debian 13 ins Leere gezeigt).
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        apt_update_tolerant
        if ! apt-get install -y -qq nodejs >/dev/null 2>&1; then
            warn "NodeSource-Installation von nodejs fehlgeschlagen (Repo/Netz?)"
        fi
    fi
    # harte Nachprüfung: Major-Version UND npm müssen stimmen
    if command -v node >/dev/null 2>&1 && [[ "$(node_major)" -ge ${NODE_MAJOR} ]] \
       && command -v npm >/dev/null 2>&1; then
        NODE_VER_OK=1
    else
        warn "Node.js ${NODE_MAJOR}.x + npm nicht über NodeSource verfügbar –"
        warn "offizielles Binary-Tarball (nodejs.org) als Fallback ..."
        # 2) Fallback: offizielles Tarball (nodejs.org) – unabhängig von apt/Repo
        NODE_DL_ARCH=""
        case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
            amd64|x86_64)   NODE_DL_ARCH="x64" ;;
            arm64|aarch64)  NODE_DL_ARCH="arm64" ;;
        esac
        if [[ -z "$NODE_DL_ARCH" ]]; then
            warn "Fallback fehlgeschlagen: Host-Architektur ($(dpkg --print-architecture 2>/dev/null || uname -m)) wird von nodejs.org nicht unterstützt."
            NODE_DL_ARCH=""
        fi
        NODE_ROOT="/opt/node-${NODE_MAJOR}"
        TARBALL=$(curl -fsSL --retry 3 "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
            | grep -o "node-v${NODE_MAJOR}\.[0-9.]*-linux-${NODE_DL_ARCH}\.tar\.xz" | head -1 || true)
        if [[ -z "$TARBALL" ]]; then
            warn "Fallback fehlgeschlagen: kein node-v${NODE_MAJOR}.*-linux-${NODE_DL_ARCH}.tar.xz auf nodejs.org gefunden."
            TARBALL=""
        fi
        if [[ -n "$TARBALL" ]]; then
            echo "    Fallback: ${TARBALL}"
            if curl -fsSL --retry 3 "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${TARBALL}" \
                    -o /tmp/node.tar.xz; then
                mkdir -p "$NODE_ROOT"
                if tar -xJf /tmp/node.tar.xz -C "$NODE_ROOT" --strip-components=1; then
                    ln -sf "$NODE_ROOT/bin/node" /usr/local/bin/node
                    ln -sf "$NODE_ROOT/bin/npm"  /usr/local/bin/npm
                    ln -sf "$NODE_ROOT/bin/npx"  /usr/local/bin/npx
                else
                    warn "node-Tarball entpacken fehlgeschlagen (xz-utils installiert?)"
                fi
                rm -f /tmp/node.tar.xz
            else
                warn "node-Tarball nicht ladbar: ${TARBALL}"
            fi
        fi
        if command -v node >/dev/null 2>&1 && [[ "$(node_major)" -ge ${NODE_MAJOR} ]] \
           && command -v npm >/dev/null 2>&1; then
            NODE_VER_OK=1
        fi
    fi
fi
if [[ "$NODE_VER_OK" -ne 1 ]]; then
    err "Node.js ${NODE_MAJOR}.x + npm konnten NICHT installiert werden."
    err "  node:  $(command -v node || echo fehlt)  $(node -v 2>/dev/null || echo '-')"
    err "  npm:   $(command -v npm  || echo fehlt)  $(npm -v 2>/dev/null || echo '-')"
    err "  apt:   $(apt-cache policy nodejs 2>/dev/null | sed -n '2p' | tr -s ' ')"
    err "  Debug: apt-get install -y nodejs npm && node -v && npm -v"
    die "Node.js ${NODE_MAJOR}.x + npm sind Pflicht (SignuDoc: next build). Manueller Fix im CT: pct exec <CT-ID> -- bash"
fi
ok "Node.js $(node -v 2>/dev/null) (npm $(npm -v 2>/dev/null || echo '?')) installiert"

echo ">>> SignuDoc ${SIGNUDOC_VERSION} klonen (idempotent) ..."
cd "$APP_DIR"
if [[ ! -d "$APP_DIR/.git" ]]; then
    # Erste Installation ODER defekter Stand → frisch klonen
    [[ -z "$(ls -A "$APP_DIR" 2>/dev/null)" ]] || warn "APP_DIR nicht leer, aber kein git-Repo – Inhalt bleibt, clone daneben fehlgeschlagen wäre fatal."
    git clone --depth 1 --branch "$SIGNUDOC_VERSION" \
        https://github.com/NYLLON-SOFTWARE/SignuDoc.git "$APP_DIR" \
        || die "git clone fehlgeschlagen (Netz/Tag existiert? --version prüfen)"
    ok "SignuDoc ${SIGNUDOC_VERSION} geklont"
elif [[ -f "$APP_DIR/.keep-build-marker" ]]; then
    # Update-Pfad: Arbeitsbaum leeren (schließt .env/storage-Reste aus APP_DIR aus,
    # sie liegen in DATA_DIR) und Tag neu auschecken
    git -C "$APP_DIR" fetch --depth 1 origin "refs/tags/${SIGNUDOC_VERSION}:refs/tags/${SIGNUDOC_VERSION}" \
        || die "git fetch von Tag ${SIGNUDOC_VERSION} fehlgeschlagen"
    git -C "$APP_DIR" checkout -q -f "$SIGNUDOC_VERSION" \
        || die "git checkout ${SIGNUDOC_VERSION} fehlgeschlagen"
    git -C "$APP_DIR" clean -fdq -e node_modules
    ok "SignuDoc auf ${SIGNUDOC_VERSION} aktualisiert"
fi
git -C "$APP_DIR" describe --tags 2>/dev/null | sed 's/^/    HEAD: /' || true

echo ">>> .env schreiben (Secrets bleiben bei Update erhalten) ..."
umask 077
ENV_FILE="$APP_DIR/.env"
dotenv_get() {
    local key=$1 line
    [[ -f "$ENV_FILE" ]] || { return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < "$ENV_FILE"
    return 0
}
dotenv_set() {
    local key=$1 value=$2 tmp="$ENV_FILE.tmp.$$" line updated=false
    if [[ -f "$ENV_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                "$key"=*) printf '%s=%s\n' "$key" "$value"; updated=true ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < "$ENV_FILE" > "$tmp"
        if [[ "$updated" != "true" ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
        fi
    else
        printf '%s=%s\n' "$key" "$value" > "$tmp"
    fi
    mv -f "$tmp" "$ENV_FILE"
}
generate_secret() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; return 0; fi
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

# APP_URL = Loopback (http://127.0.0.1:<PORT>). Zwei Gründe:
#  1. Next.js läuft im CT auf 127.0.0.1:<PORT>; Links/Auth-Callbacks baut die
#     App aus APP_URL – Loopback-Origin ist die einzige Origin, die validatePublicUrl
#     in NODE_ENV=production ohne https akzeptiert (exakt der dokumentierte
#     Selbsthosting-Weg der Upstream-eigenen e2e-Tests).
#  2. better-auth (trustedOrigins) akzeptiert Loopback-Aliase (localhost/127.0.0.1)
#     automatisch – Login/Registrierung vom LAN funktioniert so out-of-the-box;
#     bei IP-APP_URL müsste manuell jede Origin gepflegt werden.
# Wer eine Domain mit echtem https einträgt, setzt APP_URL in /opt/signudoc/.env
# (https://signo.example.com) + --update; dann greift der Loopback-Zwang nicht.
# v1.0.4: APP_URL wird tatsächlich geschrieben – ohne APP_URL/BETTER_AUTH_URL
# wirft SignuDoc (requireConfigValue in createAppAuth) beim ersten POST /api/setup
# einen ServiceConfigurationError und das Web-Setup endet mit der generischen
# Meldung "Setup could not be completed. Please try again." (HTTP 500).
[[ -n "$(dotenv_get APP_URL)" ]]         || dotenv_set APP_URL "http://127.0.0.1:${UI_PORT}"
[[ -n "$(dotenv_get DATABASE_URL)" ]]    || dotenv_set DATABASE_URL "postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
[[ -n "$(dotenv_get BETTER_AUTH_SECRET)" ]] || dotenv_set BETTER_AUTH_SECRET "$(generate_secret)"
[[ -n "$(dotenv_get STORAGE_DRIVER)" ]]  || dotenv_set STORAGE_DRIVER "local"
[[ -n "$(dotenv_get STORAGE_LOCAL_DIR)" ]] || dotenv_set STORAGE_LOCAL_DIR "${STORAGE_DIR}"
# E-Mail: KEIN Resend-Key gesetzt → capture-Treiber (100 % lokal, JSON-Outbox).
# NODE_ENV=production ist im Build gesetzt; capture ist bei Loopback-APP_URL
# erlaubt (validatePublicUrl lässt localhost/127.0.0.1 in Produktion zu –
# exakt der dokumentierte Selbsthosting-fremde Weg der Upstream-eigenen Tests).
[[ -n "$(dotenv_get EMAIL_DRIVER)" ]]   || dotenv_set EMAIL_DRIVER "capture"
[[ -n "$(dotenv_get EMAIL_CAPTURE_DIR)" ]] || dotenv_set EMAIL_CAPTURE_DIR "${OUTBOX_DIR}"
[[ -n "$(dotenv_get NODE_ENV)" ]]       || dotenv_set NODE_ENV "production"
[[ -n "$(dotenv_get PORT)" ]]           || dotenv_set PORT "${UI_PORT}"
[[ -n "$(dotenv_get HOSTNAME)" ]]       || dotenv_set HOSTNAME "0.0.0.0"
# SETUP_TOKEN: schützt /setup. Nur bei Installation mit --setup-token setzen;
# bei Update nur überschreiben, wenn explizit gewünscht (APPLY_SETUP_TOKEN=1).
if [[ "${APPLY_SETUP_TOKEN:-0}" == "1" && -n "${SETUP_TOKEN_IN:-}" ]]; then
    dotenv_set SETUP_TOKEN "${SETUP_TOKEN_IN}"
    echo "    SETUP_TOKEN gesetzt (per --setup-token)"
fi
# secrets-file-Rechte: .env enthält DB-Passwort + Auth-Secret → nur User lesbar
chmod 0640 "$ENV_FILE"
chown "$APP_USER:$APP_GROUP" "$ENV_FILE"
# .gitignore ergänzen, damit ein versehentliches git-add die .env nie erwischt
grep -qxF '.env' "$APP_DIR/.gitignore" 2>/dev/null || echo '.env' >> "$APP_DIR/.gitignore"
ok ".env geschrieben (Secrets bleiben bei Update erhalten; Rechte 0640, User ${APP_USER})"

echo ">>> npm-Abhängigkeiten installieren (npm ci) ..."
# als APP_USER ausführen: node_modules gehören dann dem Service-User (kein root-Besitz)
#
# WICHTIG: OHNE --omit=dev! SignuDoc ist ein Next.js-Produktionsbuild, der zur
# Build-Zeit devDependencies braucht: typescript + @types/*, tailwindcss,
# @tailwindcss/postcss, eslint-config-next. Mit --omit=dev (ursprünglicher Fehler)
# scheitert `next build` zwingend ("Cannot find module 'typescript'"). Der
# Container ist eine Build- UND Laufzeit-Unit, deshalb installieren wir alles.
if [[ -d "$APP_DIR/node_modules" && -f "$APP_DIR/package-lock.json" ]]; then
    # Update-Pfad: bei geändertem Lockfile prüft npm ci selbst und installiert ggf. neu
    :
fi
runuser -u "$APP_USER" -- bash -c "cd '$APP_DIR' && npm ci --no-audit --no-fund" \
    || die "npm ci fehlgeschlagen (siehe npm-Ausgabe im Setup-Log; Netz/Registry prüfen)"

echo ">>> Next.js Produktions-Build (npm run build) ..."
# Build braucht mehr als die Default-Speicher-Limits des Node-20-Heuristik →
# --max-old-space-size passend zu CT_MEMORY hochsetzen (2 GB Default).
# next/font/google lädt Schriften WAHREND des Builds (Netzwerk nötig) – der CT
# hat Internet; NEXT_TELEMETRY_DISABLED verhindert den anonymen Build-Ping.
runuser -u "$APP_USER" -- bash -c \
    "cd '$APP_DIR' && NODE_OPTIONS='--max-old-space-size=1536' NEXT_TELEMETRY_DISABLED=1 npm run build" \
    || die "npm run build fehlgeschlagen (siehe Build-Ausgabe im Setup-Log)\n  Hinweis: next/font/google braucht Netz zum Build; Telemetrie ist aus."

echo ">>> Migrationen ausführen (db/migrate.mjs – idempotent) ..."
runuser -u "$APP_USER" -- bash -c "cd '$APP_DIR' && npm run db:migrate" \
    || die "Datenbank-Migration fehlgeschlagen (db/migrate.mjs; DATABASE_URL in .env prüfen)"
ok "Migrationen durch"

echo ">>> systemd-Unit 'signudoc' schreiben (Restart=always) ..."
# npm-Pfad explizit auflösen (Unit braucht einen absoluten Pfad):
# NodeSource → /usr/bin/npm, nodejs.org-Fallback → /usr/local/bin/npm.
NPM_BIN=$(command -v npm 2>/dev/null || true)
[[ -n "$NPM_BIN" ]] || die "npm nicht im PATH – Unit kann nicht geschrieben werden (node: $(node -v 2>/dev/null || echo fehlt))"
echo "    npm: $NPM_BIN"
# Type=simple + next start als Main-Prozess: systemd überwacht, Restart=always
# startet bei Crash/Reboot. PORT aus der .env (UI_PORT) – next start bindet
# 0.0.0.0:<PORT>, damit die Web-UI über die CT-IP im LAN erreichbar ist.
UNIT_PATH="/etc/systemd/system/signudoc.service"
cat > "$UNIT_PATH" <<UNITEOF
[Unit]
Description=SignuDoc (lokale e-Signatur-Plattform, Next.js)
Wants=network-online.target
After=network-online.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=NODE_ENV=production
ExecStart=${NPM_BIN} run start
Restart=always
RestartSec=10
StandardOutput=append:${LOG_DIR}/signudoc.log
StandardError=append:${LOG_DIR}/signudoc.log
# Härtung: kein Schreibrecht außerhalb DATA_DIR/STORAGE (Next.js schreibt nur dorthin)
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNITEOF
chmod 0644 "$UNIT_PATH"
systemctl daemon-reload
systemctl enable signudoc >/dev/null 2>&1 || true
ok "Unit signudoc.service geschrieben + enabled"

echo ">>> Dienst starten (postgres läuft bereits) ..."
systemctl restart signudoc
for _ in $(seq 1 40); do
    systemctl is-active --quiet signudoc && break
    sleep 1
done
systemctl is-active --quiet signudoc \
    || die "signudoc-Service startet nicht.\n  Debug: journalctl -u signudoc -e"
ok "signudoc-Service läuft"

echo ">>> Warte auf Web-UI (http://127.0.0.1:${UI_PORT}/) ..."
WEB_OK=""
code="000"
for _ in $(seq 1 60); do
    # -L: Next.js leitet / je nach Zustand auf /setup oder /login um (307/302)
    code=$(curl -s -L -o /dev/null --max-time 4 -w '%{http_code}' \
           "http://127.0.0.1:${UI_PORT}/" 2>/dev/null || true)
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        WEB_OK=1
        break
    fi
    sleep 3
done
if [[ -z "$WEB_OK" ]]; then
    die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-keiner}).\n  Debug: journalctl -u signudoc -n 50 && systemctl status signudoc"
fi
ok "Web-UI antwortet (HTTP ${code})"

echo ">>> Aufräumen ..."
rm -f /tmp/nodesource.gpg
echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere SignuDoc im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war live unzuverlässig, siehe verify_ct_dns)
    local host_dns
    host_dns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden (Grube 14).
    # SETUP_TOKEN wird nur bei explizitem Flag gesetzt (Update erhält Bestand).
    local apply_setup_token=0
    if [[ -n "$SETUP_TOKEN" ]]; then
        apply_setup_token=1
    fi
    pct exec "$ct_id" -- env \
        APP_DIR="$APP_DIR" APP_USER="$APP_USER" APP_GROUP="$APP_GROUP" \
        DATA_DIR="$DATA_DIR" OUTBOX_DIR="$OUTBOX_DIR" STORAGE_DIR="$STORAGE_DIR" \
        LOG_DIR="$LOG_DIR" DB_NAME="$DB_NAME" DB_USER="$DB_USER" \
        DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" \
        SIGNUDOC_VERSION="$SIGNUDOC_VERSION" NODE_MAJOR="$NODE_MAJOR" \
        UI_PORT="$UI_PORT" HOST_DNS="${host_dns:-1.1.1.1}" \
        SETUP_TOKEN_IN="$SETUP_TOKEN" APPLY_SETUP_TOKEN="$apply_setup_token" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/signudoc-setup.log'
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # systemd-Service aktiv? (bis zu 30 s Nachlauf – Build/Start kann dauern)
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet signudoc 2>/dev/null; then
            ok "Service signudoc läuft (systemctl is-active)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service signudoc läuft nicht.
  Debug: pct exec $ct_id -- journalctl -u signudoc -n 50 && pct exec $ct_id -- systemctl status signudoc"
        fi
        sleep 1
    done

    # PostgreSQL aktiv? (SignuDoc bootet ohne DB nicht sinnvoll)
    if pct exec "$ct_id" -- systemctl is-active --quiet postgresql 2>/dev/null; then
        ok "Service postgresql läuft (systemctl is-active)"
    else
        warn "Service postgresql läuft NICHT – App startet evtl. trotzdem (Verbindungen erst bei Bedarf)."
        info "Logs: pct exec $ct_id -- journalctl -u postgresql -n 30"
    fi

    # Web-UI antwortet? (Grube: curl -w gibt bei Verbindungsfehler bereits
    # 000 aus – NIE zusätzlich || echo 000 anhängen, sonst falsch-positiv.)
    tries=0
    code="000"
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -L -o /dev/null --max-time 4 \
               -w '%{http_code}' "http://127.0.0.1:${UI_PORT}/" 2>/dev/null || true)
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Web-UI antwortet (HTTP ${code} auf Port ${UI_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).
  Debug: pct exec $ct_id -- journalctl -u signudoc -n 50
  Hinweis: /setup ist die erste Seite – sie antwortet erst nach abgeschlossenem Build."
        fi
        sleep 2
    done

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -s -L -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${UI_PORT}/" 2>/dev/null || true)
        if [[ "$host_code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${UI_PORT} (HTTP ${host_code})"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über http://${ct_ip}:${UI_PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "✍️  SignuDoc ist bereit!"

    local ct_ip=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<CT-IP>"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:     http://${ct_ip}:${UI_PORT}${NC}"
    echo -e "  ${GREEN}  ⚙️  Einrichtung: http://${ct_ip}:${UI_PORT}/setup${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:   pct enter ${CT_ID}${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔑 Root-PW:    ${CT_PASSWORD}${NC}"
    fi
    echo -e "  ${GREEN}  🔧 Installer:  v${INSTALLER_VERSION} (upstream ${UPSTREAM_OWNER}/${UPSTREAM_REPO})${NC}"
    echo -e "  ${GREEN}  📦 Upstream:   SignuDoc ${SIGNUDOC_VERSION} (Node ${NODE_MAJOR})${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Erste Schritte:${NC}"
    echo "  1. http://${ct_ip}:${UI_PORT}/setup öffnen – Organisation anlegen,"
    echo "     Support-Adresse eintragen und den ersten (Admin-)Account erstellen."
    if [[ -n "$SETUP_TOKEN" ]]; then
        echo "  2. /setup fragt nach dem Setup-Token: ${SETUP_TOKEN}"
    else
        echo "  2. /setup ist aktuell OHNE Token erreichbar – wer die URL zuerst"
        echo "     öffnet, wird Administrator. Für den LAN-Betrieb empfohlen:"
        echo "       ${ONE_LINER} --update --setup-token DEIN-GEHEIMNIS"
    fi
    echo ""
    echo -e "  ${CYAN}E-Mails (100 % lokal, Capture-Modus):${NC}"
    echo "  Einladungen/Erinnerungen werden als JSON nach"
    echo "  ${OUTBOX_DIR}/ geschrieben (keine Cloud, kein SMTP nötig)."
    echo "  Signer-Link einer Nachricht holen:"
    echo "    pct exec ${CT_ID} -- ls -t ${OUTBOX_DIR} | head"
    echo "    pct exec ${CT_ID} -- cat ${OUTBOX_DIR}/<datei>.json"
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:     ${ONE_LINER} --status"
    echo "  Update:     ${ONE_LINER} --update"
    echo "  Deinstall:  ${ONE_LINER} --uninstall"
    echo "  Service-Log: pct exec ${CT_ID} -- journalctl -u signudoc -f"
    echo ""
    warn "Daten (Postgres unter /var/lib/postgresql, PDFs in ${STORAGE_DIR},"
    warn "E-Mail-Outbox in ${OUTBOX_DIR}) liegen im CT – ein --update erhält sie,"
    warn "pct destroy löscht sie. Für Backups: pct backup / vzdump."
    if [[ "$CT_IP" == "dhcp" ]]; then
        warn "CT hat DHCP – Links/APP_URL sind auf Loopback gepinnt (unabhängig"
        warn "von der CT-IP); trotzdem empfohlen: DHCP-Reservierung im Router."
    fi
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "✍️  Installiere SignuDoc (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden? (Hostname-Suche; --id im Feld gewinnt)
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.
  Update:       ${ONE_LINER} --update
  Neu aufsetzen: ${ONE_LINER} --force"
        fi
    fi

    # Debian-Template sicherstellen (13 bevorzugt – Node 24/Docker-PGDG unterstützen trixie).
    # WICHTIG: Arch-Filter! Auf einem Host können Templates FREMder Architektur
    # im Cache liegen (Live-Grube ProxSmartHome 2026-11-22: arm64-Template mit
    # NEUERER Versionsnummer als das passende amd64 → Spawn-Fehler). Deshalb
    # wird zuerst auf die Host-Architektur gefiltert, dann versionssortiert.
    header "🧱 Container-Template"
    local arch template="" t_arch
    arch=$(host_arch)
    if [[ -z "$arch" ]]; then
        die "Host-Architektur $(uname -m) wird nicht unterstützt (amd64/arm64 erwartet)."
    fi
    info "Host-Architektur: $(uname -m) → Template-Suffix '${arch}'"

    template=$(pveam list local 2>/dev/null | awk '{print $1}' \
        | grep -o "debian-1[23]-standard[^ ]*_${arch}\\.tar[^ ]*" | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein passendes Debian-12/13-Template (${arch}) vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null \
            | grep -o "debian-1[23]-standard[^ ]*_${arch}\\.tar[^ ]*" | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-12/13-standard-Template für ${arch} gefunden (pveam available leer?)."
        fi
        pveam download local "$template"
    fi
    ok "Template: $template"

    # Gegenprobe: geladenes Template muss zur Host-Architektur passen – falls
    # pveam (unerwartet) ein Fremd-Arch-Template liefert, hier hart abbrechen
    # statt später mit kryptischem Spawn-Fehler.
    # (Nicht mit tr -d '_.tar' arbeiten – das löscht die Zeichen einzeln!)
    t_arch="${template%.tar*}"      # debian-13-standard_13.6-1_amd64
    t_arch="${t_arch##*_}"          # amd64
    if [[ "$t_arch" != "$arch" ]]; then
        die "Template '${template}' passt nicht zur Host-Architektur ($(uname -m) → ${arch}).
  Bitte ein ${arch}-Template bereitstellen: pveam available --section system | grep ${arch}"
    fi

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="signudoc-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    net0+=",firewall=0"
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    # pct create kann trotz intern fehlgeschlagenem Start Exit 0 liefern –
    # deshalb der explizite Status-Check mit Fehlerausgabe (Grube 10/Exit-0).
    verify_ct_started "$CT_ID"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update SignuDoc (${SIGNUDOC_VERSION} ziehen; .env + Daten bleiben erhalten)"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.
  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – .env, Datenbank und PDFs blieben erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere SignuDoc"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "ALLE Daten gehen verloren: Datenbank, PDFs, E-Mail-Outbox."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.
  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status SignuDoc"
    info "Installer-Version: v${INSTALLER_VERSION} | Upstream-Pin: ${SIGNUDOC_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $NF}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet signudoc 2>/dev/null; then
        ok "Service:   signudoc läuft (systemctl is-active)"
    else
        err "Service:   signudoc läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u signudoc -n 50"
    fi
    if pct exec "$ct_id" -- systemctl is-active --quiet postgresql 2>/dev/null; then
        ok "DB:        postgresql läuft (systemctl is-active)"
    else
        warn "DB:        postgresql läuft NICHT"
    fi

    # Installationsstand (nur KEY-Status, nie Werte)
    local upd
    upd=$(pct exec "$ct_id" -- git -C "$APP_DIR" describe --tags 2>/dev/null | head -1 || true)
    [[ -n "$upd" ]] && info "Upstream:  $upd"
    local setup_token_set
    setup_token_set=$(pct exec "$ct_id" -- sed -n 's/^SETUP_TOKEN=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    if [[ -n "$setup_token_set" ]]; then
        ok "/setup:    durch --setup-token geschützt"
    else
        warn "/setup:    OHNE Token erreichbar – jeder mit der URL wird Admin."
        warn "           Schutz: ${ONE_LINER} --update --setup-token DEIN-GEHEIMNIS"
    fi
    local mail
    mail=$(pct exec "$ct_id" -- sed -n 's/^EMAIL_DRIVER=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    [[ -n "$mail" ]] && info "E-Mail:    Treiber '${mail}' (capture = JSON-Outbox ${OUTBOX_DIR})"

    local ip code=""
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -s -L -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${UI_PORT}/" 2>/dev/null || true)
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Web-UI:    http://${ip}:${UI_PORT}  (HTTP ${code})"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von http://${ip}:${UI_PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi
