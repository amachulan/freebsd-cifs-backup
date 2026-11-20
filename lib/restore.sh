# Проверка, список и приём бэкапа. Приём никогда не монтирует датасеты (-u)
# и отказывается писать в пул, с которого загружена текущая система.

cb_try_implicit_store() {
    if [ -n "${opt_from_dir:-}" ]; then
        [ -d "$opt_from_dir" ] || cb_die "нет каталога $opt_from_dir"
        cb_hostdir=$(cb_abspath "$opt_from_dir")
        return 0
    fi
    iddir=$(dirname "$(dirname "$cb_self_dir")")
    if [ -f "$iddir/meta/backup.env" ]; then
        cb_hostdir=$(dirname "$iddir")
        if [ -z "${opt_id:-}" ]; then
            opt_id=$(basename "$iddir")
        fi
        return 0
    fi
    return 1
}

cb_open_for_read() {
    cb_begin
    if cb_try_implicit_store; then
        return 0
    fi
    cb_need_config
    cb_hostname=$(cb_compute_hostname)
    if [ ! -d "$cfg_destination" ]; then
        if [ "$cfg_cifs_mode" = mount ]; then
            cb_lock
            cb_ensure_destination
            cb_hostdir=$cfg_destination/$cb_hostname
            return 0
        fi
        cb_die "нет каталога $cfg_destination"
    fi
    if cb_is_mountpoint "$cfg_destination" || [ "$cfg_cifs_mode" = nomount ]; then
        cfg_destination=$(cb_abspath "$cfg_destination")
        cb_hostdir=$cfg_destination/$cb_hostname
        return 0
    fi
    cb_lock
    cb_ensure_destination
    cb_hostdir=$cfg_destination/$cb_hostname
}

cb_open_for_write() {
    cb_begin
    cb_require_root
    implicit=0
    if cb_try_implicit_store; then
        implicit=1
    fi
    if [ -n "${opt_config:-}" ] || [ "$implicit" = 0 ]; then
        cb_need_config
    fi
    cb_lock
    if [ "$implicit" = 0 ]; then
        cb_hostname=$(cb_compute_hostname)
        cb_ensure_destination
        cb_hostdir=$cfg_destination/$cb_hostname
    fi
}

cb_select_id() {
    if [ -n "${opt_id:-}" ]; then
        cb_valid_id "$opt_id" || cb_die "странный id: $opt_id"
        [ -d "$cb_hostdir/$opt_id" ] || cb_die "нет бэкапа $opt_id"
        printf '%s\n' "$opt_id"
        return 0
    fi
    if [ -f "$cb_hostdir/LATEST" ]; then
        id=$(tr -d '[:space:]' <"$cb_hostdir/LATEST")
        cb_valid_id "$id" || cb_die "LATEST содержит странный id"
        [ -d "$cb_hostdir/$id" ] || cb_die "LATEST указывает на отсутствующий каталог $id"
        printf '%s\n' "$id"
        return 0
    fi
    id=$(cb_newest_id "$cb_hostdir")
    [ -n "$id" ] || cb_die "бэкапов нет"
    printf '%s\n' "$id"
}

cb_chain_pools() {
    id=$1
    cb_chain_oldest_first "$cb_hostdir" "$id" >"$cb_runtime/chain-ids"
    while IFS= read -r bid; do
        [ -n "$bid" ] || continue
        streams=$cb_hostdir/$bid/meta/streams.tsv
        [ -f "$streams" ] || continue
        awk -F '\t' 'NR > 1 && NF >= 2 { print $2 }' "$streams"
    done <"$cb_runtime/chain-ids" | awk 'NF && !seen[$0]++'
}

cb_pick_from_pool() {
    id=$1
    pools=$(cb_chain_pools "$id")
    if [ -n "${opt_from:-}" ]; then
        printf '%s\n' "$pools" | grep -Fxq "$opt_from" || cb_die "в бэкапе нет пула $opt_from"
        printf '%s\n' "$opt_from"
        return 0
    fi
    count=$(printf '%s\n' "$pools" | awk 'NF { n++ } END { print n+0 }')
    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$pools"
        return 0
    fi
    if [ "$count" -eq 0 ]; then
        cb_die "в бэкапе нет потоков ZFS"
    fi
    cb_die "в бэкапе несколько пулов, укажите --from: $(printf '%s' "$pools" | tr '\n' ' ')"
}

