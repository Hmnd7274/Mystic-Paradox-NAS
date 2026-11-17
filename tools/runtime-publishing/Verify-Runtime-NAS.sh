#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$HOME/Projects/Mystic-Paradox}"
GAME_BIN="${GAME_BIN:-$HOME/Projects/Dauntless/Archon/Binaries/Win64}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
DO_PULL=1
CHECK_HTTP=1

usage() {
  cat <<'EOF'
Usage: ./Verify-Runtime-NAS.sh [--no-pull] [--no-http]

Par défaut :
  1. git fetch + git pull --ff-only depuis origin/main ;
  2. vérifie les manifests, les DLL et tous les extraFiles des feeds client/server ;
  3. vérifie les URL de téléchargement HTTP ;
  4. compare MysticParadox.dll et les extras (dont winmm.dll) avec les fichiers installés.

Le script est en lecture seule côté jeu : il ne copie aucun fichier, n'arrête aucun service
et ne redémarre rien. Variables configurables : REPO_ROOT, GAME_BIN, REMOTE, BRANCH.
EOF
}

while (($#)); do
  case "$1" in
    --no-pull) DO_PULL=0 ;;
    --no-http) CHECK_HTTP=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for cmd in git python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Commande manquante : $cmd" >&2; exit 2; }
done
if (( CHECK_HTTP )); then
  command -v curl >/dev/null 2>&1 || { echo "Commande manquante : curl (ou utiliser --no-http)" >&2; exit 2; }
fi

if [[ ! -d "$REPO_ROOT/.git" ]]; then
  echo "Dépôt introuvable : $REPO_ROOT" >&2
  exit 2
fi

if (( DO_PULL )); then
  echo "========== GIT FETCH/PULL =========="
  git -C "$REPO_ROOT" fetch "$REMOTE"
  git -C "$REPO_ROOT" pull --ff-only "$REMOTE" "$BRANCH"
fi

export REPO_ROOT GAME_BIN CHECK_HTTP
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
        with urllib.request.urlopen(request, timeout=30) as response:
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
    dll_ok = verify_local_artifact(dll_path, latest.get("size", -1), latest.get("sha256", ""), f"{target} DLL {version}")

    extras = latest.get("extraFiles") or []
    extra_checks = []
    for extra in extras:
        name = extra.get("name", "")
        if not name or pathlib.Path(name).name != name:
            report_fail(f"{target}: nom d'extra invalide : {name!r}")
            continue
        extra_path = version_dir / name
        ok = verify_local_artifact(
            extra_path, extra.get("size", -1), extra.get("sha256", ""), f"{target} extra {name}"
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

print("========== URLS DE TELECHARGEMENT ==========")
if check_http:
    server = feed_results.get("server")
    if server:
        latest = server["latest"]
        verify_http(latest.get("url"), latest.get("size", -1), latest.get("sha256", ""), "server DLL")
        for extra, _path, _ok in server["extras"]:
            verify_http(extra.get("url"), extra.get("size", -1), extra.get("sha256", ""), f"server extra {extra.get('name')}")
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
            report_ok(f"DLL installée conforme : {installed_dll} ({installed_hash})")
        else:
            report_fail(
                f"DLL installée différente : {installed_dll}; size={installed_size}, "
                f"sha256={installed_hash}; attendu size={expected_size}, sha256={expected_hash}"
            )
    else:
        report_fail(f"DLL installée introuvable : {installed_dll}")

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
                    f"sha256={actual_hash}; attendu size={expected_size}, sha256={expected_hash}"
                )
        else:
            report_fail(f"Extra installé introuvable : {installed_extra}")

print("========== RESULTAT ==========")
if failures:
    print(f"{len(failures)} vérification(s) en échec. Aucun fichier du jeu n'a été modifié.")
    sys.exit(1)
print("Toutes les vérifications sont OK. Aucun fichier du jeu n'a été modifié.")
PY
