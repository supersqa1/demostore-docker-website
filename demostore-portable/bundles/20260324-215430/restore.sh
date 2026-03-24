#!/usr/bin/env bash
# Restore a bundle produced by snapshot.sh (same folder as this script).
set -euo pipefail

# Bump when restore logic changes (if you don't see this line, the script is outdated).
echo "demostore-portable restore v3 (wait/import uses MYSQL_USER from manifest, not MySQL root)"

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$BUNDLE_DIR/docker-compose.yml"
MANIFEST="$BUNDLE_DIR/manifest.env"
SQL_GZ="$BUNDLE_DIR/demostore.sql.gz"
WP_TAR="$BUNDLE_DIR/wordpress.tar.gz"

PROJECT="${COMPOSE_PROJECT_NAME:-demostore}"

die() { echo "$*" >&2; exit 1; }

[[ -f "$COMPOSE_FILE" ]] || die "Missing docker-compose.yml in $BUNDLE_DIR"
[[ -f "$MANIFEST" ]] || die "Missing manifest.env (run snapshot.sh on the source server first)"
[[ -f "$SQL_GZ" ]] || die "Missing demostore.sql.gz"
[[ -f "$WP_TAR" ]] || die "Missing wordpress.tar.gz"

require() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
require docker

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose -p "$PROJECT" -f "$COMPOSE_FILE")
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose -p "$PROJECT" -f "$COMPOSE_FILE")
else
  die "Install Docker Compose v2 (docker compose) or v1 (docker-compose)"
fi

# shellcheck source=/dev/null
set -a
source "$MANIFEST"
set +a

# Optional overrides: use restore.local.env (recommended). Avoid naming it .env — docker-compose
# in this directory auto-loads .env and can override compose substitution in surprising ways.
if [[ -f "$BUNDLE_DIR/restore.local.env" ]]; then
  # shellcheck source=/dev/null
  set -a
  source "$BUNDLE_DIR/restore.local.env"
  set +a
elif [[ -f "$BUNDLE_DIR/.env" ]]; then
  echo "Note: loading .env — docker-compose also reads ./.env here. Prefer restore.local.env; see env.example." >&2
  # shellcheck source=/dev/null
  set -a
  source "$BUNDLE_DIR/.env"
  set +a
fi

: "${WORDPRESS_IP:=0.0.0.0}"
: "${WP_PUBLISH_PORT:=7171}"
: "${MYSQL_USER:=wordpress}"
: "${MYSQL_DATABASE:=demostore}"
: "${MYSQL_PASSWORD:?manifest missing MYSQL_PASSWORD (must match wp-config / manifest from snapshot)}"
# Root inside the MySQL image only needs to be consistent for first-time init. Some live servers
# change MySQL root without updating container env; snapshot still captures working MYSQL_PASSWORD
# for the wordpress DB user — we use that for wait + import.
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-password}"
if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
  MYSQL_ROOT_PASSWORD=password
fi

OLD_SITEURL="${WP_SITEURL:-}"
OLD_HOME="${WP_HOME:-}"

if [[ -n "${PUBLIC_SITEURL:-}" ]]; then
  NEW_SITEURL="$PUBLIC_SITEURL"
else
  if [[ "$WORDPRESS_IP" == "0.0.0.0" ]]; then
    NEW_SITEURL="http://127.0.0.1:${WP_PUBLISH_PORT}"
  else
    NEW_SITEURL="http://${WORDPRESS_IP}:${WP_PUBLISH_PORT}"
  fi
fi

if [[ -n "${PUBLIC_HOME:-}" ]]; then
  NEW_HOME="$PUBLIC_HOME"
else
  NEW_HOME="$NEW_SITEURL"
fi

export MYSQL_ROOT_PASSWORD MYSQL_PASSWORD MYSQL_USER MYSQL_DATABASE WORDPRESS_IP WP_PUBLISH_PORT MYSQL_PUBLISH_PORT

FRESH=1
if [[ "${1:-}" == "--no-fresh" ]]; then
  FRESH=0
fi

if [[ "$FRESH" -eq 1 ]]; then
  echo "Stopping stack and removing volumes (full restore)..."
  "${DC[@]}" down -v 2>/dev/null || true
  docker volume rm "${PROJECT}_mysql_data" "${PROJECT}_wordpress_html" 2>/dev/null || true
fi

echo "Starting MySQL..."
WORDPRESS_IP="$WORDPRESS_IP" MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" MYSQL_PASSWORD="$MYSQL_PASSWORD" \
  MYSQL_USER="${MYSQL_USER:-wordpress}" MYSQL_DATABASE="${MYSQL_DATABASE:-demostore}" \
  WP_PUBLISH_PORT="${WP_PUBLISH_PORT:-7171}" MYSQL_PUBLISH_PORT="${MYSQL_PUBLISH_PORT:-3308}" \
  "${DC[@]}" up -d db

echo "Waiting for MySQL (wordpress DB user)..."
ok=0
for _ in $(seq 1 90); do
  if docker exec demostore_mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1" "$MYSQL_DATABASE" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done
[[ "$ok" -eq 1 ]] || die "MySQL did not become ready or $MYSQL_USER cannot connect (check MYSQL_PASSWORD / .env — do not set MYSQL_ROOT_PASSWORD empty in .env)"

echo "Importing database (as $MYSQL_USER)..."
# DB + grants are created by the official MySQL image entrypoint from compose env; we only load data.
gunzip -c "$SQL_GZ" | docker exec -i demostore_mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"

echo "Starting WordPress (seed volume from image)..."
WORDPRESS_IP="$WORDPRESS_IP" MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" MYSQL_PASSWORD="$MYSQL_PASSWORD" \
  MYSQL_USER="${MYSQL_USER:-wordpress}" MYSQL_DATABASE="${MYSQL_DATABASE:-demostore}" \
  WP_PUBLISH_PORT="${WP_PUBLISH_PORT:-7171}" MYSQL_PUBLISH_PORT="${MYSQL_PUBLISH_PORT:-3308}" \
  "${DC[@]}" up -d wordpress

# Let entrypoint create volume layout
sleep 3
docker stop demostore_wp >/dev/null

VOL_WP="${PROJECT}_wordpress_html"
docker volume inspect "$VOL_WP" >/dev/null 2>&1 || die "Missing docker volume $VOL_WP"

echo "Restoring WordPress files into volume $VOL_WP ..."
docker run --rm \
  -v "${VOL_WP}:/var/www/html" \
  -v "${WP_TAR}:/backup/wp.tar.gz:ro" \
  alpine:3.19 \
  sh -c 'set -eu; cd /var/www/html && find . -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar xzf /backup/wp.tar.gz'

docker start demostore_wp >/dev/null
echo "Waiting for Apache..."
sleep 5

fix_url_pair() {
  local old_val="$1" new_val="$2"
  [[ -z "$old_val" || -z "$new_val" || "$old_val" == "$new_val" ]] && return 0
  echo "URL replace: $old_val -> $new_val"
  docker exec demostore_wp /usr/local/bin/wp search-replace "$old_val" "$new_val" --all-tables --allow-root
}

if [[ -n "$OLD_SITEURL" ]]; then
  fix_url_pair "$OLD_SITEURL" "$NEW_SITEURL"
fi
if [[ -n "$OLD_HOME" && "$OLD_HOME" != "$OLD_SITEURL" ]]; then
  fix_url_pair "$OLD_HOME" "$NEW_HOME"
fi

echo ""
echo "Restore finished."
echo "  Front-end: $NEW_SITEURL"
echo "  Compose project: $PROJECT (volumes: ${PROJECT}_mysql_data, ${VOL_WP})"
