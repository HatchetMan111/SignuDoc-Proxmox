#!/usr/bin/env bash
# =============================================================================
#  🧪 SignuDoc-Proxmox – Mock-Harness
#  Testet install/signudoc.sh End-to-End gegen gemockte Proxmox-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/curl/apt/systemctl/git/node/npm-Mocks (Fakebin)
#   - Inner-Script läuft ECHT (Pfade auf Mock-Root umgeschrieben, Postgres/
#     systemd/node-Mocks) – inkl. Bootstrap-Reihenfolge (nacktes Debian: kein
#     curl → apt "installiert" curl; Node-/npm-/git-Tools aus Fakebin)
#  Usage: bash harness/run.sh [-v]   (Exit 0 = alle Cases grün)
# =============================================================================
set -u
SCRIPT="${SIGNUDOC_INSTALLER_SCRIPT:-/home/phil/Proxmox-Scripts/SignuDoc-Proxmox/install/signudoc.sh}"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }

MK=$(mktemp -d /tmp/signudoc-harness.XXXXXX)
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT
HS="$MK/state"                       # Mock-Status (ct_list, Calls, Hebel)
HOSTBIN="$MK/bin-host"               # Mocks für das HOST-Script
INNERBIN="$MK/bin-inner"             # Mocks für pct-exec (im CT)
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" \
    "$MK/etc" "$MK/root" "$MK/var/log" "$MK/tmp"
CT_IP="10.120.5.42"

echo "$CT_IP" > "$HS/ct_ip"
: > "$HS/ct_list"                    # Zeilen: "VMID Status Lock-Name(=Name letztes Feld)"
echo "getent_mode=ok" > "$HS/getent_mode"
echo "x86_64" > "$HS/host_arch"      # Host-Architektur (uname -m-Mock); "aarch64" = Fremd-Arch-Falle

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }

t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }
assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_file() {
    if [[ -f "$1" ]]; then pass "Datei: $1"
    else fail "Datei fehlt: $1"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "$1 enthält: $2"
    else fail "$1 enthält NICHT: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "$1 matcht: $2"
    else fail "$1 matcht NICHT: $2"; fi
}
assert_calls() { # COUNT needle in mock-calls log (host-mocks: pct/systemctl/apt)
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}

# ── Mock-Umgebung bauen (env -i: Profil-Funktionen wie grep→ugrep meiden) ──
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() { # echte Binaries per Symlink verfügbar halten (Shadowing via PATH-Reihenfolge)
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id hostname
ln -sf "$MK/mock-curl"  "$HOSTBIN/curl"
ln -sf "$MK/mock-pct"   "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam" "$HOSTBIN/pveam"
ln -sf "$MK/mock-uname" "$HOSTBIN/uname"
ln -sf "$MK/mock-sleep" "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep" "$INNERBIN/sleep"

# ── Inner-Fakebin: nacktes Debian simulieren (KEIN curl, KEIN node) ────────
# PATH im Inner ist AUSSCHLIESSLICH $INNERBIN (kein /usr/bin!) – sonst würde
# ein echtes node/npm/postgres des Desktops das Bootstrap-Design aushebeln.
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod chown chgrp dirname basename sort uniq printf ls touch readlink stat uname \
    tee openssl wc ln base64 tar xz dpkg mktemp
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-ip"        "$INNERBIN/ip"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"   # group/passwd/host-lookups
ln -sf "$MK/mock-git"       "$INNERBIN/git"
ln -sf "$MK/mock-node"      "$INNERBIN/node"
ln -sf "$MK/mock-npm"       "$INNERBIN/npm"
ln -sf "$MK/mock-lsb_release" "$INNERBIN/lsb_release"
ln -sf "$MK/mock-su"        "$INNERBIN/su"
ln -sf "$MK/mock-runuser"   "$INNERBIN/runuser"
ln -sf "$MK/mock-useradd"   "$INNERBIN/useradd"
ln -sf "$MK/mock-groupadd"  "$INNERBIN/groupadd"
ln -sf "$MK/mock-install"   "$INNERBIN/install"
ln -sf "$MK/mock-dpkg"      "$INNERBIN/dpkg"
ln -sf "$MK/mock-psql"      "$INNERBIN/psql"
ln -sf "$MK/mock-gpg"       "$INNERBIN/gpg"
ln -sf "$(env -i /bin/sh -c "command -v tar")"  "$INNERBIN/tar"

cat > "$MK/mock-chown" <<'EOF'
#!/usr/bin/env bash
# chown-Mock: ok wenn Zieldatei existiert (Ownership-Tracking für Assertions)
set -u
HS="${HARNESS_STATE:?}"
echo "chown $*" >> "$HS/calls.log"
args=()
for a in "$@"; do
    case "$a" in -*) ;; *) args+=("$a") ;; esac
done
last="${args[${#args[@]}-1]:-}"
[[ -e "$last" ]] || { echo "chown mock: referenzierte Datei fehlt: $last" >&2; exit 1; }
exit 0
EOF
ln -sf "$MK/mock-chown"    "$INNERBIN/chown"

