#!/bin/bash
# Déploiement PDF-Chunker
# Usage :
#   Première installation : sudo bash deploy.sh install
#   Mise à jour           : sudo bash deploy.sh update

set -euo pipefail

APP_DIR="/opt/pdf-chunker"
REPO_URL="${REPO_URL:-}"          # ex. git@github.com:vous/PDF-Chunker.git
REPO_BRANCH="${REPO_BRANCH:-main}"
ENV_FILE="/etc/pdf-chunker.env"
SERVICE_FILE="/etc/systemd/system/pdf-chunker.service"
APP_USER="${APP_USER:-ubuntu}"
PORT="${PORT:-8765}"
BACKUP_DIR="/tmp/pdf-chunker-backup-$(date +%s)"

# ── Couleurs ───────────────────────────────────────────────────────────────────
G="\033[0;32m"; R="\033[0;31m"; Y="\033[1;33m"; N="\033[0m"
step() { echo -e "\n${G}==>${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[x]${N} $*" >&2; exit 1; }

# ── Pré-requis ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Lancer en root : sudo bash deploy.sh $*"
command -v python3 >/dev/null || die "python3 introuvable"
command -v git     >/dev/null || die "git introuvable"

# ── Sous-commandes ─────────────────────────────────────────────────────────────
CMD="${1:-}"
case "$CMD" in
  install|update) ;;
  *) echo "Usage: sudo bash deploy.sh <install|update>"; exit 1 ;;
esac

# ── 1. Arrêt du service ────────────────────────────────────────────────────────
step "Arrêt du service"
systemctl stop pdf-chunker 2>/dev/null || true

# ── 2. Sauvegarde des données ──────────────────────────────────────────────────
step "Sauvegarde des données"
if [[ -d "$APP_DIR/data" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -r "$APP_DIR/data" "$BACKUP_DIR/"
    echo "  → $BACKUP_DIR"
fi

# ── 3. Code source ────────────────────────────────────────────────────────────
step "Code source"
mkdir -p "$APP_DIR"

if [[ "$CMD" == "install" ]]; then
    [[ -n "$REPO_URL" ]] || die "Définir REPO_URL=git@github.com:vous/PDF-Chunker.git"
    if [[ -d "$APP_DIR/.git" ]]; then
        warn "Repo déjà présent — pull à la place"
        git -C "$APP_DIR" fetch origin
        git -C "$APP_DIR" checkout "$REPO_BRANCH"
        git -C "$APP_DIR" reset --hard "origin/$REPO_BRANCH"
    else
        git clone --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
    fi
else
    # update : simple pull
    [[ -d "$APP_DIR/.git" ]] || die "Pas de repo git dans $APP_DIR — lancez d'abord : install"
    git -C "$APP_DIR" fetch origin
    git -C "$APP_DIR" reset --hard "origin/$REPO_BRANCH"
fi

chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
mkdir -p "$APP_DIR/data/projects"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR/data"

# ── 4. Secrets ────────────────────────────────────────────────────────────────
step "Secrets"
if [[ ! -f "$ENV_FILE" ]]; then
    SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    read -rsp "  Mot de passe de l'application (APP_PASSWORD) : " APP_PASS
    echo
    cat > "$ENV_FILE" <<EOF
APP_PASSWORD=${APP_PASS}
SECRET_KEY=${SECRET_KEY}
DATA_DIR=${APP_DIR}/data
EOF
    chmod 600 "$ENV_FILE"
    echo "  → $ENV_FILE créé (chmod 600)"
else
    echo "  → $ENV_FILE existant conservé"
fi

# ── 5. Python venv + dépendances ──────────────────────────────────────────────
step "Python venv + dépendances"
if [[ ! -d "$APP_DIR/venv" ]]; then
    python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --upgrade pip -q
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q
echo "  → OK"

# ── 6. Service systemd ────────────────────────────────────────────────────────
step "Service systemd"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PDF-Chunker RAG Configurator
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app --host 127.0.0.1 --port ${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pdf-chunker
systemctl start pdf-chunker
sleep 2

# ── 7. Résultat ────────────────────────────────────────────────────────────────
echo ""
systemctl status pdf-chunker --no-pager | head -15
echo ""
echo -e "${G}Déploiement terminé.${N}"
echo "  → App       : http://127.0.0.1:${PORT}"
echo "  → Secrets   : $ENV_FILE"
echo "  → Backups   : $BACKUP_DIR (si données existantes)"
echo ""
echo "Pensez à configurer Nginx en reverse proxy (voir README)."
