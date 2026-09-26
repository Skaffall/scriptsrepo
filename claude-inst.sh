#!/usr/bin/env bash
# ==============================================================================
# Интерактивный скрипт установки Arch Linux (UEFI / GPT) с консольным интерфейсом
# ==============================================================================
#
# Использование: bash install-arch.sh
# Запускать из Arch Linux live-окружения (загрузочный носитель).
#
set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Общие функции интерфейса
# ------------------------------------------------------------------------------

# Используем whiptail, если он есть в live-ISO (обычно есть по умолчанию).
# Если нет — работаем через обычный read с валидацией.
HAS_WHIPTAIL=0
if command -v whiptail >/dev/null 2>&1; then
    HAS_WHIPTAIL=1
fi

msg()  { echo -e "\e[1;32m[*]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ОШИБКА]\e[0m $*" >&2; }

die() {
    err "$*"
    exit 1
}

confirm() {
    # confirm "Текст вопроса" -> возвращает 0 (да) / 1 (нет)
    local prompt="$1"
    if [ "$HAS_WHIPTAIL" -eq 1 ]; then
        whiptail --title "Подтверждение" --yesno "$prompt" 12 70
        return $?
    else
        read -r -p "$prompt [y/N]: " ans
        [[ "$ans" =~ ^[YyДд] ]]
    fi
}

ask_text() {
    # ask_text "Подсказка" "значение_по_умолчанию" -> печатает результат в stdout
    local prompt="$1"
    local default="${2:-}"
    local result
    if [ "$HAS_WHIPTAIL" -eq 1 ]; then
        result=$(whiptail --title "Ввод" --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3) || die "Отменено пользователем"
    else
        read -r -p "$prompt [$default]: " result
        result="${result:-$default}"
    fi
    echo "$result"
}

ask_password() {
    # ask_password "Подсказка" -> печатает пароль в stdout, с повторным вводом для проверки
    local prompt="$1"
    local pass1 pass2
    while true; do
        if [ "$HAS_WHIPTAIL" -eq 1 ]; then
            pass1=$(whiptail --title "Пароль" --passwordbox "$prompt" 10 70 3>&1 1>&2 2>&3) || die "Отменено пользователем"
            pass2=$(whiptail --title "Пароль" --passwordbox "Повторите пароль" 10 70 3>&1 1>&2 2>&3) || die "Отменено пользователем"
        else
            read -r -s -p "$prompt: " pass1; echo
            read -r -s -p "Повторите пароль: " pass2; echo
        fi
        if [ -z "$pass1" ]; then
            warn "Пароль не может быть пустым."
            continue
        fi
        if [ "$pass1" != "$pass2" ]; then
            warn "Пароли не совпадают, попробуйте ещё раз."
            continue
        fi
        echo "$pass1"
        return 0
    done
}

choose_from_menu() {
    # choose_from_menu "Заголовок" опция1 опция2 ... -> печатает выбранную опцию
    local title="$1"; shift
    local options=("$@")
    if [ "$HAS_WHIPTAIL" -eq 1 ]; then
        local wt_args=()
        local i=1
        for opt in "${options[@]}"; do
            wt_args+=("$i" "$opt")
            i=$((i+1))
        done
        local choice
        choice=$(whiptail --title "$title" --menu "Выберите вариант:" 20 78 10 "${wt_args[@]}" 3>&1 1>&2 2>&3) || die "Отменено пользователем"
        echo "${options[$((choice-1))]}"
    else
        echo "$title"
        local i=1
        for opt in "${options[@]}"; do
            echo "  $i) $opt"
            i=$((i+1))
        done
        local sel
        while true; do
            read -r -p "Введите номер: " sel
            if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#options[@]}" ]; then
                echo "${options[$((sel-1))]}"
                return 0
            fi
            warn "Некорректный ввод."
        done
    fi
}

# ------------------------------------------------------------------------------
# 1. Проверка режима загрузки (UEFI)
# ------------------------------------------------------------------------------