seed_inner_tools() { # simuliert bereits installiertes curl+node+npm+git (Update-Pfad)
    ln -sf "$MK/mock-curl"  "$INNERBIN/curl"
    ln -sf "$MK/mock-node"  "$INNERBIN/node"
    ln -sf "$MK/mock-npm"   "$INNERBIN/npm"
    ln -sf "$MK/mock-git"   "$INNERBIN/git"
}
unseed_inner_tools() {
    rm -f "$INNERBIN/curl" "$INNERBIN/node" "$INNERBIN/npm" "$INNERBIN/git"
}

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-uname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
arch=$(/bin/cat "$HS/host_arch" 2>/dev/null || echo "x86_64")
echo "$arch"
exit 0
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="$(dirname "$HS")"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"; id="${2:-}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ $# -gt 0 ]]; then shift; fi

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    config)
        [[ -f "$HS/ct_${id}.hostname" ]] || exit 1
        echo "hostname: $(cat "$HS/ct_${id}.hostname")"; exit 0 ;;
    create)
        echo "pct $*" >> "$HS/calls.log"
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        tmpl="$1"; shift
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${id}.create"
        # Exit-0-Täuschung simulieren: create meldet Erfolg, aber der Start
        # scheitert intern ("Failed to spawn container") – Status bleibt stopped.
        if [[ -f "$HS/create_spawn_fail" ]]; then
            echo "sync_wait: 34 An error occurred in another process (expected sequence number 7)" >&2
            echo '__lxc_start: 2127 Failed to spawn container "'"$id"'"' >&2
            hostname="ct-$id"
            prev=""
            for a in "$@"; do
                if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
                prev="$a"
            done
            echo "$id stopped $hostname" >> "$HS/ct_list"
            echo "stopped" > "$HS/ct_${id}.status"
            echo "$hostname" > "$HS/ct_${id}.hostname"
            exit 0
        fi
        hostname="ct-$id"
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$id running $hostname" >> "$HS/ct_list"
        echo "running" > "$HS/ct_${id}.status"
        echo "$hostname" > "$HS/ct_${id}.hostname"
        exit 0 ;;
    start)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        if [[ -f "$HS/create_spawn_fail" ]]; then
            echo "sync_wait: 34 An error occurred in another process (expected sequence number 7)" >&2
            echo '__lxc_start: 2127 Failed to spawn container "'"$id"'"' >&2
            exit 1
        fi
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}".hostname
        exit 0 ;;
    push)
        src="$1"; dst="$2"; shift 2
        mkdir -p "$MK$(dirname "$dst")"
        # Inner-Script: ALLE absoluten Pfade (/etc, /tmp, /opt, /var, /root) auf
        # den Mock-Root umschreiben – sonst würde der Mock z. B. auf dem ECHTEN
        # /opt/signudoc mkdir-en und "Permission denied" ernten.
        # Reihenfolge: /tmp zuerst – die /etc-Ersetzung injiziert selbst ein
        # /tmp/ (Mock-Root liegt unter /tmp) und würde doppelt umgeschrieben.
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" \
                 -e "s|/opt/|${MK}/opt/|g" -e "s|/var/|${MK}/var/|g" \
                 -e "s|/usr/local/|${MK}/usr/local/|g" \
                 -e "s|/root/|$MK/root/|g" "$src" > "$MK$dst"
        exit 0 ;;
    exec)
        # pct exec ID -- env K=V... cmd...   (Grube 10: gestoppter CT → Exit 255)
        [[ "${1:-}" == "--" ]] && shift
        envs=()
        if [[ "${1:-}" == "env" ]]; then
            shift
            while [[ "${1:-}" == *=* && "${1:-}" != -* ]]; do envs+=("$1"); shift; done
        fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        if [[ -f "$HS/exec_fail" ]]; then
            echo "mock: exec erzwingt Fehler" >&2
            exit 255
        fi
        INNERBIN="$MK/bin-inner"
        rewrite_path() {
            local a="$1"
            a="${a//\/opt\/signudoc/$MK/opt/signudoc}"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/var\/lib\/signudoc/$MK/var/lib/signudoc}"
            a="${a//\/etc\//$MK/etc/}"
            a="${a//\/var\/lib\/postgresql/$MK/var/lib/postgresql}"
            a="${a//\/usr\/local\//$MK/usr/local/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "$@"; do
            newargs+=("$(rewrite_path "$a")")
        done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do
            newenvs+=("$(rewrite_path "$a")")
        done
        exec env -i PATH="$INNERBIN" \
            HARNESS_STATE="$HS" MKROOT="$MK" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    enter|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex|set)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
# pveam-Mock: Templates je Host-Architektur ($HS/host_arch):
#  - host_arch=amd64 → list/available liefern ein amd64-Template
#    (debian-13-standard_13.6-1_amd64) UND ein NEUERES arm64-Template
#    (debian-13-standard_13.9-1_arm64) – der Installer MUSS das arm64
#    ignorieren (Live-Grube ProxSmartHome 2026-11-22: genau dieser Fall!)
#  - host_arch=arm64 → nur arm64-Templates
#  - pveam_empty        → nichts vorhanden (Download-Pfad)
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
ARCH=$(/bin/cat "$HS/host_arch" 2>/dev/null || echo "amd64")
case "${1:-}" in
    list)
        if [[ -f "$HS/template_downloaded" && ! -f "$HS/pveam_empty" ]]; then
            if [[ "$ARCH" == "arm64" ]]; then
                echo "debian-13-standard_13.9-1_arm64.tar.zst  123456789"
            else
                echo "debian-13-standard_13.6-1_amd64.tar.zst  123456789"
                echo "debian-13-standard_13.9-1_arm64.tar.zst  123456789"
            fi
        fi
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            if [[ "$ARCH" == "arm64" ]]; then
                echo "system          debian-13-standard_13.9-1_arm64.tar.zst  123456789"
            else
                echo "system          debian-13-standard_13.6-1_amd64.tar.zst  123456789"
                echo "system          debian-13-standard_13.9-1_arm64.tar.zst  123456789"
            fi
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        mkdir -p "$HS/templates"
        if [[ "$ARCH" == "arm64" ]]; then
            touch "$HS/templates/debian-13-standard_13.9-1_arm64.tar.zst"
        else
            touch "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
        fi
        touch "$HS/template_downloaded"
        exit 0 ;;
esac
exit 0
EOF
echo "mocks pct/pveam written"

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: Health-/HTTP-Checks → 200/302/000; Downloads → Stub-Dateien
set -u
HS="${HARNESS_STATE:?}"
MK="${MKROOT:-$(dirname "$HS")}"   # robust: MKROOT (Inner-Ebene) oder dirname(HS)
url=""; outfile=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then outfile="$a"; fi
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

