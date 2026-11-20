# Текст RESTORE.txt внутри бэкапа. Его должно хватить без этой утилиты:
# установщик FreeBSD уже содержит gpart, dd, zfs и gzip.

cb_plan_line() {
    printf '%s\n' "$*" >>"$plan_out"
}

cb_decompress_cmd() {
    case $1 in
        gzip) printf '%s\n' "gzip -dc" ;;
        xz) printf '%s\n' "xz -dc" ;;
        zstd) printf '%s\n' "zstd -dc" ;;
        none) printf '%s\n' "cat" ;;
        *) printf '%s\n' "cat" ;;
    esac
}

cb_emit_stream_commands() {
    id=$1
    dir=$2
    relprefix=$3
    comp=$(cb_meta_get "$dir" compress)
    enc=$(cb_meta_get "$dir" encrypt)
    [ -n "$comp" ] || comp=$cb_compress
    streams=$dir/meta/streams.tsv
    [ -f "$streams" ] || return 0
    dec=$(cb_decompress_cmd "$comp")
    while IFS=$(printf '\t') read -r seq pool dataset kind parent snap raw file; do
        [ -n "${seq:-}" ] || continue
        [ "$seq" = seq ] && continue
        cb_plan_line "# $id $kind $dataset"
        src="$relprefix$file"
        if [ "$enc" = 1 ]; then
            cb_plan_line "openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/root/cifsbak.key -in $(cb_sq "$src") | $dec | zfs receive -u -F $(cb_sq "$dataset")"
        else
            cb_plan_line "$dec $(cb_sq "$src") | zfs receive -u -F $(cb_sq "$dataset")"
        fi
    done <"$streams"
}