cb_live_pool() {
    if ! zfs list -H -o name -- / >/dev/null 2>&1; then
        return 0
    fi
    ds=$(zfs list -H -o name -- / 2>/dev/null || true)
    [ -n "$ds" ] || return 0
    printf '%s\n' "${ds%%/*}"
}

cb_assert_restore_target() {
    to=$1
    cb_assert_pool "$to"
    if [ "$to" = cifsbakdrill ] && [ "${cb_drill_active:-0}" != 1 ]; then
        cb_die "имя cifsbakdrill занято пробным восстановлением"
    fi
    if ! zpool list -H -o name -- "$to" >/dev/null 2>&1; then
        cb_die "пул $to не импортирован. С установочного носителя: zpool import -N -R /mnt $to"
    fi
    live=$(cb_live_pool || true)
    if [ -n "$live" ] && [ "$live" = "$to" ]; then
        cb_die "пул $to сейчас держит корень системы. Восстанавливайте с установочного носителя или проверьте копию командой cifsbak drill"
    fi
    alt=$(zpool get -H -o value altroot -- "$to" 2>/dev/null || true)
    case $alt in
        /*) ;;
        *) cb_die "у пула $to не задан altroot (${alt:-пусто}). Импортируйте его так: zpool export $to && zpool import -N -R /mnt $to" ;;
    esac
}

cb_verify_tree() {
    id=$1
    dir=$cb_hostdir/$id
    [ -f "$dir/MANIFEST" ] || cb_die "в $id нет MANIFEST"
    [ -f "$dir/MANIFEST.sha256" ] || cb_die "в $id нет MANIFEST.sha256"
    expected=$(awk 'NR == 1 { print $1 }' "$dir/MANIFEST.sha256")
    actual=$(cb_sha256 "$dir/MANIFEST")
    if [ "$expected" != "$actual" ]; then
        cb_die "контрольная сумма MANIFEST не сходится в $id"
    fi
    while read -r hash path; do
        [ -n "$hash" ] || continue
        if [ ! -f "$dir/$path" ]; then
            cb_die "в $id нет файла $path"
        fi
        got=$(cb_sha256 "$dir/$path")
        if [ "$got" != "$hash" ]; then
            cb_die "контрольная сумма не сходится: $id/$path"
        fi
    done <"$dir/MANIFEST"
}

cb_verify_payload() {
    id=$1
    dir=$cb_hostdir/$id
    enc=$(cb_meta_get "$dir" encrypt)
    comp=$(cb_meta_get "$dir" compress)
    [ -n "$comp" ] || cb_die "в $id не записано сжатие"
    key=-
    if [ "$enc" = 1 ]; then
        if ! key=$(cb_active_keyfile); then
            cb_log warn "полезную нагрузку $id не расшифровывал: нет ключа"
            cb_verify_skipped_payload=1
            return 0
        fi
    fi
    if ! cb_have zstream; then
        cb_log warn "zstream нет, содержимое потоков не разобрано (суммы файлов проверены)"
        return 0
    fi
    streams=$dir/meta/streams.tsv
    [ -f "$streams" ] || return 0
    while IFS=$(printf '\t') read -r seq pool dataset kind parent snap raw file; do
        [ -n "${seq:-}" ] || continue
        [ "$seq" = seq ] && continue
        cb_log info "разбираю поток $id $dataset"
        if ! cb_pipe_decoded "$dir/$file" "$comp" "$key" -- zstream dump; then
            cb_die "поток $id $file не читается"
        fi
    done <"$streams"
}

cb_cmd_verify() {
    cb_job=verify
    cb_open_for_read
    id=$(cb_select_id)
    cb_verify_skipped_payload=0
    cb_chain_oldest_first "$cb_hostdir" "$id" >"$cb_runtime/verify-chain"
    while IFS= read -r bid; do
        [ -n "$bid" ] || continue
        cb_verify_tree "$bid"
        cb_verify_payload "$bid"
    done <"$cb_runtime/verify-chain"
    if [ "$cb_verify_skipped_payload" = 1 ]; then
        printf 'OK %s (файлы целы, потоки не расшифрованы)\n' "$id"
    else
        printf 'OK %s\n' "$id"
    fi
}

cb_cmd_list() {
    cb_job=list
    cb_open_for_read
    if [ ! -d "$cb_hostdir" ]; then
        printf 'бэкапов нет\n'
        return 0
    fi
    printf '%-18s %-6s %-28s %10s %s\n' "ID" "РЕЖИМ" "СНИМОК" "КБ" "РОДИТЕЛЬ"
    cb_list_ids "$cb_hostdir" | sort -r >"$cb_runtime/list-ids"
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        mode=$(cb_meta_get "$cb_hostdir/$id" mode)
        snap=$(cb_meta_get "$cb_hostdir/$id" snap)
        parent=$(cb_meta_get "$cb_hostdir/$id" parent_id)
        [ -n "$parent" ] || parent=-
        kb=$(du -sk "$cb_hostdir/$id" 2>/dev/null | awk '{print $1}')
        printf '%-18s %-6s %-28s %10s %s\n' "$id" "${mode:--}" "${snap:--}" "${kb:-0}" "$parent"
    done <"$cb_runtime/list-ids"
}

cb_cmd_plan() {
    cb_job=plan
    cb_open_for_read
    id=$(cb_select_id)
    if [ -f "$cb_hostdir/$id/RESTORE.txt" ]; then
        cat "$cb_hostdir/$id/RESTORE.txt"
        return 0
    fi
    cb_die "в $id нет RESTORE.txt"
}

cb_replay() {
    target_id=$1
    from_pool=$2
    to_pool=$3
    cb_assert_restore_target "$to_pool"
    cb_chain_oldest_first "$cb_hostdir" "$target_id" >"$cb_runtime/replay-chain"
    while IFS= read -r bid; do
        [ -n "$bid" ] || continue
        dir=$cb_hostdir/$bid
        comp=$(cb_meta_get "$dir" compress)
        enc=$(cb_meta_get "$dir" encrypt)
        [ -n "$comp" ] || cb_die "в $bid не записано сжатие"
        key=-
        if [ "$enc" = 1 ]; then
            key=$(cb_active_keyfile) || cb_die "бэкап $bid зашифрован, укажите --keyfile"
        fi
        streams=$dir/meta/streams.tsv
        [ -f "$streams" ] || cb_die "в $bid нет списка потоков"
        while IFS=$(printf '\t') read -r seq pool dataset kind parent snap raw file; do
            [ -n "${seq:-}" ] || continue
            [ "$seq" = seq ] && continue
            [ "$pool" = "$from_pool" ] || continue
            dest=$(cb_rehome "$dataset" "$to_pool")
            cb_log info "приём $bid $dataset -> $dest"
            if ! cb_pipe_decoded "$dir/$file" "$comp" "$key" -- zfs receive -u -F -v -- "$dest"; then
                cb_die "приём $dataset не удался. Пул $to_pool оставлен как есть, цепочка оборвалась на $bid"
            fi
            if ! zfs list -H -o name -t snapshot -- "$dest@$snap" >/dev/null 2>&1; then
                cb_die "после приёма нет снимка $dest@$snap"
            fi
        done <"$streams"
    done <"$cb_runtime/replay-chain"
}

cb_cmd_restore() {
    cb_job=restore
    [ "${opt_yes:-0}" = 1 ] || cb_die "восстановление переписывает датасеты пула. Добавьте --yes, когда пул импортирован с altroot"
    cb_open_for_write
    id=$(cb_select_id)
    from=$(cb_pick_from_pool "$id")
    to=${opt_to:-$from}
    cb_log info "восстановление $id: $from -> $to"
    cb_replay "$id" "$from" "$to"
    printf 'cifsbak восстановлен %s в пул %s\n' "$id" "$to"
}

cb_bootfs_of() {
    id=$1
    pool=$2
    file=$cb_hostdir/$id/inventory/bootfs.tsv
    [ -f "$file" ] || return 0
    awk -F '\t' -v p="$pool" '$1 == p { print $2; exit }' "$file"
}

cb_cmd_drill() {
    cb_job=drill
    [ "${opt_yes:-0}" = 1 ] || cb_die "drill создаёт временный пул и требует свободное место. Добавьте --yes"
    cb_open_for_write
    id=$(cb_select_id)
    from=$(cb_pick_from_pool "$id")
    mkdir -p -- "$cfg_drill_dir" || cb_die "не создать $cfg_drill_dir"
    need_kb=$((cfg_drill_size_gb * 1024 * 1024))
    avail=$(cb_free_kb "$cfg_drill_dir")
    case ${avail:-} in
        ''|*[!0-9]*|0) cb_log warn "не проверяю свободное место под drill" ;;
        *)
            if [ "$avail" -lt "$need_kb" ]; then
                cb_die "для drill нужно около ${cfg_drill_size_gb} ГиБ в $cfg_drill_dir, свободно ${avail} КБ"
            fi
            ;;
    esac
    cb_drill_alt=$(mktemp -d "$cfg_drill_dir/cifsbak-drill-mnt.XXXXXX")
    cb_drill_image=$cfg_drill_dir/cifsbak-drill-$$.img
    truncate -s "${cfg_drill_size_gb}G" "$cb_drill_image" || cb_die "не удалось создать $cb_drill_image"
    cb_drill_active=1
    ashift=$(awk -F '\t' -v p="$from" 'NR > 1 && $1 == p { print $2; exit }' \
        "$cb_hostdir/$id/inventory/poolprops.tsv" 2>/dev/null || true)
    case ${ashift:-} in
        ''|0|*[!0-9]*) ashift=12 ;;
    esac
    cb_log info "пробный пул cifsbakdrill на $cb_drill_image, altroot $cb_drill_alt"
    zpool create -o cachefile=none -o "ashift=$ashift" -R "$cb_drill_alt" \
        -O mountpoint=none -O canmount=off cifsbakdrill "$cb_drill_image" \
        || cb_die "zpool create для drill не удался"
    cb_replay "$id" "$from" cifsbakdrill
    boot=$(cb_bootfs_of "$id" "$from")
    if [ -n "$boot" ] && [ "$boot" != "-" ]; then
        mapped=$(cb_rehome "$boot" cifsbakdrill)
        alt=$(zpool get -H -o value altroot -- cifsbakdrill)
        case $alt in
            /*) ;;
            *) cb_die "drill: altroot не задан" ;;
        esac
        zfs mount -- "$mapped" || cb_die "не смонтировался $mapped"
        if [ ! -f "$cb_drill_alt/etc/rc.conf" ] && [ ! -x "$cb_drill_alt/bin/sh" ] && [ ! -f "$cb_drill_alt/boot/loader.conf" ]; then
            cb_die "drill: после приёма в $cb_drill_alt нет /etc/rc.conf, /bin/sh или /boot/loader.conf"
        fi
    fi
    printf 'cifsbak drill OK %s пул %s\n' "$id" "$from"
    cb_log info "пробное восстановление прошло, временный пул будет удалён"
}

cb_cmd_restore_ufs() {
    cb_job=restore
    [ "${opt_yes:-0}" = 1 ] || cb_die "restore-ufs распаковывает дамп в каталог. Добавьте --yes"
    [ -n "${opt_target:-}" ] || cb_die "нужен --target, каталог смонтированного UFS"
    [ -n "${opt_mountpoint:-}" ] || cb_die "нужен --mountpoint, исходная точка из бэкапа, например / или /var"
    [ "$opt_target" != / ] || cb_die "отказ распаковывать дамп в /"
    case $opt_target in
        /*) ;;
        *) cb_die "--target должен быть абсолютным путём" ;;
    esac
    [ -d "$opt_target" ] || cb_die "нет каталога $opt_target"
    if [ "${CIFSBAK_ALLOW_NONROOT:-}" != 1 ]; then
        rootfs=$(df -P / | awk 'NR == 2 { print $1 }')
        tgtfs=$(df -P "$opt_target" | awk 'NR == 2 { print $1 }')
        if [ "$rootfs" = "$tgtfs" ]; then
            cb_die "$opt_target находится на корневой файловой системе. Смонтируйте отдельный UFS"
        fi
    fi
    cb_open_for_write
    id=$(cb_select_id)
    dir=$cb_hostdir/$id
    comp=$(cb_meta_get "$dir" compress)
    enc=$(cb_meta_get "$dir" encrypt)
    key=-
    if [ "$enc" = 1 ]; then
        key=$(cb_active_keyfile) || cb_die "дамп зашифрован, укажите --keyfile"
    fi
    found=
    while IFS=$(printf '\t') read -r seq mp dev file; do
        [ -n "${seq:-}" ] || continue
        [ "$seq" = seq ] && continue
        if [ "$mp" = "$opt_mountpoint" ]; then
            found=$file
            break
        fi
    done <"$dir/meta/ufs.tsv"
    [ -n "$found" ] || cb_die "в $id нет дампа UFS для $opt_mountpoint"
    cb_log info "распаковка $found в $opt_target"
    if ! cb_pipe_decoded "$dir/$found" "$comp" "$key" -- sh -c 'cd "$1" && exec restore -r -f -' sh "$opt_target"; then
        cb_die "restore не смог распаковать $opt_mountpoint"
    fi
    printf 'cifsbak UFS %s распакован в %s\n' "$opt_mountpoint" "$opt_target"
}

cb_cmd_prune() {
    cb_job=prune
    cb_begin
    cb_require_root
    cb_need_config
    cb_hostname=$(cb_compute_hostname)
    cb_lock
    cb_ensure_destination
    cb_hostdir=$cfg_destination/$cb_hostname
    mkdir -p -- "$cb_hostdir"
    cb_prune_dest
    printf 'cifsbak prune OK\n'
}

cb_cmd_doctor() {
    cb_job=doctor
    cb_begin
    cb_require_root
    cb_need_config
    cb_hostname=$(cb_compute_hostname)
    fail=0
    printf 'хост: %s\n' "$cb_hostname"
    printf 'назначение: %s\n' "$cfg_destination"
    printf 'режим шары: %s\n' "$cfg_cifs_mode"
    printf 'режим копии: %s\n' "$cfg_backup_mode"
    comp=$(cb_pick_compress)
    if cb_compress_available "$comp"; then
        printf 'сжатие: %s\n' "$comp"
    else
        printf 'ОШИБКА: нет программы для сжатия %s\n' "$comp"
        fail=1
    fi
    if [ -n "$cfg_encrypt_keyfile" ]; then
        if cb_have openssl; then
            printf 'шифрование: openssl aes-256-cbc\n'
        else
            printf 'ОШИБКА: для шифрования нужен openssl\n'
            fail=1
        fi
    else
        printf 'шифрование: выключено\n'
    fi
    if [ "$cfg_cifs_mode" = mount ]; then
        if cb_have mount_smbfs; then
            printf 'mount_smbfs: есть, шара //%s@%s/%s\n' "$cfg_cifs_user" "$cfg_cifs_host" "$cfg_cifs_share"
        else
            printf 'ОШИБКА: нет mount_smbfs\n'
            fail=1
        fi
    elif [ -d "$cfg_destination" ]; then
        probe=$cfg_destination/.cifsbak-write-test.$$
        if : >"$probe" 2>/dev/null; then
            rm -f -- "$probe"
            printf 'запись в назначение: да\n'
        else
            printf 'ОШИБКА: нет права записи в %s\n' "$cfg_destination"
            fail=1
        fi
    else
        printf 'ОШИБКА: нет каталога %s\n' "$cfg_destination"
        fail=1
    fi
    if cb_have zpool && cb_have zfs; then
        cb_discover_pools
        printf 'пулы:'
        if [ -s "$cb_pools_file" ]; then
            printf ' %s' $(cat "$cb_pools_file")
            printf '\n'
        else
            printf ' нет\n'
        fi
        if [ -s "$cfg_exclude_file" ]; then
            printf 'исключения:'
            while IFS= read -r ex; do
                [ -n "$ex" ] && printf ' %s' "$ex"
            done <"$cfg_exclude_file"
            printf '\n'
        fi
    else
        printf 'ZFS: zpool или zfs не найдены, будут только дампы UFS\n'
    fi
    if ! cb_have gpart; then
        printf 'предупреждение: нет gpart, разметка диска в бэкап не попадёт\n'
    fi
    if [ "$fail" -ne 0 ]; then
        cb_die "проверка не пройдена"
    fi
    printf 'можно запускать cifsbak backup\n'
}