# nodejs.org: Binary-Tarball (echtes tar.xz) – MUSS VOR dem Index-Muster stehen,
# sonst matcht `*latest-v*` auch die .tar.xz-URL und liefert HTML statt Datei.
case "$url" in
    *nodejs.org/dist/*.tar.xz)
        if [[ -f "$HS/no_nodejs_org" ]]; then echo "000"; exit 7; fi
        [[ -n "$outfile" ]] || { echo "curl mock: node-tarball ohne -o" >&2; exit 1; }
        # echtes, winziges tar.xz bauen (bin/node, bin/npm, bin/npx)
        stage="$MK/node-stage"
        rm -rf "$stage"; mkdir -p "$stage/bin"
        printf '#!/bin/sh\nexit 0\n' > "$stage/bin/node"
        printf '#!/bin/sh\nexit 0\n' > "$stage/bin/npm"
        printf '#!/bin/sh\nexit 0\n' > "$stage/bin/npx"
        chmod +x "$stage"/bin/*
        tar -C "$stage" -cJf "$outfile" bin
        rm -rf "$stage"
        echo "24.11.0" > "$HS/node_v"      # Tarball = Node 24 (Fallback-Erfolg)
        ln -sf "$MK/mock-node" "$MK/bin-inner/node"
        ln -sf "$MK/mock-npm"  "$MK/bin-inner/npm"
        exit 0 ;;
    *nodejs.org/dist/latest-v*)
        if [[ -f "$HS/no_nodejs_org" ]]; then echo "000"; exit 7; fi
        # HTML-Index mit einem Tarball-Namen (Arch x64)
        printf '<a href="node-v24.11.0-linux-x64.tar.xz">node-v24.11.0-linux-x64.tar.xz</a>\n'
        exit 0 ;;
esac

# Key-Downloads (PGDG / NodeSource): Stub-Dateien schreiben
case "$url" in
    *postgresql.org/media/keys*)
        [[ -n "$outfile" ]] || { echo "curl mock: pgdg key ohne -o" >&2; exit 1; }
        printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nmock-pgdg\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$outfile"
        exit 0 ;;
    *nodesource*)
        [[ -n "$outfile" ]] || { echo "curl mock: nodesource key ohne -o" >&2; exit 1; }
        printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nmock-nodesource\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$outfile"
        exit 0 ;;
esac

# Health-/HTTP-Checks (Web-UI; 2xx/3xx zählen beide als "antwortet")
code="200"
if [[ -f "$HS/host_curl_fail" && -z "${MKROOT:-}" ]]; then
    code="000"
fi
if [[ -n "${MKROOT:-}" ]]; then
    # Inner-Ebene (Setup-Health-Checks + Verifikation über pct exec)
    [[ -f "$HS/fail_web"  ]] && code="000"
    [[ -f "$HS/web_302"   ]] && code="302"
    [[ -f "$HS/web_307"   ]] && code="307"
fi
echo "$code"
[[ "$code" == "000" ]] && exit 7 || exit 0
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl real in der Inner-Fakebin (Bootstrap-Reihenfolge)
# sowie node/npm (NodeSource-Paket) bzw. postgresql (PGDG-Paket).
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
if [[ "${1:-}" == "update" ]]; then
    # Hebel stale_nodesource: sources.list.d/nodesource.list existiert mit
    # Codename (trixie) statt nodistro → apt-get update MUSS mit Exit 100
    # scheitern (Live-Grube CT 207, v1.0.0-Rest). Sonst: Erfolg.
    if [[ -f "$HS/stale_nodesource" ]]; then
        echo "E: The repository 'https://deb.nodesource.com/node_24.x trixie Release' does not have a Release file." >&2
        exit 100
    fi
    exit 0
fi
if [[ "${1:-}" == "install" ]]; then
    for a in "$@"; do
        case "$a" in
            curl)
                [[ -e "$INNERBIN_DIR/curl" ]] || ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl" ;;
            nodejs)
                # Hebel apt_nodejs_fail=1: NodeSource-Repo nicht installierbar
                # (Live-Fall Debian 13: dists/trixie → 404, apt fällt auf
                # Debians nodejs 20 ohne npm zurück).
                if [[ -f "$HS/apt_nodejs_fail" ]]; then
                    if [[ -f "$HS/node_v_debian" ]]; then
                        # Debian-Repo liefert nodejs 20 OHNE npm
                        [[ -e "$INNERBIN_DIR/node" ]] || ln -sf "$MK/mock-node" "$INNERBIN_DIR/node"
                    fi
                else
                    [[ -e "$INNERBIN_DIR/node" ]] || ln -sf "$MK/mock-node" "$INNERBIN_DIR/node"
                    [[ -e "$INNERBIN_DIR/npm"  ]] || ln -sf "$MK/mock-npm"  "$INNERBIN_DIR/npm"
                fi ;;
            git)
                [[ -e "$INNERBIN_DIR/git" ]] || ln -sf "$MK/mock-git" "$INNERBIN_DIR/git" ;;
            postgresql*)
                [[ -e "$INNERBIN_DIR/psql" ]] || ln -sf "$MK/mock-psql" "$INNERBIN_DIR/psql" ;;
        esac
    done
fi
exit 0
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
echo "systemctl $*" >> "$HS/calls.log"
MKDIR_MOCK="$MK"
unitdir="$MKDIR_MOCK/etc/systemd/system"
sub="${1:-}"
case "$sub" in
    daemon-reload) exit 0 ;;
    enable)
        mkdir -p "$unitdir"; echo "${2:-}" >> "$HS/enabled_units"; exit 0 ;;
    restart|start)
        svc="${2:-}"
        if [[ "$svc" == "signudoc" ]]; then
            [[ -f "$unitdir/signudoc.service" ]] || { echo "mock: signudoc.service fehlt" >&2; exit 1; }
            [[ -f "$HS/signudoc_build_failed" ]] && exit 1
            touch "$HS/signudoc_active"
        elif [[ "$svc" == "postgresql" ]]; then
            touch "$HS/postgres_active"
        fi
        exit 0 ;;
    stop)
        rm -f "$HS/signudoc_active" "$HS/postgres_active"; exit 0 ;;
    is-active)
        svc="${3:-${2:-}}"
        if [[ "$svc" == "signudoc" && -f "$HS/signudoc_active" ]]; then exit 0; fi
        if [[ "$svc" == "postgresql" && -f "$HS/postgres_active" ]]; then exit 0; fi
        exit 3 ;;
    status) echo "mock: ${2:-} active-ish"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
echo "mocks curl/apt/systemctl written"

cat > "$MK/mock-ip" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq state UP group default qlen 1000\n'
printf '    inet %s/24 scope global eth0\n       valid_lft forever preferred_lft forever\n' "$IP"
exit 0
EOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_hostname_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "signudoc"; exit 0
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
# getent-Mock: 3 Modi
#  - group/passwd-lookups → immer ok (User/Gruppe existieren im Mock)
#  - host-lookups (deb.debian.org): ok | fail | flaky (jeder 4. failt) |
#    fail_then_ok (9x fail, dann ok)
set -u
HS="${HARNESS_STATE:?}"
db="${1:-}"
case "$db" in
    group|passwd|shadow) exit 0 ;;
esac
echo "getent $*" >> "$HS/calls.log"
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    flaky)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        if [[ $((n % 4)) -eq 0 ]]; then exit 2; fi
        exit 0 ;;
    flaky_3ok)
        # 3x ok (Initial-Check), danach dauerhaft fail → Fallback + Post-Check ok
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        [[ "$n" -le 3 ]] && exit 0
        exit 2 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        [[ "$n" -le 9 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-git" <<'EOF'
#!/usr/bin/env bash
# git-Mock: clone/fetch/checkout/clean/describe → ok; clone legt APP_DIR-Struktur an
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
echo "git $*" >> "$HS/calls.log"
sub="${1:-}"
case "$sub" in
    clone)
        # git clone --depth 1 --branch TAG URL DIR
        for a in "$@"; do
            case "$a" in -*) ;; */SignuDoc.git|https://*) ;; *) destdir="$a" ;; esac
        done
        [[ -n "${destdir:-}" ]] || { echo "mock-git: kein Ziel" >&2; exit 1; }
        mkdir -p "$destdir/.git" "$destdir/db" "$destdir/src"
        echo "ref: refs/heads/main" > "$destdir/.git/HEAD"
        echo "0123456789abcdef0123456789abcdef01234567" > "$destdir/.git/HEAD.sha"
        touch "$destdir/package.json" "$destdir/package-lock.json" "$destdir/next.config.ts"
        echo "INNEREOF" > "$destdir/.git/shallow"
        ;;
    fetch|checkout|clean) ;;
    describe)
        echo "v0.9.0"; ;;
    -C)
        # git -C DIR describe → Version aus describe-Subcase
        echo "v0.9.0"; ;;
    *) ;;
esac
exit 0
EOF

