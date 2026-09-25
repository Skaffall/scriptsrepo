#!/usr/bin/env bash
# ==============================================================================
# Скрипт автоматизированной ручной установки Arch Linux (UEFI / GPT)
# ==============================================================================

set -e

# 1. Определение целевого диска
# ВНИМАНИЕ: Укажите ваш диск (например, /dev/sda или /dev/nvme0n1)
DISK="/dev/sda"

# Проверка режима UEFI
if [ ! -d "/sys/firmware/efi/efivars" ]; then
    echo "Ошибка: Система загружена не в режиме UEFI!"
    exit 1
fi

echo "=== 1. Синхронизация системных часов ==="
timedatectl set-ntp true

echo "=== 2. Разметка диска $DISK ==="
# Создание таблицы разделов GPT и трех разделов:
# 1: EFI System (1 GiB)
# 2: Linux Swap (4 GiB)
# 3: Linux Root (все оставшееся место)
sfdisk "$DISK" <<EOF
label: gpt
,1G,U,*
,4G,S
,,L
EOF

# Определение имен разделов в зависимости от типа диска (NVMe или SATA)
if [[ "$DISK" =~ "nvme" ]]; then
    PART_EFI="${DISK}p1"
    PART_SWAP="${DISK}p2"
    PART_ROOT="${DISK}p3"
else
    PART_EFI="${DISK}1"
    PART_SWAP="${DISK}2"
    PART_ROOT="${DISK}3"
fi

echo "=== 3. Форматирование разделов ==="
mkfs.fat -F 32 "$PART_EFI"
mkswap "$PART_SWAP"
swapon "$PART_SWAP"
mkfs.ext4 -F "$PART_ROOT"

echo "=== 4. Монтирование разделов ==="
mount "$PART_ROOT" /mnt
mount --mkdir "$PART_EFI" /mnt/boot/efi

echo "=== 5. Установка базовых пакетов и KDE Plasma ==="
pacstrap -K /mnt \
    base base-devel linux linux-headers linux-firmware \
    nano vim sudo networkmanager \
    grub efibootmgr \
    xorg plasma sddm kde-applications \
    ttf-dejavu ttf-liberation

echo "=== 6. Генерация fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

echo "=== 7. Настройка системы внутри chroot ==="
arch-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -e

# Установка часового пояса
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Настройка локали
sed -i 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf
echo "FONT=cyr-sun16" >> /etc/vconsole.conf

# Имя компьютера (hostname)
echo "archpc" > /etc/hostname

# Установка пароля root
echo "root:1234" | chpasswd

# Создание пользователя skaffka и добавление в группу wheel (sudo)
useradd -m -G wheel -s /bin/bash skaffka
echo "skaffka:1234" | chpasswd

# Включение прав sudo для группы wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Включение системных служб
systemctl enable NetworkManager
systemctl enable sddm

# Установка и конфигурация загрузчика GRUB для UEFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

CHROOT_EOF

echo "=== 8. Завершение установки ==="
umount -R /mnt
echo "Установка успешно завершена! Извлеките установочный носитель и выполните 'reboot'."
