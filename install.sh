#!/usr/bin/env bash
# Установка сервера TVOREH на Linux с Docker одной командой:
#   curl -fsSL https://raw.githubusercontent.com/chuck-uz/OrehTV/main/install.sh | bash
# Что делает: проверяет Docker, память и диск; кладёт файлы в /opt/tvoreh (или $TVOREH_DIR); по желанию скачивает
# снимок базы раздач (~2,5 ГБ, иначе база соберётся сама за сутки); запускает контейнеры; печатает адрес и код мастера.
set -euo pipefail

REPO="${OREHTV_REPO:-chuck-uz/OrehTV}"
RAW="https://raw.githubusercontent.com/$REPO/main"
DIR="${TVOREH_DIR:-/opt/tvoreh}"
FILES="docker-compose.yml Caddyfile .env.example jacred/config/init.yaml"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

say "TVOREH — установка сервера"

# --- проверки -------------------------------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || SUDO="sudo"; SUDO="${SUDO:-}"
command -v docker >/dev/null || die "нужен Docker: https://docs.docker.com/engine/install/ (потом запустите установку снова)"
docker compose version >/dev/null 2>&1 || die "нужен плагин docker compose (пакет docker-compose-plugin)"
$SUDO docker info >/dev/null 2>&1 || die "Docker не запущен или нет прав (добавьте себя в группу docker или запустите через sudo)"
for t in curl tar awk; do command -v $t >/dev/null || die "нужна утилита $t"; done
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) die "поддерживаются только amd64 и arm64, у вас $(uname -m)";; esac
mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem" -ge 3500 ] || die "нужно не меньше 4 ГБ памяти, сейчас ${mem} МБ"
$SUDO mkdir -p "$DIR"
free_gb=$(df -BG "$DIR" | awk 'NR==2 {gsub("G","",$4); print $4}')
[ "$free_gb" -ge 15 ] || die "нужно не меньше 15 ГБ свободно в $DIR, сейчас ${free_gb} ГБ"
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ':80$'; then
  PORT_DEFAULT=8080; echo "Порт 80 занят — сервер будет на 8080 (можно поменять в $DIR/.env)."
else PORT_DEFAULT=80; fi

# --- файлы ------------------------------------------------------------------------------------------------------------
say "Файлы → $DIR"
cd "$DIR"
$SUDO mkdir -p data secrets jacred/config jacred/data torrserver
for f in $FILES; do
  $SUDO curl -fsSL "$RAW/$f" -o "$f.new" || die "не скачался $f"
  if [ -f "$f" ] && ! $SUDO cmp -s "$f" "$f.new"; then $SUDO cp -a "$f" "$f.pre-$(date +%Y%m%d)"; fi
  $SUDO mv "$f.new" "$f"
done
if [ ! -f .env ]; then
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
  $SUDO tee .env >/dev/null <<EOF
# TVOREH — настройки сервера. Пароль админки и ключи задаются в мастере (http://<адрес>/setup) и в админке.
PORT=$PORT_DEFAULT
TZ=${tz:-UTC}
SERVER_NAME=$(hostname -s 2>/dev/null || echo TVOREH)
UPDATES_CHANNEL=release
COMPOSE_PROFILES=linux
EOF
  $SUDO chmod 600 .env
fi

# --- снимок базы раздач -----------------------------------------------------------------------------------------------
# При «curl … | bash» stdin — это сам скрипт, поэтому спрашиваем через /dev/tty; без терминала — TVOREH_SNAPSHOT (по умолчанию да).
if [ ! -f jacred/data/masterDb.bz ]; then
  say "База раздач"
  echo "Без снимка база соберётся сама примерно за сутки (всё это время поиск неполный). Снимок — около 2 ГБ."
  ans=${TVOREH_SNAPSHOT:-}
  if [ -z "$ans" ] && { : </dev/tty; } 2>/dev/null; then read -r -p "Скачать снимок базы? [Y/n] " ans </dev/tty || ans=y; fi
  ans=${ans:-y}
  if [ "${ans:-y}" != "n" ] && [ "${ans:-y}" != "N" ]; then
    # GitHub сортирует релизы по дате коммита тега, а не публикации: снимок может оказаться за сотней сборок — листаем.
    tag=""
    for page in 1 2 3 4 5; do
      tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page" | awk -F'"' '/"tag_name": "jacred-base-/ {print $4}' | sort -r | head -1) || tag=""
      [ -n "$tag" ] && break
    done
    if [ -z "$tag" ]; then echo "Снимка на витрине пока нет — база соберётся сама."; else
      parts=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$tag" | awk -F'"' '/"browser_download_url"/ && /jacred-base\.tar\.part/ {print $4}' | sort)
      tmp=$(mktemp -d); n=0
      for u in $parts; do n=$((n+1)); echo "часть $n: $(basename "$u")"; curl -fL --progress-bar "$u" -o "$tmp/$(basename "$u")" || die "не скачалась часть снимка"; done
      say "Распаковка снимка ($tag)"
      cat "$tmp"/jacred-base.tar.part* | $SUDO tar -xf - -C jacred/data || die "снимок не распаковался"
      rm -rf "$tmp"
    fi
  fi
fi

# --- код мастера, права, запуск ---------------------------------------------------------------------------------------
# Конечный кусок /dev/urandom: «tr </dev/urandom | head» под pipefail падает с SIGPIPE и роняет весь скрипт.
code=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' | cut -c1-6)
printf '%s' "$code" | $SUDO tee data/setup-code >/dev/null
$SUDO chown -R 1000:1000 data secrets jacred/data torrserver
$SUDO chmod 600 data/setup-code
say "Запуск контейнеров (первый раз — скачивание образов, несколько минут)"
$SUDO docker compose pull -q
$SUDO docker compose up -d
# Автообновление сервера: раз в сутки ночью свежий образ api; up -d пересоздаёт только то, у чего образ сменился.
# Минута случайная — чтобы серверы друзей не ходили в ghcr.io все разом.
if [ -d /etc/cron.d ]; then
  printf '%s\n' "# TVOREH: ежедневное обновление сервера (ставит install.sh). Журнал — $DIR/update.log" \
    "$((RANDOM % 60)) 4 * * * root cd $DIR && { date; docker compose pull -q api && docker compose up -d; } >> $DIR/update.log 2>&1" \
    | $SUDO tee /etc/cron.d/orehtv-update >/dev/null
  $SUDO chmod 644 /etc/cron.d/orehtv-update
  echo "Автообновление: каждую ночь в 04:xx (/etc/cron.d/orehtv-update)."
else
  echo "cron не найден — автообновления не будет; обновлять вручную: cd $DIR && docker compose pull && docker compose up -d"
fi
port=$(grep -E '^PORT=' .env | cut -d= -f2)
for i in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null && break; sleep 2; done
curl -fsS -o /dev/null "http://127.0.0.1:$port/health" || die "сервер не поднялся — смотрите: docker compose -f $DIR/docker-compose.yml logs api"

# Адрес основного интерфейса (маршрут наружу): hostname -I выдаёт ещё и сети Docker (172.17.0.1 …), они только путают.
ips=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
[ -n "$ips" ] || ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|192\.168\.)' | head -1) || true
say "Готово"
echo "Сервер работает. Откройте в браузере мастер первого запуска:"
for ip in ${ips:-127.0.0.1}; do echo "    http://$ip${port:+$( [ "$port" = 80 ] || echo ":$port")}/setup"; done
echo "Код мастера:  $code"
echo
echo "Потом поставьте приложение на телевизор (APK из https://github.com/$REPO/releases) — оно найдёт сервер само."