cat > "$MK/mock-node" <<'EOF'
#!/usr/bin/env bash
# node-Mock: Version aus $HS/node_v (Default v24.11.0; "20" simuliert Debians
# nodejs 20.19.2 ohne npm – der Live-Fall auf Debian 13 / CT 207).
set -u
HS="${HARNESS_STATE:?}"
echo "node $*" >> "$HS/calls.log"
ver="24.11.0"
[[ -f "$HS/node_v" ]] && ver=$(cat "$HS/node_v")
if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then echo "v$ver"; exit 0; fi
exit 0
EOF

cat > "$MK/mock-npm" <<'EOF'
#!/usr/bin/env bash
# npm-Mock: ci/build/db:migrate/start → ok (build-Call wird geloggt)
set -u
HS="${HARNESS_STATE:?}"
echo "npm $*" >> "$HS/calls.log"
sub="${1:-}"
case "$sub" in
    -v|--version) echo "11.3.0"; exit 0 ;;
    ci)
        # npm ci legt node_modules im CWD an (wie echt; $2 ist ein Flag wie --omit=dev!)
        mkdir -p "./node_modules"
        ;;
    run)
        script="${2:-}"
        if [[ "$script" == "build" ]]; then
            [[ -f "$HS/npm_build_fail" ]] && { echo "mock: build fehlgeschlagen" >&2; exit 1; }
            touch "$HS/build_done"
        elif [[ "$script" == "db:migrate" ]]; then
            [[ -f "$HS/npm_migrate_fail" ]] && { echo "mock: migration fehlgeschlagen" >&2; exit 1; }
            touch "$HS/migrate_done"
        elif [[ "$script" == "start" ]]; then
            : # next start läuft als Main-Prozess der Unit – systemd-Mock trackt
        fi
        ;;
    *) ;;
esac
exit 0
EOF

cat > "$MK/mock-lsb_release" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-cs" ]]; then echo "trixie"; exit 0; fi
echo "Debian GNU/Linux 13 (trixie)"; exit 0
EOF

cat > "$MK/mock-su" <<'EOF'
#!/usr/bin/env bash
# su-Mock: `su - postgres -c "psql ..."` → psql-Mock (DB anlegen idempotent)
set -u
HS="${HARNESS_STATE:?}"
echo "su $*" >> "$HS/calls.log"
cmd=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-c" ]]; then cmd="$a"; fi
    prev="$a"
done
if [[ "$cmd" == psql* ]]; then
    exec "$MKROOT/bin-inner/psql" "${@: -0}" 2>/dev/null || \
    exec env PATH="$MKROOT/bin-inner" sh -c "psql ${cmd#psql }"
fi
exit 0
EOF

cat > "$MK/mock-psql" <<'EOF'
#!/usr/bin/env bash
# psql-Mock: SELECT → 1; CREATE/ALTER → ok
set -u
HS="${HARNESS_STATE:?}"
echo "psql $*" >> "$HS/calls.log"
args="$*"
case "$args" in
    *"SELECT 1 FROM pg_roles"*|*"SELECT 1 FROM pg_database"*) echo "  1"; exit 0 ;;
esac
if [[ -f "$HS/psql_fail" ]]; then echo "mock: psql fehler" >&2; exit 1; fi
exit 0
EOF

cat > "$MK/mock-runuser" <<'EOF'
#!/usr/bin/env bash
# runuser-Mock: parst `runuser -u USER -- CMD ARGS...` korrekt (sonst würde der
# Mock versuchen, den BENUTZERNAMEN als Kommando auszuführen – der Live-Grube-
# Fund beim npm-ci-Kind: "exec: signudoc: not found").
set -u
HS="${HARNESS_STATE:?}"
echo "runuser $*" >> "$HS/calls.log"
shift # -u
[[ "${1:-}" == "-u" ]] && shift # USER (falls -u nicht geflaggt war)
shift || true                      # USER-Name
[[ "${1:-}" == "--" ]] && shift
exec "$@"
EOF

cat > "$MK/mock-useradd" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "useradd $*" >> "$HS/calls.log"
name=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "--comment" ]]; then :; fi
    prev="$a"
done
for a in "$@"; do
    case "$a" in --*) ;; *) name="$a" ;; esac
done
echo "$name" >> "$HS/users"
exit 0
EOF

cat > "$MK/mock-groupadd" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "groupadd $*" >> "$HS/calls.log"
exit 0
EOF

cat > "$MK/mock-getent-passwd" <<'EOF'
#!/usr/bin/env bash
# getent-Mock-Erweiterung: `getent group X` / `getent passwd X` → ok wenn in Users
set -u
HS="${HARNESS_STATE:?}"
db="${1:-}"; name="${2:-}"
echo "getent $*" >> "$HS/calls.log"
[[ -f "$HS/users" ]] && grep -qx "$name" "$HS/users" 2>/dev/null && exit 0
exit 2
EOF

cat > "$MK/mock-install" <<'EOF'
#!/usr/bin/env bash
# install-Mock: -d DIR → mkdir; -m MODE -o OWNER -g GROUP file → touch.
# Grube: Flags MIT WERTPARAMETERN (-m 0755, -o user, -g group) korrekt parsen –
# sonst werden die WERTE als Pfade fehlinterpretiert ("mkdir: cannot create
# directory 'signudoc': Permission denied").
set -u
HS="${HARNESS_STATE:?}"
echo "install $*" >> "$HS/calls.log"
mode_d=false
MODE_VAL=""
want_mode=false
args=()
prev=""
skip_next=false
for a in "$@"; do
    if [[ "$skip_next" == "true" ]]; then
        skip_next=false
        if [[ "${want_mode:-false}" == "true" ]]; then MODE_VAL="$a"; want_mode=false; fi
        prev=""; continue
    fi
    case "$a" in
        -d) mode_d=true; want_mode=false; prev="";;
        -m) skip_next=true; want_mode=true; prev="";;
        -o|-g) skip_next=true; want_mode=false; prev="";;
        -*) want_mode=false; prev="";;
        *) if [[ "${want_mode:-false}" == "true" ]]; then MODE_VAL="$a"; want_mode=false; prev=""; else args+=("$a"); prev="$a"; fi;;
    esac
done
for a in "${args[@]}"; do
    mode_arg=""
    [[ -n "${MODE_VAL:-}" ]] && mode_arg="$MODE_VAL"
    if [[ "$mode_d" == "true" ]]; then
        mkdir -p "$a"
        [[ -n "$mode_arg" ]] && chmod "$mode_arg" "$a"
    else
        mkdir -p "$(dirname "$a")"
        touch "$a"
        [[ -n "$mode_arg" ]] && chmod "$mode_arg" "$a"
    fi
done
exit 0
EOF

