#!/usr/bin/env bash
#
# Выполняется НА ДОМАШНЕЙ машине: backup-push.sh передаёт этот скрипт по ssh
# (bash -s), переменные окружения задаются в ssh-команде:
#
#   PROJECT     — каталог на доме, где лежит docker-compose.yml (сервис db)
#   DUMP        — путь к выгруженному дампу (.sql)
#   PGUSER      — учётная запись БД (та же, что на основной машине)
#   PGDATABASE  — имя БД
#
# Дамп создан на основной машине с ключами pg_dump --clean --if-exists,
# поэтому таблицы домашней БД заменяются целиком. Копия предназначена
# для чтения/аналитики: свои записи на ней не сохранятся (будут перезаписаны).

set -euo pipefail

: "${PROJECT:?не задан PROJECT}"
: "${DUMP:?не задан DUMP}"
: "${PGUSER:?не задан PGUSER}"
: "${PGDATABASE:?не задан PGDATABASE}"

cd "$PROJECT"

echo "  проект: $PROJECT"
echo "  база:   $PGDATABASE  <-  $DUMP"

cat "$DUMP" | docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDATABASE" >/dev/null

echo "  restore OK"