cb_write_plan() {
    plan_out=$1
    : >"$plan_out"
    uname_line=
    if [ -f "$cb_partial/inventory/uname.txt" ]; then
        uname_line=$(head -n 1 "$cb_partial/inventory/uname.txt")
    fi
    cb_plan_line "cifsbak — восстановление $cb_hostname"
    cb_plan_line "===================================="
    cb_plan_line "backup_id: $cb_id"
    cb_plan_line "host: $cb_hostname"
    cb_plan_line "mode: $cb_run_mode"
    cb_plan_line "snap: ${cb_snap:-}"
    cb_plan_line "tool: cifsbak ${CB_VERSION}"
    if [ -n "$uname_line" ]; then
        cb_plan_line "source: $uname_line"
    fi
    cb_plan_line ""
    cb_plan_line "Этот каталог — самодостаточная копия системы FreeBSD."
    cb_plan_line "Потоки ZFS — не tar. Их принимает только zfs receive."
    cb_plan_line "Восстанавливайте с установочного носителя той же или более новой"
    cb_plan_line "версии FreeBSD, чем исходная система. Не подавайте потоки в пул,"
    cb_plan_line "с которого сейчас загружена рабочая система."
    cb_plan_line ""
    cb_plan_line "Быстрый путь, если пул уже создан и импортирован с altroot"
    cb_plan_line "(zpool import -N -R /mnt <пул>):"
    cb_plan_line ""
    cb_plan_line "    sh tool/bin/cifsbak restore --yes"
    cb_plan_line ""
    if [ "${cb_encrypt:-0}" = 1 ]; then
        cb_plan_line "Потоки зашифрованы. Рядом с командой положите ключ и добавьте"
        cb_plan_line "--keyfile /root/cifsbak.key. Без ключа данные не читаются."
        cb_plan_line ""
    fi
    cb_plan_line "Ниже те же действия базовыми программами установщика."
    cb_plan_line "Команды выполняются из каталога этого бэкапа."
    cb_plan_line ""
    cb_plan_line "1. Разметить новый диск"
    cb_plan_line ""
    if [ -s "$cb_partial/inventory/disks.tsv" ]; then
        awk -F '\t' 'NF && !seen[$1]++ {print $1}' "$cb_partial/inventory/disks.tsv" >"$cb_runtime/plan-disks"
        while IFS= read -r disk; do
            [ -n "$disk" ] || continue
            if [ -s "$cb_partial/inventory/gpart/$disk.backup" ]; then
                cb_plan_line "gpart restore -F $(cb_sq "$disk") < $(cb_sq "inventory/gpart/$disk.backup")"
            else
                cb_plan_line "# для $disk нет gpart backup, смотрите inventory/gpart-list.txt"
            fi
        done <"$cb_runtime/plan-disks"
        cb_plan_line ""
        cb_plan_line "Образ EFI, если он есть (после gpart restore, поверх раздела ESP):"
        found_efi=0
        for img in "$cb_partial/inventory/efi/"*.img; do
            [ -f "$img" ] || continue
            found_efi=1
            base=$(basename "$img")
            cb_plan_line "dd if=$(cb_sq "inventory/efi/$base") of=$(cb_sq "/dev/${base%.img}") bs=1m"
        done
        if [ "$found_efi" = 0 ]; then
            cb_plan_line "# образ ESP не снят"
        fi
        cb_plan_line ""
        cb_plan_line "Если машина не грузится по EFI, с установочного носителя:"
        cb_plan_line "    mount -t msdosfs /dev/<раздел-efi> /mnt/efi"
        cb_plan_line "    mkdir -p /mnt/efi/efi/boot /mnt/efi/efi/freebsd"
        cb_plan_line "    cp /boot/loader.efi /mnt/efi/efi/boot/bootx64.efi"
        cb_plan_line "    cp /boot/loader.efi /mnt/efi/efi/freebsd/loader.efi"
        cb_plan_line "    umount /mnt/efi"
        awk -F '\t' '$5 == "freebsd-boot" { printf "%s %s\n", $1, $3 }' \
            "$cb_partial/inventory/disks.tsv" >"$cb_runtime/plan-bios"
        if [ -s "$cb_runtime/plan-bios" ]; then
            cb_plan_line ""
            cb_plan_line "Раздел freebsd-boot (схема BIOS/GPT):"
            while read -r disk index; do
                [ -n "$disk" ] || continue
                cb_plan_line "gpart bootcode -b /boot/pmbr -p /boot/gptboot -i $(cb_sq "$index") $(cb_sq "$disk")"
            done <"$cb_runtime/plan-bios"
        fi
    else
        cb_plan_line "# gpart list не сохранился. Размечайте диск по своим записям:"
        cb_plan_line "# небольшой ESP (efi), swap при необходимости, остальное freebsd-zfs."
    fi
    cb_plan_line ""
    cb_plan_line "2. Создать пул (имя пула оставьте прежним, altroot=/mnt)"
    cb_plan_line ""
    if [ -f "$cb_partial/inventory/poolprops.tsv" ]; then
        while IFS=$(printf '\t') read -r pool ashift bootfs autoexpand autotrim; do
            [ -n "${pool:-}" ] || continue
            [ "$pool" = pool ] && continue
            status="$cb_partial/inventory/zpool-status-$pool.txt"
            sug=$(cb_suggest_create "$pool" "$status" "$ashift" || true)
            case $sug in
                zpool\ create*) cb_plan_line "$sug" ;;
                "") cb_plan_line "# пул $pool: соберите zpool create по inventory/zpool-status-$pool.txt" ;;
                *) cb_plan_line "# пул $pool: $sug" ;;
            esac
        done <"$cb_partial/inventory/poolprops.tsv"
    fi
    cb_plan_line ""
    cb_plan_line "3. Принять потоки. Для инкремента сначала идёт базовый полный бэкап."
    cb_plan_line "   zfs receive -u не монтирует датасеты, даже если mountpoint=/."
    cb_plan_line ""
    if [ -n "${cb_parent_id:-}" ]; then
        cb_chain_oldest_first "$cb_hostdir" "$cb_parent_id" >"$cb_runtime/plan-chain"
    else
        : >"$cb_runtime/plan-chain"
    fi
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        cb_emit_stream_commands "$id" "$cb_hostdir/$id" "../$id/"
    done <"$cb_runtime/plan-chain"
    cb_emit_stream_commands "$cb_id" "$cb_partial" ""
    cb_plan_line ""
    cb_plan_line "4. Загрузчик ZFS и проверка"
    cb_plan_line ""
    if [ -f "$cb_partial/inventory/bootfs.tsv" ]; then
        while IFS=$(printf '\t') read -r pool bootfs; do
            [ -n "${pool:-}" ] || continue
            if [ -n "$bootfs" ] && [ "$bootfs" != "-" ]; then
                cb_plan_line "zpool set bootfs=$(cb_sq "$bootfs") $(cb_sq "$pool")"
            fi
            cb_plan_line "zpool set cachefile=/mnt/boot/zfs/zpool.cache $(cb_sq "$pool")"
            if [ -n "$bootfs" ] && [ "$bootfs" != "-" ]; then
                cb_plan_line "zfs mount $(cb_sq "$bootfs")"
                cb_plan_line "# файлы корня должны быть видны в /mnt, потому что altroot=/mnt"
                cb_plan_line "# проверьте: test -f /mnt/etc/rc.conf && test -x /mnt/bin/sh"
            fi
            cb_plan_line "zpool export $(cb_sq "$pool")"
        done <"$cb_partial/inventory/bootfs.tsv"
    fi
    cb_plan_line "reboot"
    cb_plan_line ""
    cb_plan_line "5. Исключённые датасеты в поток не входили. Создайте их пустыми, если они нужны:"
    cb_plan_line ""
    if [ -s "$cb_partial/meta/excluded.tsv" ]; then
        while IFS=$(printf '\t') read -r pool dataset mp canmount origin; do
            [ -n "${dataset:-}" ] || continue
            opts=
            case ${mp:-} in
                ""|-|none) opts="-o mountpoint=none" ;;
                legacy) opts="-o mountpoint=legacy" ;;
                *) opts="-o mountpoint=$(cb_sq "$mp")" ;;
            esac
            case ${canmount:-} in
                ""|-|on) ;;
                *) opts="$opts -o canmount=$(cb_sq "$canmount")" ;;
            esac
            cb_plan_line "zfs create $opts $(cb_sq "$dataset")"
        done <"$cb_partial/meta/excluded.tsv"
    else
        cb_plan_line "# исключений не было"
    fi
    cb_plan_line ""
    cb_plan_line "6. UFS, если в бэкапе есть дампы"
    cb_plan_line ""
    if [ -f "$cb_partial/meta/ufs.tsv" ]; then
        comp=$(cb_meta_get "$cb_partial" compress)
        [ -n "$comp" ] || comp=$cb_compress
        enc=$(cb_meta_get "$cb_partial" encrypt)
        [ -n "$enc" ] || enc=$cb_encrypt
        dec=$(cb_decompress_cmd "$comp")
        ufs_any=0
        while IFS=$(printf '\t') read -r seq mp dev file; do
            [ -n "${seq:-}" ] || continue
            [ "$seq" = seq ] && continue
            ufs_any=1
            cb_plan_line "# $mp был на $dev. Смонтируйте свежий UFS, например в /mnt/ufs."
            if [ "$enc" = 1 ]; then
                cb_plan_line "openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/root/cifsbak.key -in $(cb_sq "$file") | $dec | (cd /mnt/ufs && restore -r -f -)"
            else
                cb_plan_line "$dec $(cb_sq "$file") | (cd /mnt/ufs && restore -r -f -)"
            fi
        done <"$cb_partial/meta/ufs.tsv"
        if [ "$ufs_any" = 0 ]; then
            cb_plan_line "# дампов UFS нет"
        fi
    else
        cb_plan_line "# дампов UFS нет"
    fi
    cb_plan_line ""
    cb_plan_line "После загрузки проверьте fstab, rc.conf и zpool status."
    cb_plan_line "Пароли и ключи хоста лежат внутри принятых датасетов: шара с бэкапом"
    cb_plan_line "так же секретна, как сама система."
}