if [ ! -d "/sys/firmware/efi/efivars" ]; then
    die "Система загружена не в режиме UEFI! Установка в режиме BIOS/Legacy этим скриптом не поддерживается."
fi

msg "Обнаружен режим загрузки UEFI."

# Проверка интернет-соединения
if ! ping -c 1 -W 3 archlinux.org >/dev/null 2>&1; then
    warn "Не удалось проверить интернет-соединение (ping archlinux.org не прошёл)."
    confirm "Продолжить всё равно? Без интернета pacstrap не сработает." || die "Установка прервана. Настройте сеть (iwctl / ip) и запустите скрипт снова."
else
    msg "Интернет-соединение доступно."
fi

# ------------------------------------------------------------------------------
# 2. Выбор диска
# ------------------------------------------------------------------------------

mapfile -t DISK_LIST < <(lsblk -dnpo NAME,SIZE,MODEL | grep -E '/dev/(sd|nvme|vd)' || true)

if [ "${#DISK_LIST[@]}" -eq 0 ]; then
    die "Не найдено ни одного подходящего диска (sd*, nvme*, vd*)."
fi

msg "Доступные диски:"
printf '  %s\n' "${DISK_LIST[@]}"

DISK=$(choose_from_menu "Выбор диска для установки" "${DISK_LIST[@]}")
DISK="${DISK%% *}"   # берём только путь /dev/xxx, отбрасывая размер/модель

warn "ВНИМАНИЕ: все данные на диске $DISK будут УНИЧТОЖЕНЫ!"
confirm "Вы уверены, что хотите разметить и отформатировать $DISK?" || die "Установка отменена пользователем."

# Повторное текстовое подтверждение — дополнительная защита от ошибки
TYPED=$(ask_text "Для подтверждения введите точное имя диска ($DISK)" "")
[ "$TYPED" = "$DISK" ] || die "Введённое имя диска не совпадает. Установка прервана."

# ------------------------------------------------------------------------------
# 3. Размеры разделов
# ------------------------------------------------------------------------------

EFI_SIZE=$(ask_text "Размер EFI-раздела (например, 1G)" "1G")
SWAP_SIZE=$(ask_text "Размер раздела подкачки (swap), например 4G. Введите 0, чтобы пропустить swap" "4G")

# ------------------------------------------------------------------------------
# 4. Выбор окружения рабочего стола
# ------------------------------------------------------------------------------

DE_CHOICE=$(choose_from_menu "Выбор окружения рабочего стола" \
    "KDE Plasma (полный, kde-applications)" \
    "KDE Plasma (минимальный, plasma-desktop)" \
    "GNOME" \
    "Без графического окружения (только консоль)")

case "$DE_CHOICE" in
    "KDE Plasma (полный, kde-applications)")
        DE_PACKAGES="xorg plasma-meta kde-applications sddm"
        DE_SERVICE="sddm"
        ;;
    "KDE Plasma (минимальный, plasma-desktop)")
        DE_PACKAGES="xorg plasma-desktop konsole dolphin sddm"
        DE_SERVICE="sddm"
        ;;
    "GNOME")
        DE_PACKAGES="xorg gnome gdm"
        DE_SERVICE="gdm"
        ;;
    *)
        DE_PACKAGES=""
        DE_SERVICE=""
        ;;
esac

# ------------------------------------------------------------------------------
# 5. Локаль, часовой пояс, имя хоста, пользователь
# ------------------------------------------------------------------------------

HOSTNAME=$(ask_text "Имя компьютера (hostname)" "archpc")
USERNAME=$(ask_text "Имя пользователя" "user")
TIMEZONE=$(ask_text "Часовой пояс (см. /usr/share/zoneinfo)" "Europe/Moscow")
LOCALE=$(ask_text "Основная локаль" "ru_RU.UTF-8")
KEYMAP=$(ask_text "Раскладка консоли (vconsole)" "ru")

msg "Установка root-пароля:"
ROOT_PASS=$(ask_password "Пароль root")

msg "Установка пароля пользователя $USERNAME:"
USER_PASS=$(ask_password "Пароль $USERNAME")

