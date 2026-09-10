#!/usr/bin/env bash
#
# Периодическая выгрузка БД на домашнюю машину (push-схема).
# Запускается на ОСНОВНОЙ машине (где живёт база) по расписанию: cron / systemd timer.
#
# Схема:
#   1. pg_dump — полный согласованный снимок БД (без остановки сервера);
#   2. rsync по ssh на домашнюю машину → cryptodb-latest.sql;
#   3. (опционально) восстановление на домашней БД через scripts/restore-remote.sh.
#
# Почему push, а не репликация:
#   - основная база НЕ принимает входящих соединений из интернета —
#     исходящий ssh на домашнюю машину инициирует сама основная;
#   - домашняя машина может быть недоступна до недели: неудачный запуск просто
#     завершится с ошибкой (для cron), следующий запуск сделает свежий дамп —
#     данные не теряются, т.к. снимок всегда полный и текущий;
#   - временный дамп живёт только на время выгрузки и удаляется (trap) —
#     лишнего места на 10-ГБ диске основной машины не занимает.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Подхватываем .env (те же PGUSER/PGDATABASE + настройки BACKUP_*).
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# ── Настройки (переопределяются в .env, см. .env.example) ───────────────
BACKUP_HOME_HOST="${BACKUP_HOME_HOST:-}"          # ssh-цель, напр. user@home.example.com
BACKUP_HOME_PORT="${BACKUP_HOME_PORT:-22}"
BACKUP_HOME_DIR="${BACKUP_HOME_DIR:-/srv/cryptodb/backup}"            # каталог дампа на доме
BACKUP_HOME_PROJECT_DIR="${BACKUP_HOME_PROJECT_DIR:-/srv/cryptodb}"   # на доме: каталог с docker-compose.yml
BACKUP_HOME_RESTORE="${BACKUP_HOME_RESTORE:-1}"   # 1 — сразу восстановить на доме; 0 — только файл
BACKUP_SSH_KEY="${BACKUP_SSH_KEY:-}"              # путь к ssh-ключу, если нужен -i
BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-${TMPDIR:-/tmp}}"

PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-cryptodb}"

if [[ -z "$BACKUP_HOME_HOST" ]]; then
  echo "Ошибка: не задан BACKUP_HOME_HOST (см. .env.example)" >&2
  exit 1
fi

SSH_ARGS=(-p "$BACKUP_HOME_PORT")
[[ -n "$BACKUP_SSH_KEY" ]] && SSH_ARGS+=(-i "$BACKUP_SSH_KEY")

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOCAL_DUMP="$BACKUP_TMP_DIR/cryptodb-$TIMESTAMP.sql"
REMOTE_DUMP_PART="$BACKUP_HOME_DIR/cryptodb-latest.sql.part"
REMOTE_DUMP="$BACKUP_HOME_DIR/cryptodb-latest.sql"

cleanup() { rm -f "$LOCAL_DUMP"; }
trap cleanup EXIT

echo "[1/3] pg_dump: $PGDATABASE ..."
docker compose exec -T db pg_dump --no-owner --clean --if-exists \
  -U "$PGUSER" -d "$PGDATABASE" > "$LOCAL_DUMP"
echo "      дамп готов: $(du -h "$LOCAL_DUMP" | cut -f1)"

echo "[2/3] выгрузка на $BACKUP_HOME_HOST:$REMOTE_DUMP"
rsync -az --partial --append-verify -e "ssh ${SSH_ARGS[*]}" \
  "$LOCAL_DUMP" "$BACKUP_HOME_HOST:$REMOTE_DUMP_PART"
ssh "${SSH_ARGS[@]}" "$BACKUP_HOME_HOST" "mv -f '$REMOTE_DUMP_PART' '$REMOTE_DUMP'"

if [[ "$BACKUP_HOME_RESTORE" == "1" ]]; then
  echo "[3/3] восстановление на домашней БД ..."
  ssh "${SSH_ARGS[@]}" "$BACKUP_HOME_HOST" \
    "PROJECT='$BACKUP_HOME_PROJECT_DIR' DUMP='$REMOTE_DUMP' PGUSER='$PGUSER' PGDATABASE='$PGDATABASE' bash -s" \
    < "$REPO_ROOT/scripts/restore-remote.sh"
else
  echo "[3/3] восстановление пропущено (BACKUP_HOME_RESTORE=0)"
fi

echo "OK $TIMESTAMP"
