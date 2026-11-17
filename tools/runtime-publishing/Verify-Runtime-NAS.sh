#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$HOME/Projects/Mystic-Paradox}"
GAME_BIN="${GAME_BIN:-$HOME/Projects/Dauntless/Archon/Binaries/Win64}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
DO_PULL=1
CHECK_HTTP=1
CHECK_ONLY=0

usage() {
  cat <<'USAGE'
Usage: ./Verify-Runtime-NAS.sh [--no-pull] [--no-http] [--check-only]

Par défaut, le script :
  1. fait git fetch + git pull --ff-only depuis origin/main ;
  2. vérifie les manifests, les DLL et les extraFiles des feeds client/server ;
  3. vérifie les URL HTTP et les empreintes des téléchargements ;
  4. vérifie les fichiers installés, notamment winmm.dll ;
  5. si nécessaire, sauvegarde puis remplace MysticParadox.dll par la DLL du feed server ;
  6. vérifie le SHA-256 installé puis redémarre avec ./dauntless.sh restart.

Le script ne remplace jamais winmm.dll.

Options :
  --no-pull     ne fait pas git fetch/pull ; utilise le dépôt local tel quel ;
  --no-http     saute les contrôles HTTP (les contrôles locaux SHA-256 restent actifs) ;
  --check-only  vérifie tout sans arrêter le serveur ni modifier les fichiers du jeu.

Variables : REPO_ROOT, GAME_BIN, REMOTE, BRANCH.
USAGE
}

while (($#)); do
  case "$1" in
    --no-pull) DO_PULL=0 ;;
    --no-http) CHECK_HTTP=0 ;;
    --check-only) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for cmd in git python3 sha256sum stat realpath; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Commande manquante : $cmd" >&2; exit 2; }
done
REPO_ROOT="$(realpath "$REPO_ROOT")"
GAME_BIN="$(realpath -m "$GAME_BIN")"
if [[ ! -d "$REPO_ROOT/.git" ]]; then
  echo "Dépôt introuvable : $REPO_ROOT" >&2
  exit 2
fi
if [[ ! -d "$GAME_BIN" ]]; then
  echo "Répertoire du jeu introuvable : $GAME_BIN" >&2
  exit 2
fi

if (( DO_PULL )); then
  echo "========== GIT FETCH/PULL =========="
  git -C "$REPO_ROOT" fetch "$REMOTE"
  git -C "$REPO_ROOT" pull --ff-only "$REMOTE" "$BRANCH"
fi

cd "$REPO_ROOT"
export REPO_ROOT GAME_BIN CHECK_HTTP

# Phase 1 : aucune modification du jeu tant que tous les contrôles de publication
# et les contrôles HTTP n'ont pas réussi.
python3 <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

repo = pathlib.Path(os.environ["REPO_ROOT"]).resolve()
game_bin = pathlib.Path(os.environ["GAME_BIN"]).resolve()
check_http = os.environ.get("CHECK_HTTP", "1") == "1"
channel = "stable"
platform = "windows-x86_64"
failures = []
feed_results = {}


def report_ok(message):
    print(f"[OK]   {message}")


def report_fail(message):
    print(f"[FAIL] {message}")
    failures.append(message)


def report_update(message):
    print(f"[UPDATE] {message}")


