#!/bin/bash

# ============================================================
# logrotate.sh — Настройка ротации логов
# ============================================================

RED="\e[91m"
GREEN="\e[92m"
YELLOW="\e[93m"
CYAN="\e[96m"
NC="\e[0m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запусти скрипт с правами root: sudo bash logrotate.sh${NC}"
    exit 1
fi

echo -e "${CYAN}Настройка logrotate...${NC}"
echo ""

# ============================================================
# Шаг 1: Устанавливаем logrotate если не установлен
# ============================================================
if ! command -v logrotate >/dev/null 2>&1; then
    echo -e "${YELLOW}logrotate не найден, устанавливаю...${NC}"
    apt-get install -yqq logrotate >/dev/null 2>&1
    echo -e "${GREEN}✓ logrotate установлен.${NC}"
else
    echo -e "${GREEN}✓ logrotate уже установлен.${NC}"
fi

# ============================================================
# Шаг 2: Комментируем wtmp и btmp в /etc/logrotate.conf
# (они уже есть в /etc/logrotate.d/wtmp и btmp — дубликаты)
# ============================================================
if [ ! -f /etc/logrotate.conf.bak ]; then
    cp /etc/logrotate.conf /etc/logrotate.conf.bak
fi

python3 << 'PYEOF'
import re

with open('/etc/logrotate.conf', 'r') as f:
    content = f.read()

def comment_block(text, logfile):
    pattern = rf'(^{re.escape(logfile)}\s*\n?\s*\{{[^}}]*\}})'
    def replacer(m):
        lines = m.group(1).splitlines()
        return '\n'.join('# ' + l for l in lines)
    return re.sub(pattern, replacer, text, flags=re.MULTILINE | re.DOTALL)

content = comment_block(content, '/var/log/wtmp')
content = comment_block(content, '/var/log/btmp')

with open('/etc/logrotate.conf', 'w') as f:
    f.write(content)
PYEOF
echo -e "${GREEN}✓ wtmp и btmp закомментированы в logrotate.conf.${NC}"

# ============================================================
# Шаг 3: Функция добавления директивы su в конфиги logrotate.d
# Работает с { как в конце строки, так и на отдельной строке
# ============================================================
add_su_directive() {
    local file="$1"
    local user="$2"
    local group="$3"

    [ ! -f "$file" ] && return
    grep -q "su " "$file" && return

    python3 - "$file" "$user" "$group" << 'PYEOF'
import sys, re

filepath, user, group = sys.argv[1], sys.argv[2], sys.argv[3]
su_line = f"    su {user} {group}"

with open(filepath, 'r') as f:
    content = f.read()

# Нормализуем: если { на отдельной строке — присоединяем к предыдущей
normalized = re.sub(r'(\S)\s*\n\s*\{', r'\1 {', content)

# Вставляем su после каждой открывающей {
result = re.sub(r'(\{)(\s*\n)', rf'\1\2{su_line}\n', normalized)

with open(filepath, 'w') as f:
    f.write(result)
PYEOF
    echo -e "${GREEN}✓ su $user $group добавлен в $(basename $file).${NC}"
}

# ============================================================
# Шаг 4: Переопределяем /etc/logrotate.d/rsyslog
# ============================================================
rm -f /etc/logrotate.d/custom-system /etc/logrotate.d/custom-ssh

cat > /etc/logrotate.d/rsyslog << 'LOGROTATE'
/var/log/syslog
/var/log/auth.log
/var/log/kern.log
/var/log/mail.log
/var/log/user.log {
    su root syslog
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    create 0640 syslog adm
    sharedscripts
    postrotate
        systemctl reload rsyslog 2>/dev/null || true
    endscript
}
LOGROTATE
echo -e "${GREEN}✓ Конфиг rsyslog обновлён.${NC}"

# ============================================================
# Шаг 5: Добавляем su в проблемные конфиги logrotate.d
# ============================================================
add_su_directive /etc/logrotate.d/alternatives  root root
add_su_directive /etc/logrotate.d/apport        root root
add_su_directive /etc/logrotate.d/bootlog       root root
add_su_directive /etc/logrotate.d/dpkg          root root
add_su_directive /etc/logrotate.d/ufw           root syslog
add_su_directive /etc/logrotate.d/wtmp          root utmp
add_su_directive /etc/logrotate.d/btmp          root utmp

# ============================================================
# Шаг 6: Docker-логи (если Docker установлен)
# ============================================================
if command -v docker >/dev/null 2>&1; then
    cat > /etc/logrotate.d/custom-docker << 'LOGROTATE'
/var/lib/docker/containers/*/*.log {
    su root root
    daily
    rotate 7
    compress
    maxsize 10M
    missingok
    notifempty
    copytruncate
}
LOGROTATE
    echo -e "${GREEN}✓ Конфиг Docker-логов создан.${NC}"
else
    echo -e "${CYAN}Docker не найден, пропускаем.${NC}"
fi

# ============================================================
# Шаг 7: Проверка конфигурации
# ============================================================
echo ""
echo -e "${YELLOW}Проверяю конфигурацию...${NC}"
ERRORS=$(logrotate -d /etc/logrotate.conf 2>&1 | grep -i "error")
if [ -n "$ERRORS" ]; then
    echo "$ERRORS"
    echo -e "${RED}⚠ Найдены ошибки, проверь выше.${NC}"
else
    echo -e "${GREEN}✓ Конфигурация без ошибок.${NC}"
fi

# ============================================================
# Шаг 8: Тестовый прогон
# ============================================================
echo ""
echo -e "${YELLOW}Файлы, которые будут ротированы:${NC}"
logrotate -d /etc/logrotate.conf 2>&1 | grep "rotating pattern" | awk '{print "  →", $3}'

# ============================================================
# Итог
# ============================================================
echo ""
echo -e "${CYAN}Активные конфиги logrotate:${NC}"
for f in /etc/logrotate.d/*; do
    echo -e "  ${GREEN}✓${NC} $f"
done

echo ""
echo -e "${GREEN}Готово! logrotate настроен.${NC}"
echo -e "${CYAN}Ручная принудительная ротация: ${GREEN}logrotate -f /etc/logrotate.conf${NC}"