#!/usr/bin/env bash
# Mystic Paradox NAS control script
# Run from the repository root as: ./dauntless.sh <command>
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
BACKEND_DIR="$REPO_DIR/ParadoxBackend"
DIRECTOR_DIR="$REPO_DIR/ParadoxDirector"
BACKEND_ENV="$BACKEND_DIR/.env"
DIRECTOR_ENV="$DIRECTOR_DIR/.env"
GAME_DIR="${HOME}/Projects/Dauntless/Archon/Binaries/Win64"
GAME_EXE="$GAME_DIR/Dauntless-Win64-Shipping.exe"
GAME_WRAPPER="$REPO_DIR/bin/dauntless-wine"
BACKEND_UNIT="mystic-paradox-backend.service"
DIRECTOR_UNIT="mystic-paradox-director.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
NODE_BIN="$(command -v node || true)"
NPM_BIN="$(command -v npm || true)"

say()  { printf '\033[1;36m[dauntless]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dauntless] ATTENTION:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[dauntless] ERREUR:\033[0m %s\n' "$*" >&2; }

need_command() {
    command -v "$1" >/dev/null 2>&1 || { err "Commande introuvable: $1"; return 1; }
}

need_repo() {
    [[ -d "$BACKEND_DIR" && -d "$DIRECTOR_DIR" ]] || {
        err "Lance ce script depuis le dépôt Mystic-Paradox (il doit être à sa racine)."
        return 1
    }
}

need_user_systemd() {
    need_command systemctl || return 1
    systemctl --user show-environment >/dev/null 2>&1 || {
        err "systemd utilisateur indisponible. Ouvre une session SSH normale sur le NAS puis réessaie."
        return 1
    }
}