def read_json(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        report_fail(f"JSON impossible à lire : {path} ({exc})")
        return None


def digest_file(path):
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            size += len(chunk)
            h.update(chunk)
    return size, h.hexdigest()


def verify_local_artifact(path, expected_size, expected_hash, description):
    if not path.is_file():
        report_fail(f"Artefact absent du dépôt après pull : {path}")
        return False
    size, sha = digest_file(path)
    if size != int(expected_size) or sha.lower() != str(expected_hash).lower():
        report_fail(
            f"{description} incorrect : size={size} (attendu {expected_size}), "
            f"sha256={sha} (attendu {expected_hash})"
        )
        return False
    report_ok(f"{description} présent dans Git ({size} octets, SHA256 {sha})")
    return True


def verify_http(url, expected_size, expected_hash, description):
    if not url:
        report_fail(f"URL absente pour {description}")
        return
    request = urllib.request.Request(url, headers={"User-Agent": "Mystic-Paradox-Runtime-Check/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            h = hashlib.sha256()
            size = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                h.update(chunk)
        sha = h.hexdigest()
        if size != int(expected_size) or sha.lower() != str(expected_hash).lower():
            report_fail(
                f"Téléchargement HTTP {description} incorrect : size={size}, sha256={sha}"
            )
        else:
            report_ok(f"URL HTTP {description} répond et son contenu est valide")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        report_fail(f"URL HTTP {description} inaccessible : {exc}")


print("========== FEEDS CLIENT / SERVER ==========")
for target in ("client", "server"):
    feed_root = repo / "ParadoxBackend" / "updates" / "runtime" / target / channel / platform
    latest_path = feed_root / "latest.json"
    latest = read_json(latest_path)
    if latest is None:
        continue

    version = str(latest.get("version", ""))
    if not version:
        report_fail(f"{target}: latest.json ne contient pas de version")
        continue
    if latest.get("target") != target:
        report_fail(f"{target}: target dans latest.json vaut {latest.get('target')!r}")
    if latest.get("channel") != channel or latest.get("platform") != platform:
        report_fail(f"{target}: channel/platform incohérent dans latest.json")

    version_dir = feed_root / version
    version_manifest_path = version_dir / "manifest.json"
    version_manifest = read_json(version_manifest_path)
    if version_manifest is not None:
        report_ok(f"{target}: manifest.json de la version {version} présent")

    dll_name = latest.get("file")
    if not dll_name or pathlib.Path(dll_name).name != dll_name:
        report_fail(f"{target}: nom de DLL invalide dans latest.json : {dll_name!r}")
        continue
    dll_path = version_dir / dll_name
    dll_ok = verify_local_artifact(
        dll_path, latest.get("size", -1), latest.get("sha256", ""), f"{target} DLL {version}"
    )

    extras = latest.get("extraFiles") or []
    extra_checks = []
    for extra in extras:
        name = extra.get("name", "")
        if not name or pathlib.Path(name).name != name:
            report_fail(f"{target}: nom d'extra invalide : {name!r}")
            continue
        extra_path = version_dir / name
        ok = verify_local_artifact(
            extra_path, extra.get("size", -1), extra.get("sha256", ""),
            f"{target} extra {name}"
        )
        extra_checks.append((extra, extra_path, ok))

    if not any(item[0].get("name") == "winmm.dll" for item in extra_checks):
        report_fail(f"{target}: winmm.dll ne figure pas dans extraFiles")

    feed_results[target] = {
        "version": version,
        "latest": latest,
        "dll_ok": dll_ok,
        "extras": extra_checks,
    }

if "client" in feed_results and "server" in feed_results:
    c = feed_results["client"]["latest"]
    s = feed_results["server"]["latest"]
    same = (
        c.get("version") == s.get("version")
        and c.get("sha256") == s.get("sha256")
        and c.get("size") == s.get("size")
    )
    if same:
        report_ok("Les feeds client et server publient la même version et la même DLL")
    else:
        report_fail("Les feeds client et server ne sont pas alignés")
else:
    report_fail("Impossible de comparer les feeds client/server : manifest absent")

print("========== URLS DE TELECHARGEMENT ==========")
if check_http:
    server = feed_results.get("server")
    if server:
        latest = server["latest"]
        verify_http(latest.get("url"), latest.get("size", -1), latest.get("sha256", ""), "server DLL")
        for extra, _path, _ok in server["extras"]:
            verify_http(
                extra.get("url"), extra.get("size", -1), extra.get("sha256", ""),
                f"server extra {extra.get('name')}"
            )
else:
    print("[SKIP] Vérification HTTP désactivée (--no-http)")

print("========== FICHIERS REELLEMENT INSTALLES SUR LE NAS ==========")
server = feed_results.get("server")
if server:
    latest = server["latest"]
    installed_dll = game_bin / "MysticParadox.dll"
    if installed_dll.is_file():
        installed_size, installed_hash = digest_file(installed_dll)
        expected_size = int(latest.get("size", -1))
        expected_hash = str(latest.get("sha256", "")).lower()
        if installed_size == expected_size and installed_hash.lower() == expected_hash:
            report_ok(f"DLL installée déjà conforme : {installed_dll} ({installed_hash})")
        else:
            report_update(
                f"DLL à remplacer : {installed_dll}; actuelle size={installed_size}, "
                f"sha256={installed_hash}; attendue size={expected_size}, sha256={expected_hash}"
            )
    else:
        report_update(f"DLL installée absente, installation nécessaire : {installed_dll}")

    for extra, _path, _ok in server["extras"]:
        name = extra.get("name", "")
        installed_extra = game_bin / name
        if installed_extra.is_file():
            actual_size, actual_hash = digest_file(installed_extra)
            expected_size = int(extra.get("size", -1))
            expected_hash = str(extra.get("sha256", "")).lower()
            if actual_size == expected_size and actual_hash.lower() == expected_hash:
                report_ok(f"Extra installé conforme : {installed_extra} ({actual_hash})")
            else:
                report_fail(
                    f"Extra installé différent : {installed_extra}; size={actual_size}, "
                    f"sha256={actual_hash}; attendu size={expected_size}, sha256={expected_hash}. "
                    "Le script ne remplace pas automatiquement les extras."
                )
        else:
            report_fail(
                f"Extra installé introuvable : {installed_extra}. "
                "Le script ne remplace pas automatiquement les extras."
            )

print("========== RESULTAT PREFLIGHT ==========")
if failures:
    print(f"{len(failures)} vérification(s) en échec. Installation annulée ; aucun fichier du jeu n'a été modifié.")
    sys.exit(1)
print("Tous les contrôles de publication et de téléchargement sont OK.")
PY

# La prévalidation Python ci-dessus doit réussir avant de poursuivre.
SERVER_FEED_ROOT="$REPO_ROOT/ParadoxBackend/updates/runtime/server/stable/windows-x86_64"
SERVER_LATEST="$SERVER_FEED_ROOT/latest.json"
mapfile -t SERVER_INFO < <(python3 - "$SERVER_LATEST" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text(encoding="utf-8"))
name = data.get("file", "")
if not name or pathlib.Path(name).name != name:
    raise SystemExit("Nom de DLL serveur invalide dans latest.json")
print(data["version"])
print(name)
print(int(data["size"]))
print(str(data["sha256"]).lower())
PY
)

if ((${#SERVER_INFO[@]} != 4)); then
  echo "Impossible de récupérer les informations du manifest serveur." >&2
  exit 1
fi
VERSION="${SERVER_INFO[0]}"
DLL_NAME="${SERVER_INFO[1]}"
EXPECTED_SIZE="${SERVER_INFO[2]}"
EXPECTED_SHA="${SERVER_INFO[3]}"
SOURCE="$SERVER_FEED_ROOT/$VERSION/$DLL_NAME"
DEST="$GAME_BIN/MysticParadox.dll"

if [[ ! -f "$SOURCE" ]]; then
  echo "DLL source absente : $SOURCE" >&2
  exit 1
fi
SOURCE_SIZE="$(stat -c '%s' "$SOURCE")"
SOURCE_SHA="$(sha256sum "$SOURCE" | awk '{print $1}')"
if [[ "$SOURCE_SIZE" != "$EXPECTED_SIZE" || "$SOURCE_SHA" != "$EXPECTED_SHA" ]]; then
  echo "ERREUR : la DLL source ne correspond pas au manifest serveur." >&2
  echo "Attendu : size=$EXPECTED_SIZE sha256=$EXPECTED_SHA" >&2
  echo "Réel    : size=$SOURCE_SIZE sha256=$SOURCE_SHA" >&2
  exit 1
fi

CURRENT_SHA=""
if [[ -f "$DEST" ]]; then
  CURRENT_SHA="$(sha256sum "$DEST" | awk '{print $1}')"
fi
if [[ "$CURRENT_SHA" == "$EXPECTED_SHA" ]]; then
  echo "========== INSTALLATION =========="
  echo "[OK] MysticParadox.dll est déjà à jour ($VERSION). Aucun redémarrage nécessaire."
  exit 0
fi

if (( CHECK_ONLY )); then
  echo "========== MODE CHECK-ONLY =========="
  echo "[INFO] Tous les artefacts sont valides ; MysticParadox.dll doit être mise à jour vers $VERSION."
  echo "Aucun service arrêté, aucun fichier modifié."
  exit 0
fi

if [[ ! -f "$REPO_ROOT/dauntless.sh" || ! -x "$REPO_ROOT/dauntless.sh" ]]; then
  echo "Script de gestion absent ou non exécutable : $REPO_ROOT/dauntless.sh" >&2
  exit 2
fi
command -v sudo >/dev/null 2>&1 || { echo "Commande manquante : sudo" >&2; exit 2; }

if [[ -f "$DEST" ]]; then
  OWNER="$(stat -c '%U' "$DEST")"
  GROUP="$(stat -c '%G' "$DEST")"
  MODE="$(stat -c '%a' "$DEST")"
else
  OWNER="$(id -un)"
  GROUP="$(id -gn)"
  MODE="644"
fi

# Demande l'authentification sudo avant d'arrêter le service.
echo "========== AUTORISATION ADMIN =========="
sudo -v

BACKUP=""
if [[ -f "$DEST" ]]; then
  BACKUP="$DEST.bak-before-$VERSION-$(date +%Y%m%d-%H%M%S)"
fi
TMP_DEST="$GAME_BIN/.MysticParadox.dll.runtime-update.$$"
SERVICE_STOPPED=0
UPDATE_VERIFIED=0
cleanup() {
  local status=$?
  sudo rm -f "$TMP_DEST" >/dev/null 2>&1 || true
  if (( SERVICE_STOPPED && ! UPDATE_VERIFIED )); then
    echo "[RECUPERATION] La mise à jour n'a pas été validée."
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
      echo "[RECUPERATION] Restauration de la DLL sauvegardée : $BACKUP"
      sudo cp -a "$BACKUP" "$DEST" || echo "[ERREUR] Restauration automatique impossible."
    fi
    if [[ -f "$DEST" ]]; then
      echo "[RECUPERATION] Redémarrage avec la DLL présente avant l'échec..."
      "$REPO_ROOT/dauntless.sh" restart || echo "[ERREUR] Redémarrage de récupération échoué."
    else
      echo "[ATTENTION] Aucune DLL précédente à restaurer ; serveur laissé arrêté."
    fi
  fi
  return "$status"
}
trap cleanup EXIT

printf '========== MISE A JOUR %s ==========\n' "$VERSION"
echo "Source : $SOURCE"
echo "Cible  : $DEST"
echo "SHA256 : $EXPECTED_SHA"

echo "========== ARRET DU SERVEUR =========="
# Arme la récupération avant l'appel : si stop échoue après un arrêt partiel,
# le trap tentera de remettre en route la DLL précédente.
SERVICE_STOPPED=1
"$REPO_ROOT/dauntless.sh" stop

if [[ -n "$BACKUP" ]]; then
  echo "========== SAUVEGARDE DLL ACTUELLE =========="
  sudo cp -a "$DEST" "$BACKUP"
  echo "Sauvegarde : $BACKUP"
fi

echo "========== PREPARATION DLL =========="
if ! sudo install -o "$OWNER" -g "$GROUP" -m "$MODE" "$SOURCE" "$TMP_DEST"; then
  echo "ERREUR : impossible de préparer la nouvelle DLL." >&2
  exit 1
fi
TEMP_SHA="$(sudo sha256sum "$TMP_DEST" | awk '{print $1}')"
TEMP_SIZE="$(sudo stat -c '%s' "$TMP_DEST")"
if [[ "$TEMP_SHA" != "$EXPECTED_SHA" || "$TEMP_SIZE" != "$EXPECTED_SIZE" ]]; then
  echo "ERREUR : la copie temporaire ne correspond pas au manifest." >&2
  exit 1
fi

if ! sudo mv -f "$TMP_DEST" "$DEST"; then
  echo "ERREUR : impossible de remplacer la DLL installée." >&2
  exit 1
fi
INSTALLED_SHA="$(sudo sha256sum "$DEST" | awk '{print $1}')"
INSTALLED_SIZE="$(sudo stat -c '%s' "$DEST")"
if [[ "$INSTALLED_SHA" != "$EXPECTED_SHA" || "$INSTALLED_SIZE" != "$EXPECTED_SIZE" ]]; then
  echo "ERREUR : vérification après installation échouée." >&2
  exit 1
fi

UPDATE_VERIFIED=1
echo "[OK] MysticParadox.dll $VERSION installée : size=$INSTALLED_SIZE sha256=$INSTALLED_SHA"
echo "[INFO] winmm.dll n'a pas été modifiée."

echo "========== REDÉMARRAGE DU SERVEUR =========="
"$REPO_ROOT/dauntless.sh" restart

echo "========== TERMINE =========="
echo "DLL installée et vérifiée : $DEST"
echo "Sauvegarde précédente : ${BACKUP:-aucune (DLL initialement absente)}"
echo "Relance ensuite ce script pour le contrôle final complet."