cat > "$MK/mock-dpkg" <<'EOF'
#!/usr/bin/env bash
# dpkg-Mock: `dpkg -s postgresql-17` → ok wenn postgres installiert (postgres_active)
set -u
HS="${HARNESS_STATE:?}"
echo "dpkg $*" >> "$HS/calls.log"
[[ "${1:-}" == "-s" && "${2:-}" == postgresql-17 ]] || exit 1
[[ -f "$HS/postgres_active" ]] && exit 0
exit 1
EOF

cat > "$MK/mock-gpg" <<'EOF'
#!/usr/bin/env bash
# gpg-Mock: --dearmor muss stdin→stdout reichen (sonst leerer Keyring und der
# Installer überspringt NodeSource still → Fallback wird fälschlich ausgelöst).
if [[ "${1:-}" == "--dearmor" ]]; then cat; exit 0; fi
cat >/dev/null 2>&1
exit 0
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null
echo "mocks rest written"

# ── Runner ─────────────────────────────────────────────────────────────────
reset_state() {
    rm -rf "$HS"; mkdir -p "$HS" "$HS/templates"
    # Mock-Root KOMPLETT wipen (Grube: Reste aus VORHERIGEN Cases – .git, node_modules,
    # .env, psql-Marker – fälschten sonst die Assertions: "PostgreSQL bereits installiert"
    # auf einem angeblich frischen CT).
    [[ -n "${MK:-}" && "$MK" != "/" ]] || { echo "MK leer/unplausibel – Abbruch" >&2; exit 1; }
    rm -rf "${MK:?}/etc" "${MK:?}/opt" "${MK:?}/root" "${MK:?}/var" "${MK:?}/tmp"
    mkdir -p "$MK/etc/systemd/system" "$MK/etc/dhcp" \
        "$MK/etc/apt/sources.list.d" "$MK/etc/apt/keyrings" \
        "$MK/usr/local/bin" \
        "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp" "$MK/var/lib"
    echo "$CT_IP" > "$HS/ct_ip"
    : > "$HS/ct_list"
    : > "$HS/calls.log"
    echo "getent_mode=ok" > "$HS/getent_mode"
    echo "x86_64" > "$HS/host_arch"
    echo "24.11.0" > "$HS/node_v"        # node-Mock: Node 24 (Default)
    unseed_inner_tools   # Inner-Fakebin wieder auf "nacktes Debian" zurücksetzen
}
run_installer() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_stdin() {
    local input="$1"; shift
    ( printf '%s\n' "$input" | unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_devnull() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" < /dev/null > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_bash_c() { # ECHTES bash -c-Muster: Option wird als $0 geliefert
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash -c "$(cat "$SCRIPT")" "--status" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
seed_ct() { # laufender CT mit installiertem SignuDoc
    # v1.0.0-Rest: NodeSource-Repo mit Codename statt nodistro
    reset_state
    echo "200 running signudoc" > "$HS/ct_list"
    echo "running" > "$HS/ct_200.status"
    echo "signudoc" > "$HS/ct_200.hostname"
    mkdir -p "$MK/opt/signudoc" "$MK/etc/systemd/system" "$MK/etc" "$MK/var/log" \
        "$MK/var/lib/signudoc" "$MK/var/lib/signudoc/outbox" "$MK/var/lib/signudoc/storage"
    seed_inner_tools
    touch "$HS/signudoc_active" "$HS/postgres_active" "$HS/template_downloaded" "$HS/build_done"
    touch "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
    touch "$MK/etc/systemd/system/signudoc.service" "$MK/opt/signudoc/.git/HEAD" 2>/dev/null || \
        { mkdir -p "$MK/opt/signudoc/.git"; touch "$MK/etc/systemd/system/signudoc.service" "$MK/opt/signudoc/.git/HEAD"; }
    cat > "$MK/opt/signudoc/.env" <<ENVSEED
DATABASE_URL=postgres://signudoc:fixedpassword@127.0.0.1:5432/signudoc
BETTER_AUTH_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
STORAGE_DRIVER=local
STORAGE_LOCAL_DIR=/var/lib/signudoc/storage
EMAIL_DRIVER=capture
EMAIL_CAPTURE_DIR=/var/lib/signudoc/outbox
NODE_ENV=production
PORT=8080
HOSTNAME=0.0.0.0
ENVSEED
    chmod 0640 "$MK/opt/signudoc/.env"
}

ENV_PATH="$MK/opt/signudoc/.env"
UNIT_PATH="$MK/etc/systemd/system/signudoc.service"

echo "════════════════════════════════════════════════════════════"
echo " 🧪 SignuDoc-Proxmox Harness – $(date +%H:%M:%S)"
echo "════════════════════════════════════════════════════════════"

# ════════════════ A. Argumente & Grundlagen ════════════════
t "--help"
ec=$(run_installer --help); assert_exit 0 "$ec"
assert_out "SignuDoc – Proxmox-Installer"
assert_out "--update"

t "unbekannte Option"
ec=$(run_installer --schnulli); assert_exit 1 "$ec"
assert_out "Unbekannte Option: --schnulli"

t "--port ungültig"
ec=$(run_installer --port abc); assert_exit 1 "$ec"
assert_out "Ungültiger Port: 'abc'"

t "--version ungültig (Sonderzeichen)"
ec=$(run_installer --version "v0.9.0 rm -rf"); assert_exit 1 "$ec"
assert_out "Ungültige Versions-Pin-Angabe"

t "--setup-token zu kurz"
ec=$(run_installer --setup-token "kurz"); assert_exit 1 "$ec"
assert_out "zu kurz"

t "\$0-Fallback (bash -c-Muster: Option als \$0)"
ec=$(run_installer_bash_c); assert_exit 0 "$ec"
assert_out "Status SignuDoc"

t "nächste freie CT-ID (200-202 belegt)"
reset_state
printf '200 running foo\n201 running bar\n202 running baz\n' > "$HS/ct_list"
seed_inner_tools
touch "$HS/template_downloaded"
touch "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Nächste freie CT-ID: 203"
assert_fcontains "$HS/ct_203.create" "hostname signudoc"

t "pct list ohne Lock-Spalte (Name \$NF)"
reset_state
printf '200 running signudoc' > "$HS/ct_list"
echo "running" > "$HS/ct_200.status"
seed_inner_tools
touch "$HS/signudoc_active" "$HS/postgres_active" "$HS/template_downloaded" "$HS/build_done"
mkdir -p "$MK/opt/signudoc" "$MK/etc/systemd/system"
touch "$MK/etc/systemd/system/signudoc.service"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – signudoc"

# ════════════════ B. Install End-to-End ════════════════
t "Install End-to-End (nacktes Debian: curl bootstrappen, Node+PG nachziehen)"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Container-IP: $CT_IP"
assert_out "DNS im Container funktioniert (3x bestätigt)"
assert_out "debian-13-standard_13.6-1_amd64"
assert_fcontains "$HS/ct_200.create" "unprivileged"
assert_fcontains "$HS/ct_200.create" "nesting=1,keyctl=1"
assert_fcontains "$HS/ct_200.create" "onboot 1"
assert_fcontains "$HS/ct_200.create" "memory 2048"
assert_fcontains "$HS/ct_200.create" "swap 2048"
assert_fregex "$HS/ct_200.create" "rootfs local-lvm:8"
assert_fcontains "$HS/ct_200.create" "firewall=0"
assert_calls 1 "apt-get install"
assert_calls 1 "media/keys"
assert_calls 1 "nodesource"
assert_calls 1 "npm ci"
assert_calls 1 "npm run build"
assert_calls 1 "npm run db:migrate"
assert_out "✍️  SignuDoc ist bereit!"
assert_out "http://$CT_IP:8080"
assert_out "Service signudoc läuft (systemctl is-active)"
assert_out "Service postgresql läuft (systemctl is-active)"
assert_out "Web-UI antwortet (HTTP 200 auf Port 8080)"
assert_out "Vom Host erreichbar: http://$CT_IP:8080 (HTTP 200)"
assert_out "Status:     bash -c"
assert_out "Update:     bash -c"
assert_out "Deinstall:  bash -c"

t "systemd-Unit: Restart=always + Prod-Pfade"
assert_file "$UNIT_PATH"
assert_fcontains "$UNIT_PATH" "Restart=always"
assert_fcontains "$UNIT_PATH" "RestartSec=10"
assert_fcontains "$UNIT_PATH" "run start"
assert_fcontains "$UNIT_PATH" "npm"
assert_fcontains "$UNIT_PATH" "After=network-online.target postgresql.service"
assert_fcontains "$UNIT_PATH" "Requires=postgresql.service"
assert_fcontains "$UNIT_PATH" "EnvironmentFile="
assert_fcontains "$UNIT_PATH" "/opt/signudoc/.env"
assert_fcontains "$UNIT_PATH" "User=signudoc"
assert_fcontains "$UNIT_PATH" "WantedBy=multi-user.target"

t ".env vollständig & Secrets-Format"
# .env enthält STORAGE_LOCAL_DIR etc. – im Mock mit $MK-Prefix (pct-Env-Rewrite).
# Für die Assertions eine normalisierte Kopie ohne Mock-Prefix erzeugen.
ENV_PATH_NORM="$CUR_DIR/env-normalized"
sed "s|$MK||g" "$ENV_PATH" > "$ENV_PATH_NORM" 2>/dev/null || true
chmod 0640 "$ENV_PATH_NORM" 2>/dev/null || true   # Kopie erbt sed-umask (002) - Mode angleichen
assert_file "$ENV_PATH_NORM"
assert_fregex "$ENV_PATH_NORM" '^BETTER_AUTH_SECRET=[0-9a-f]{64}$'
assert_fregex "$ENV_PATH_NORM" '^APP_URL=http://127\.0\.0\.1:8080$'   # v1.0.4: ohne APP_URL schlägt /api/setup mit HTTP 500 fehl
assert_fregex "$ENV_PATH_NORM" '^DATABASE_URL=postgres://signudoc:[0-9a-f]{48}@127\.0\.0\.1:5432/signudoc$'
assert_fcontains "$ENV_PATH_NORM" "STORAGE_DRIVER=local"
assert_fcontains "$ENV_PATH_NORM" "STORAGE_LOCAL_DIR=/var/lib/signudoc/storage"
assert_fcontains "$ENV_PATH_NORM" "EMAIL_DRIVER=capture"
assert_fcontains "$ENV_PATH_NORM" "EMAIL_CAPTURE_DIR=/var/lib/signudoc/outbox"
assert_fcontains "$ENV_PATH_NORM" "NODE_ENV=production"
assert_fcontains "$ENV_PATH_NORM" "PORT=8080"
assert_fcontains "$ENV_PATH_NORM" "HOSTNAME=0.0.0.0"
env_mode=$(/bin/stat -c '%a' "$ENV_PATH_NORM" 2>/dev/null || echo "?")
if [[ "$env_mode" == "640" ]]; then pass ".env chmod 640"
else fail ".env chmod 640 (ist $env_mode)"; fi
assert_file "$MK/opt/signudoc/.gitignore"
assert_fcontains "$MK/opt/signudoc/.gitignore" ".env"

t "Outbox-/Storage-Verzeichnisse: Rechte (eigener Install-Lauf)"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
# Verzeichnis, nicht Datei: -d statt -f prüfen (assert_file nutzt -f!)
if [[ -d "$MK/var/lib/signudoc/outbox" ]]; then pass "Verzeichnis: $MK/var/lib/signudoc/outbox"
else fail "Verzeichnis fehlt: $MK/var/lib/signudoc/outbox"; fi
if [[ -d "$MK/var/lib/signudoc/storage" ]]; then pass "Verzeichnis: $MK/var/lib/signudoc/storage"
else fail "Verzeichnis fehlt: $MK/var/lib/signudoc/storage"; fi
outbox_mode=$(/bin/stat -c '%a' "$MK/var/lib/signudoc/outbox" 2>/dev/null || echo "?")
if [[ "$outbox_mode" == "700" ]]; then pass "outbox chmod 700"
else fail "outbox chmod 700 (ist $outbox_mode)"; fi

t "Build-Blocker: npm ci OHNE --omit=dev (next build braucht devDependencies)"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
if /bin/grep -q "npm ci --omit=dev" "$HS/calls.log" 2>/dev/null; then
    fail "npm ci läuft mit --omit=dev (next build braucht typescript/tailwind!)"
else
    pass "npm ci ohne --omit=dev (devDependencies für next build vorhanden)"
fi
assert_calls 1 "npm ci"
assert_out "SignuDoc ist bereit!"

t "Install mit --port 4545"
reset_state
ec=$(run_installer --port 4545); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "PORT=4545"
assert_out "http://$CT_IP:4545"

t "Install mit --setup-token (mind. 8 Zeichen)"
reset_state
ec=$(run_installer --setup-token "geheimes-token"); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "SETUP_TOKEN=geheimes-token"
assert_out "SETUP_TOKEN gesetzt (per --setup-token)"
assert_out "Setup-Token: geheimes-token"

t "Install mit --version v0.8.5 (Pin überschreiben)"
reset_state
ec=$(run_installer --version v0.8.5); assert_exit 0 "$ec"
assert_calls 1 "clone --depth 1 --branch v0.8.5"
assert_out "SignuDoc v0.8.5"

t "Install mit statischer IP (--ip)"
reset_state
echo "192.168.178.77" > "$HS/ct_ip"
ec=$(run_installer --ip 192.168.178.77/24 --gateway 192.168.178.1); assert_exit 0 "$ec"
assert_fcontains "$HS/ct_200.create" "ip=192.168.178.77/24,gateway=192.168.178.1"
assert_out "http://192.168.178.77:8080"

t "Install: Web-UI antwortet mit 307 (Redirect aufs /setup) – auch ok"
reset_state
touch "$HS/web_307"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Web-UI antwortet (HTTP 307 auf Port 8080)"

t "Install: Web-UI antwortet mit 302 – auch ok"
reset_state
touch "$HS/web_302"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Web-UI antwortet (HTTP 302 auf Port 8080)"

t "Install: npm build schlägt fehl → die() mit Fehlerkette"
reset_state
touch "$HS/npm_build_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "npm run build fehlgeschlagen"

t "Install: CT existiert bereits → die() mit Update-Hinweis"
reset_state
echo "200 running signudoc" > "$HS/ct_list"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "existiert bereits"
assert_out "--update"

t "Install --force: bestehender CT wird gelöscht und neu angelegt"
reset_state
echo "200 running signudoc" > "$HS/ct_list"
echo "running" > "$HS/ct_200.status"
echo "signudoc" > "$HS/ct_200.hostname"
seed_inner_tools
touch "$HS/template_downloaded"
touch "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
ec=$(run_installer --force); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_out "neu an"
assert_fcontains "$HS/ct_200.create" "hostname signudoc"

t "Arch-Filter: amd64-Host ignoriert NEUERES arm64-Template (Live-Grube 2026-11-22)"
reset_state
seed_inner_tools
touch "$HS/template_downloaded"
touch "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Host-Architektur: x86_64 → Template-Suffix 'amd64'"
assert_out "Template: debian-13-standard_13.6-1_amd64.tar.zst"
assert_out "Container 200 läuft (Status: running)"
assert_fcontains "$HS/ct_200.create" "debian-13-standard_13.6-1_amd64.tar.zst"

t "Arch-Filter: Download-Pfad ignoriert Fremd-Arch (kein Template im Cache)"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "lade es herunter"
assert_fcontains "$HS/ct_200.create" "debian-13-standard_13.6-1_amd64.tar.zst"

t "Arch-Filter: arm64-Host bekommt arm64-Template"
reset_state
echo "aarch64" > "$HS/host_arch"
seed_inner_tools
touch "$HS/template_downloaded"
touch "$HS/templates/debian-13-standard_13.9-1_arm64.tar.zst"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Template-Suffix 'arm64'"
assert_out "Template: debian-13-standard_13.9-1_arm64.tar.zst"
assert_fcontains "$HS/ct_200.create" "debian-13-standard_13.9-1_arm64.tar.zst"

t "Live-Grube NodeSource-trixie: apt liefert Node 20 ohne npm → nodejs.org-Fallback (CT 207)"
reset_state
touch "$HS/apt_nodejs_fail"        # NodeSource-Repo nicht installierbar
echo "20.19.2" > "$HS/node_v"       # Debian-Repo: nodejs 20.19.2 (ohne npm)
touch "$HS/node_v_debian"           # apt-Mock: node da, npm fehlt
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Node.js 24.x installieren (NodeSource, Fallback nodejs.org)"
assert_out "Fallback: node-v24.11.0-linux-x64.tar.xz"
assert_calls 1 "nodejs.org/dist"
assert_out "Web-UI antwortet (HTTP 200 auf Port 8080)"
assert_out "SignuDoc ist bereit!"

t "Live-Grube: NodeSource-Repo sauber (nodistro) → kein Fallback nötig"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
assert_no_out "Fallback: node-v24"
assert_calls 1 "deb.nodesource.com"
assert_out "npm 11.3.0"

t "NodeSource-Installation: sources.list braucht nodistro (nicht Codename)"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
# Der Key-Datei-Inhalt ist ein Datei-Write, kein Tool-Call → direkt prüfen
assert_fcontains "$MK/etc/apt/sources.list.d/nodesource.list" "nodistro main"
assert_no_fcontains "$MK/etc/apt/sources.list.d/nodesource.list" "trixie"

t "Node endgültig unmöglich → die() mit Diagnose (node/npm/apt-cache)"
reset_state
touch "$HS/apt_nodejs_fail"
echo "20.19.2" > "$HS/node_v"
touch "$HS/node_v_debian"
# Fallback soll fehlschlagen: nodejs.org nicht erreichbar machen
touch "$HS/no_nodejs_org"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Node.js 24.x + npm konnten NICHT installiert werden"
assert_out "apt-get install -y nodejs npm"

t "Live-Grube v1.0.0-Rest: stale NodeSource-Repo (trixie) killt apt → Installer repariert + läuft"
reset_state
# CT-Stand wie nach dem fehlgeschlagenen v1.0.0-Lauf: Repo mit Codename,
# Node 20 von Debian (ohne npm), Code + .env + DB schon vorhanden.
mkdir -p "$MK/etc/apt/sources.list.d"
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x trixie main" \
    > "$MK/etc/apt/sources.list.d/nodesource.list"
touch "$HS/stale_nodesource"        # apt-get update → Exit 100
seed_inner_tools
echo "200 running signudoc" > "$HS/ct_list"
echo "running" > "$HS/ct_200.status"
echo "signudoc" > "$HS/ct_200.hostname"
mkdir -p "$MK/opt/signudoc" "$MK/etc/systemd/system" "$MK/var/log" "$MK/var/lib/signudoc/outbox"
touch "$HS/template_downloaded" "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
touch "$MK/etc/systemd/system/signudoc.service"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "Stale NodeSource-Repo erkannt"
assert_fcontains "$MK/etc/apt/sources.list.d/nodesource.list" "nodistro"
assert_no_fcontains "$MK/etc/apt/sources.list.d/nodesource.list" "trixie"
assert_out "Update abgeschlossen"

t "Toleranter apt-Update: kaputtes Fremd-Repo beendet die Installation NICHT"
reset_state
touch "$HS/stale_nodesource"
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x trixie main" \
    > "$MK/etc/apt/sources.list.d/nodesource.list"
seed_inner_tools
touch "$HS/template_downloaded" "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "apt-get update meldet weiterhin Fehler"   # nur wenn 2. Versuch scheitert
assert_out "SignuDoc ist bereit!"

t "Stale-Repo ohne NodeSource-Bezug: Installer lässt fremde Listen in Ruhe"
reset_state
mkdir -p "$MK/etc/apt/sources.list.d"
echo "deb http://deb.debian.org/debian trixie main" > "$MK/etc/apt/sources.list.d/custom.list"
seed_inner_tools
touch "$HS/template_downloaded" "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
ec=$(run_installer); assert_exit 0 "$ec"
assert_fcontains "$MK/etc/apt/sources.list.d/custom.list" "deb.debian.org"

t "verify_ct_started: pct create Exit-0-Täuschung (spawn fail) → die() mit Fehlerkette"
reset_state
seed_inner_tools
touch "$HS/template_downloaded"
touch "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
touch "$HS/create_spawn_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Container 200 läuft NICHT (Status: stopped)"
assert_out "Failed to spawn container"
assert_out "Start-Versuch mit vollständiger Fehlerausgabe"
assert_out "pct start sagte:"
assert_out "pct start 200 && pct status 200"

t "Install: pct create schlägt fehl → komplette Fehlerkette + --debug-Hinweis"
reset_state
touch "$HS/create_fail"
ec=$(run_installer); assert_exit 255 "$ec"
assert_out "Installationsfehler – Exit-Code 255"
assert_out "Fehlgeschlagener Befehl"
assert_out "--debug"
assert_out "Neu ausführen mit vollem bash -x-Trace"

t "Install: DNS tot ohne Fallback-Erfolg → die() mit Diagnose"
reset_state
echo "getent_mode=fail" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "DNS im Container weiterhin ohne Funktion"
assert_out "Port 53"

t "Install: flaky DNS (jeder 4. Call failt) → 3x-Fenster hält, kein Fallback nötig"
reset_state
echo "getent_mode=flaky" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "DNS im Container funktioniert (3x bestätigt)"

t "SSH-Key per --sshkey (Datei)"
reset_state
touch "$HS/template_downloaded"
touch "$HS/templates/debian-13-standard_13.6-1_amd64.tar.zst"
seed_inner_tools
echo "ssh-ed25519 AAAAC3Nza test@example" > "$MK/sshkey.pub"
ec=$(run_installer --sshkey "$MK/sshkey.pub"); assert_exit 0 "$ec"
assert_calls 1 "pct create 200"
assert_fcontains "$HS/ct_200.create" "ssh-public-keys"
assert_out "SSH-Public-Key wird in den Container installiert"

# ════════════════ D. Update ════════════════
t "--update: Secrets bleiben erhalten, Tag wird neu ausgerollt"
seed_ct
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_calls 1 "git -C"
assert_calls 1 "npm ci"
assert_calls 1 "npm run build"
assert_fcontains "$ENV_PATH" "BETTER_AUTH_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
assert_fcontains "$ENV_PATH" "DATABASE_URL=postgres://signudoc:fixedpassword@127.0.0.1:5432/signudoc"
assert_out "Update abgeschlossen – .env, Datenbank und PDFs blieben erhalten."

t "--update --setup-token setzt Token nachträglich"
seed_ct
ec=$(run_installer --update --setup-token "neues-geheimnis"); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "SETUP_TOKEN=neues-geheimnis"
assert_fcontains "$ENV_PATH" "BETTER_AUTH_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

t "--update ohne --setup-token lässt bestehenden Token in Ruhe"
seed_ct
/bin/grep -q '^SETUP_TOKEN=' "$ENV_PATH" 2>/dev/null || echo "SETUP_TOKEN=bestehend" >> "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "SETUP_TOKEN=bestehend"
assert_no_out "SETUP_TOKEN gesetzt (per --setup-token)"

t "--update auf gestopptem CT → startet ihn selbst (Grube 10)"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i 's/^200 running/200 stopped/' "$HS/ct_list"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_calls 1 "pct start 200"
assert_out "läuft nicht (Status: stopped) – starte ihn"

t "--update: Domain-Modus (APP_URL=https:// in .env) bleibt unangetastet"
seed_ct
echo "APP_URL=https://signo.example.com" >> "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "APP_URL=https://signo.example.com"

t "--update ergänzt fehlendes APP_URL (Loopback) bei Alt-Installationen (v1.0.3)"
seed_ct   # ENVSEED ohne APP_URL = Stand vor v1.0.4
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "APP_URL=http://127.0.0.1:8080"

t "--update ohne CT → die() mit Install-Hinweis"
reset_state
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Kein Container mit Hostname 'signudoc' gefunden"
assert_out "Erst installieren"

# ════════════════ E. Uninstall ════════════════
t "--uninstall --yes: CT stoppen + löschen"
seed_ct
ec=$(run_installer --uninstall --yes); assert_exit 0 "$ec"
assert_calls 1 "pct stop 200"
assert_calls 1 "pct destroy 200 --purge"
assert_no_out "200 running signudoc"
if /bin/grep -q "200" "$HS/ct_list" 2>/dev/null; then fail "CT noch in ct_list"
else pass "CT aus ct_list entfernt"; fi

t "--uninstall ohne CT → nichts zu tun (exit 0)"
reset_state
ec=$(run_installer --uninstall --yes); assert_exit 0 "$ec"
assert_out "nichts zu tun"

t "--uninstall ohne --yes, stdin 'nein' → Abbruch, CT bleibt"
seed_ct
ec=$(run_installer_stdin "nein" --uninstall); assert_exit 0 "$ec"
assert_out "Abgebrochen – nichts gelöscht"
assert_calls 0 "pct destroy 200"

t "--uninstall ohne --yes, kein stdin → die() mit --yes-Hinweis"
seed_ct
ec=$(run_installer_devnull --uninstall); assert_exit 1 "$ec"
assert_out "Keine Bestätigung erhalten"
assert_out "--uninstall --yes"

# ════════════════ F. Status ════════════════
t "--status (laufend): Service, DB, Setup-Schutz-Warnung, Web-UI 200"
seed_ct
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – signudoc"
assert_out "Service:   signudoc läuft (systemctl is-active)"
assert_out "DB:        postgresql läuft (systemctl is-active)"
assert_out "Upstream:  v0.9.0"
assert_out "E-Mail:    Treiber 'capture'"
assert_out "/setup:    OHNE Token erreichbar"
assert_out "Web-UI:    http://10.120.5.42:8080  (HTTP 200)"

t "--status: Setup-Token gesetzt → ok statt Warnung"
seed_ct
echo "SETUP_TOKEN=geheim123" >> "$ENV_PATH"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "/setup:    durch --setup-token geschützt"

t "--status: Host_curl_fail → Warnung mit HTTP 000"
seed_ct
touch "$HS/host_curl_fail"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "HTTP-Code 000 von http://10.120.5.42:8080"

t "--status: gestoppter CT → Start-Hinweis, keine falschen Fehler"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i 's/^200 running/200 stopped/' "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "nicht gestartet (stopped)"
assert_out "Starten:    pct start 200"

t "--status: signudoc-Service tot → Fehler + journalctl-Hinweis"
seed_ct
rm -f "$HS/signudoc_active"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "signudoc läuft NICHT"
assert_out "journalctl -u signudoc -n 50"

t "--status ohne CT → Hinweis + Install-Befehl (exit 0)"
reset_state
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Kein Container mit Hostname 'signudoc' gefunden"

t "--id 999 --status: unbekannte ID → Hinweis (kein Absturz)"
reset_state
ec=$(run_installer --id 999 --status); assert_exit 0 "$ec"
assert_out "Kein Container mit Hostname 'signudoc' gefunden"

# ════════════════ Zusammenfassung ════════════════
echo "════════════════════════════════════════════════════════════"
echo " Ergebnis: $PASSED bestanden, $FAILED fehlgeschlagen"
echo "════════════════════════════════════════════════════════════"
if [[ "$FAILED" -gt 0 ]]; then
    KEEP=1
    echo "(Behalten für Fehlersuche: $MK)"
    exit 1
fi
exit 0