unit_file_backend() {
    cat <<UNIT
[Unit]
Description=Mystic Paradox Backend
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$BACKEND_DIR
Environment=HOME=$HOME
Environment=PATH=$(dirname "$NODE_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStartPre=$NODE_BIN scripts/ensure-build-fresh.cjs
ExecStart=$NODE_BIN --env-file=.env build/server.js
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=45
LimitNOFILE=65536
SyslogIdentifier=mystic-paradox-backend

[Install]
WantedBy=default.target
UNIT
}

unit_file_director() {
    cat <<UNIT
[Unit]
Description=Mystic Paradox Director and Dauntless persistent hubs
Wants=network-online.target $BACKEND_UNIT
After=network-online.target $BACKEND_UNIT

[Service]
Type=simple
WorkingDirectory=$DIRECTOR_DIR
Environment=HOME=$HOME
Environment=PATH=$(dirname "$NODE_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStartPre=$NODE_BIN scripts/ensure-build-fresh.cjs
ExecStart=$NODE_BIN --env-file=.env dist/server.js
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=60
LimitNOFILE=65536
SyslogIdentifier=mystic-paradox-director

[Install]
WantedBy=default.target
UNIT
}

port_listening() {
    local proto="$1" port="$2"
    if [[ "$proto" == tcp ]]; then
        ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
    else
        ss -H -lun "sport = :$port" 2>/dev/null | grep -q .
    fi
}

show_port() {
    local proto="$1" port="$2"
    if port_listening "$proto" "$port"; then
        printf '  %-4s %-5s : écoute\n' "$proto" "$port"
    else
        printf '  %-4s %-5s : non ouvert\n' "$proto" "$port"
    fi
}

service_state() {
    local unit="$1"
    if systemctl --user is-active --quiet "$unit"; then
        printf '\033[1;32mACTIF\033[0m'
    elif systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then
        printf 'arrêté (activé au démarrage)'
    else
        printf 'non installé / désactivé'
    fi
}

read_env_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    sed -nE "s/^${key}=(.*)$/\\1/p" "$file" | tail -n 1 | sed -E 's/^"(.*)"$/\1/; s/^\x27(.*)\x27$/\1/'
}

cmd_install() {
    need_repo
    need_user_systemd
    [[ -n "$NODE_BIN" ]] || { err "Node.js introuvable dans le PATH. Charge ton environnement Node puis relance."; return 1; }
    [[ -f "$BACKEND_ENV" && -f "$DIRECTOR_ENV" ]] || { err "Fichier .env Backend ou Director absent."; return 1; }
    [[ -f "$BACKEND_DIR/build/server.js" ]] || { err "Backend non compilé. Lance ./dauntless.sh build."; return 1; }
    [[ -f "$DIRECTOR_DIR/dist/server.js" ]] || { err "Director non compilé. Lance ./dauntless.sh build."; return 1; }

    mkdir -p "$UNIT_DIR"
    unit_file_backend > "$UNIT_DIR/$BACKEND_UNIT"
    unit_file_director > "$UNIT_DIR/$DIRECTOR_UNIT"
    systemctl --user daemon-reload

    # Keep the user manager alive after SSH logout, but deliberately do NOT
    # enable the game services at boot. Linger alone does not start disabled units.
    if command -v loginctl >/dev/null 2>&1; then
        local linger
        linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
        if [[ "$linger" != yes ]]; then
            need_command sudo || return 1
            say "Activation de linger pour conserver les services après la déconnexion SSH."
            sudo loginctl enable-linger "$USER" || {
                err "Impossible d'activer linger. Exécute : sudo loginctl enable-linger $USER"
                return 1
            }
        else
            say "Linger déjà actif : les services pourront continuer après la déconnexion SSH."
        fi
    else
        err "loginctl indisponible : impossible de garantir la survie après déconnexion SSH."
        return 1
    fi

    # Remove any previous boot-enable links from an earlier version of this script.
    systemctl --user disable "$BACKEND_UNIT" "$DIRECTOR_UNIT" >/dev/null 2>&1 || true

    say "Services systemd utilisateur installés, mais DÉSACTIVÉS au démarrage du NAS."
    say "Linger maintient le gestionnaire utilisateur après la déconnexion SSH."
    say "Pour démarrer manuellement : ./dauntless.sh start"
    say "Pour vérifier : ./dauntless.sh status"
}

cmd_enable_boot() {
    need_user_systemd
    need_command loginctl
    need_command sudo
    say "Activation du démarrage automatique après reboot pour $USER."
    sudo loginctl enable-linger "$USER"
    systemctl --user enable "$BACKEND_UNIT" "$DIRECTOR_UNIT"
    say "Démarrage automatique activé."
}

cmd_disable_boot() {
    need_user_systemd
    systemctl --user disable "$BACKEND_UNIT" "$DIRECTOR_UNIT" >/dev/null 2>&1 || true
    say "Démarrage automatique désactivé. Les services actifs ne sont pas arrêtés."
    say "Linger reste actif pour permettre aux services démarrés manuellement de survivre à la déconnexion SSH."
}

cmd_build() {
    need_repo
    need_command npm
    say "Compilation du Backend..."
    (cd "$BACKEND_DIR" && "$NPM_BIN" run build)
    say "Compilation du Director..."
    (cd "$DIRECTOR_DIR" && "$NPM_BIN" run build)
    say "Les deux compilations sont terminées."
}

cmd_start() {
    need_repo
    need_user_systemd
    systemctl --user cat "$BACKEND_UNIT" >/dev/null 2>&1 || { err "Services non installés. Lance ./dauntless.sh install."; return 1; }

    # Never kill an unknown process: identify manually-managed instances first.
    if ! systemctl --user is-active --quiet "$BACKEND_UNIT" && port_listening tcp 3000; then
        err "Le port TCP 3000 est déjà utilisé hors du service systemd. Arrête l'ancien Backend manuel (Ctrl+C) puis réessaie."
        return 1
    fi
    if ! systemctl --user is-active --quiet "$DIRECTOR_UNIT" && port_listening tcp 3001; then
        err "Le port TCP 3001 est déjà utilisé hors du service systemd. Arrête l'ancien Director manuel (Ctrl+C) puis réessaie."
        return 1
    fi

    say "Démarrage du Backend..."
    systemctl --user start "$BACKEND_UNIT"
    local ready=0
    for _ in $(seq 1 40); do
        if systemctl --user is-active --quiet "$BACKEND_UNIT" && port_listening tcp 3000; then
            ready=1
            break
        fi
        sleep 1
    done
    if [[ "$ready" -ne 1 ]]; then
        err "Backend non prêt sur TCP 3000. Consulte ./dauntless.sh logs backend"
        return 1
    fi

    say "Démarrage du Director..."
    systemctl --user start "$DIRECTOR_UNIT"
    sleep 2
    cmd_status
    say "Le démarrage des hubs peut prendre environ 60 à 120 secondes. Suivi : ./dauntless.sh logs ramsgate"
}

cmd_stop() {
    need_user_systemd
    say "Arrêt du Director et de ses processus Wine/Xvfb..."
    systemctl --user stop "$DIRECTOR_UNIT" 2>/dev/null || true
    say "Arrêt du Backend..."
    systemctl --user stop "$BACKEND_UNIT" 2>/dev/null || true
    say "Services Mystic Paradox arrêtés. Les autres processus, notamment /home/xavier/Test, ne sont pas ciblés."
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

cmd_status() {
    need_user_systemd
    echo "========== MYSTIC PARADOX =========="
    printf 'Backend  : '; service_state "$BACKEND_UNIT"; echo
    printf 'Director : '; service_state "$DIRECTOR_UNIT"; echo
    echo
    echo "========== PORTS =========="
    show_port tcp 3000
    show_port tcp 3001
    show_port udp 8789
    show_port udp 8790
    echo
    echo "========== SESSION / DEMARRAGE =========="
    if command -v loginctl >/dev/null 2>&1; then
        printf 'Linger : '
        loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo inconnu
    fi
    printf 'Backend activé au boot : '
    if systemctl --user is-enabled --quiet "$BACKEND_UNIT" 2>/dev/null; then echo oui; else echo non; fi
    printf 'Director activé au boot : '
    if systemctl --user is-enabled --quiet "$DIRECTOR_UNIT" 2>/dev/null; then echo oui; else echo non; fi
    echo
    echo "========== HUBS =========="
    local runtime_log="$GAME_DIR/mysticparadox_dll_port8790.log"
    local dojo_log="$GAME_DIR/mysticparadox_dll_port8789.log"
    if [[ -f "$runtime_log" ]] && grep -q 'Ready marker emitted' "$runtime_log"; then
        say "Ramsgate : marqueur runtime READY présent (port 8790)."
    else
        warn "Ramsgate : marqueur runtime READY non trouvé (port 8790)."
    fi
    if [[ -f "$dojo_log" ]] && grep -q 'Ready marker emitted' "$dojo_log"; then
        say "Training Dojo : marqueur runtime READY présent (port 8789)."
    else
        warn "Training Dojo : marqueur runtime READY non trouvé (port 8789)."
    fi
    echo
    echo "========== TAILSCALE =========="
    if command -v tailscale >/dev/null 2>&1; then
        tailscale ip -4 2>/dev/null | head -n 1 || true
    else
        echo "tailscale introuvable"
    fi
}

cmd_logs() {
    need_user_systemd
    local what="${1:-director}"
    case "$what" in
        backend) journalctl --user -u "$BACKEND_UNIT" -n 100 -f ;;
        director) journalctl --user -u "$DIRECTOR_UNIT" -n 150 -f ;;
        all) journalctl --user -u "$BACKEND_UNIT" -u "$DIRECTOR_UNIT" -n 150 -f ;;
        ramsgate)
            local f="$DIRECTOR_DIR/logs/port8790_ramsgate.log"
            [[ -f "$f" ]] || { err "Log Ramsgate absent : $f"; return 1; }
            tail -n 100 -F "$f"
            ;;
        dojo|training|training_dojo)
            local f="$DIRECTOR_DIR/logs/port8789_training_dojo.log"
            [[ -f "$f" ]] || { err "Log Training Dojo absent : $f"; return 1; }
            tail -n 100 -F "$f"
            ;;
        runtime)
            local f="$GAME_DIR/mysticparadox_dll_port8790.log"
            [[ -f "$f" ]] || { err "Log runtime absent : $f"; return 1; }
            tail -n 100 -F "$f"
            ;;
        *) err "Type de logs inconnu : $what (backend|director|all|ramsgate|dojo|runtime)"; return 2 ;;
    esac
}