# ------------------------------------------------------------------------------
# 6. Итоговое подтверждение
# ------------------------------------------------------------------------------

SUMMARY="Диск:            $DISK
EFI раздел:      $EFI_SIZE
Swap:            $SWAP_SIZE
Окружение:       $DE_CHOICE
Hostname:        $HOSTNAME
Пользователь:    $USERNAME
Часовой пояс:    $TIMEZONE
Локаль:          $LOCALE
Раскладка:       $KEYMAP"

echo "=============================================="
echo "$SUMMARY"
echo "=============================================="
confirm "Всё верно? Начать установку? ЭТО СОТРЁТ ДАННЫЕ НА $DISK." || die "Установка отменена."

# ------------------------------------------------------------------------------
# 7. Разметка диска
# ------------------------------------------------------------------------------

msg "Синхронизация системных часов..."
timedatectl set-ntp true

msg "Разметка диска $DISK..."

if [ "$SWAP_SIZE" = "0" ]; then
    sfdisk "$DISK" <<EOF
label: gpt
,${EFI_SIZE},U,*
,,L
EOF
else
    sfdisk "$DISK" <<EOF
label: gpt
,${EFI_SIZE},U,*
,${SWAP_SIZE},S
,,L
EOF
fi

# Определение имён разделов (NVMe использует суффикс pN)
if [[ "$DISK" =~ nvme ]]; then
    PART_EFI="${DISK}p1"
    if [ "$SWAP_SIZE" = "0" ]; then
        PART_ROOT="${DISK}p2"
        PART_SWAP=""
    else
        PART_SWAP="${DISK}p2"
        PART_ROOT="${DISK}p3"
    fi
else
    PART_EFI="${DISK}1"
    if [ "$SWAP_SIZE" = "0" ]; then
        PART_ROOT="${DISK}2"
        PART_SWAP=""
    else
        PART_SWAP="${DISK}2"
        PART_ROOT="${DISK}3"
    fi
fi

msg "Разделы: EFI=$PART_EFI SWAP=${PART_SWAP:-нет} ROOT=$PART_ROOT"

# ------------------------------------------------------------------------------
# 8. Форматирование и монтирование
# ------------------------------------------------------------------------------

msg "Форматирование разделов..."
mkfs.fat -F 32 "$PART_EFI"
if [ -n "$PART_SWAP" ]; then
    mkswap "$PART_SWAP"
    swapon "$PART_SWAP"
fi
mkfs.ext4 -F "$PART_ROOT"

msg "Монтирование разделов..."
mount "$PART_ROOT" /mnt
mount --mkdir "$PART_EFI" /mnt/boot/efi

# ------------------------------------------------------------------------------
# 9. Установка базовой системы
# ------------------------------------------------------------------------------

msg "Установка базовых пакетов (это может занять время)..."
pacstrap -K /mnt \
    base base-devel linux linux-headers linux-firmware \
    nano vim sudo networkmanager grub efibootmgr \
    ttf-dejavu ttf-liberation \
    $DE_PACKAGES

msg "Генерация fstab..."
genfstab -U /mnt > /mnt/etc/fstab

# ------------------------------------------------------------------------------
# 10. Настройка внутри chroot
# ------------------------------------------------------------------------------

msg "Настройка системы внутри chroot..."

# Пароли передаём через переменные окружения, а не хардкодим в heredoc
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -e

ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

sed -i 's/^#${LOCALE}/${LOCALE}/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname
cat >> /etc/hosts <<HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS_EOF

echo "root:${ROOT_PASS}" | chpasswd

useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASS}" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
$( [ -n "$DE_SERVICE" ] && echo "systemctl enable ${DE_SERVICE}" )

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_EOF

# ------------------------------------------------------------------------------
# 11. Завершение
# ------------------------------------------------------------------------------

msg "Отмонтирование разделов..."
umount -R /mnt
[ -n "${PART_SWAP:-}" ] && swapoff "$PART_SWAP" || true

msg "Установка успешно завершена!"
echo "Извлеките установочный носитель и выполните 'reboot'."