cmd_invite() {
    need_repo
    local ip host
    ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    host="$(sed -nE 's/.*MP_PUBLIC_HOST L"([^"]+)".*/\1/p' "$REPO_DIR/ParadoxRuntime/deployment_config.generated.h" 2>/dev/null | head -n 1)"
    echo "========== INFORMATIONS DE CONNEXION =========="
    echo "NAS Tailscale : ${ip:-IP Tailscale indisponible}"
    [[ -n "$host" ]] && echo "Backend HTTPS : https://$host" || true
    echo "Ramsgate      : ${ip:-NAS}:8790/UDP"
    echo "Training Dojo : ${ip:-NAS}:8789/UDP"
    echo
    echo "Les joueurs doivent être autorisés à rejoindre ton tailnet Tailscale."
    echo "Pour les inviter, ouvre l'administration Tailscale > Users > Invite users."
    echo "Cette commande affiche les paramètres : elle ne crée pas elle-même une invitation Tailscale."
}

cmd_doctor() {
    need_repo
    echo "========== DIAGNOSTIC MYSTIC PARADOX =========="
    for item in node npm wine xvfb-run systemctl; do
        printf '%-12s' "$item"
        command -v "$item" || true
    done
    echo
    for f in "$BACKEND_ENV" "$DIRECTOR_ENV" "$BACKEND_DIR/build/server.js" "$DIRECTOR_DIR/dist/server.js" "$GAME_EXE" "$GAME_WRAPPER" "$GAME_DIR/winmm.dll" "$GAME_DIR/MysticParadox.dll" "$GAME_DIR/MP_FORCE_WARP.flag"; do
        [[ -e "$f" ]] && printf '[OK]      %s\n' "$f" || printf '[ABSENT]  %s\n' "$f"
    done
    echo
    if [[ -f "$DIRECTOR_ENV" ]]; then
        grep -E '^(PORT|MY_IP|PORT_RANGE_BEGIN|PORT_RANGE_END|GAMESERVER_BINARY_PATH|GAMESERVER_READY_TIMEOUT_MS|RAMSGATE_HUB|TRAINING_HUB|SERVER_RUNTIME_AUTO_UPDATE|PARADOX_GAME_DATA_DIR|GAMESERVER_LOG_DIR)=' "$DIRECTOR_ENV" || true
    fi
}

cmd_uninstall() {
    need_user_systemd
    systemctl --user disable --now "$DIRECTOR_UNIT" "$BACKEND_UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$DIRECTOR_UNIT" "$UNIT_DIR/$BACKEND_UNIT"
    systemctl --user daemon-reload
    say "Units retirées. Les fichiers du dépôt et les données ne sont pas supprimés."
}

usage() {
    cat <<'HELP'
Mystic Paradox — gestion du serveur NAS

Utilisation : ./dauntless.sh <commande>

  install       Installer les services, activer linger, sans démarrage après reboot
  enable-boot   (Optionnel) Activer explicitement le démarrage automatique après reboot
  disable-boot  Désactiver le démarrage automatique sans arrêter les services actifs
  build         Compiler Backend et Director
  start         Démarrer Backend puis Director
  stop          Arrêter Director/Wine/Xvfb puis Backend
  restart       Redémarrer les deux services
  status        État des services, ports et hubs
  logs          Suivre les logs du Director
  logs backend  Suivre les logs du Backend
  logs all      Suivre les deux services
  logs ramsgate Suivre le log du monde Ramsgate
  logs dojo     Suivre le log du Training Dojo
  logs runtime  Suivre le log de MysticParadox.dll
  invite        Afficher les informations Tailscale pour les joueurs
  doctor        Vérifier les dépendances et fichiers requis
  uninstall     Désinstaller les unités systemd (ne supprime pas les données)
  help          Afficher cette aide

Le script ne tue jamais les processus d'une autre installation, par exemple /home/xavier/Test.
HELP
}

main() {
    local command="${1:-help}"
    shift || true
    case "$command" in
        install) cmd_install ;;
        enable-boot) cmd_enable_boot ;;
        disable-boot) cmd_disable_boot ;;
        build) cmd_build ;;
        start) cmd_start ;;
        stop) cmd_stop ;;
        restart) cmd_restart ;;
        status) cmd_status ;;
        logs) cmd_logs "${1:-director}" ;;
        invite) cmd_invite ;;
        doctor) cmd_doctor ;;
        uninstall) cmd_uninstall ;;
        help|-h|--help) usage ;;
        *) err "Commande inconnue : $command"; usage; return 2 ;;
    esac
}

main "$@"
