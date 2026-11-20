# Съёмка бэкапа. Снимок ZFS атомарный на пул, отправка идёт уже со снимка,
# поэтому длинная запись на шару не размазывает состояние системы.

cb_mount_cifs() {
    cb_require_root
    cb_have mount_smbfs || cb_die "нет mount_smbfs. На FreeBSD это базовая программа; без неё смонтируйте шару сами и поставьте cifs_mode=nomount"
    pass=$(cb_cifs_password)
    host_uc=$(printf '%s' "$cfg_cifs_host" | tr '[:lower:]' '[:upper:]')
    cb_privhome=$(mktemp -d /tmp/cifsbak.XXXXXX)
    chmod 700 "$cb_privhome"
    {
        printf '[%s:%s]\n' "$host_uc" "$cfg_cifs_user"
        printf 'addr=%s\n' "$cfg_cifs_host"
        printf 'password=%s\n' "$pass"
        if [ -n "$cfg_cifs_workgroup" ]; then
            printf 'workgroup=%s\n' "$cfg_cifs_workgroup"
        fi
    } >"$cb_privhome/.nsmbrc"
    chmod 600 "$cb_privhome/.nsmbrc"
    unc="//${cfg_cifs_user}@${host_uc}/${cfg_cifs_share}"
    cb_log info "монтирую $unc в $cfg_destination"
    if [ -n "$cfg_cifs_workgroup" ]; then
        HOME=$cb_privhome mount_smbfs -N -I "$cfg_cifs_host" -u 0 -g 0 -f 0600 -d 0700 \
            -W "$cfg_cifs_workgroup" "$unc" "$cfg_destination" || cb_die "mount_smbfs не смог подключить $unc"
    else
        HOME=$cb_privhome mount_smbfs -N -I "$cfg_cifs_host" -u 0 -g 0 -f 0600 -d 0700 \
            "$unc" "$cfg_destination" || cb_die "mount_smbfs не смог подключить $unc"
    fi
    if ! mount | grep -F " on ${cfg_destination} " >/dev/null 2>&1; then
        cb_die "mount_smbfs завершился, но $cfg_destination нет в списке mount"
    fi
    cb_mounted_by_us=1
}

cb_ensure_destination() {
    mkdir -p -- "$cfg_destination" || cb_die "не создать $cfg_destination"
    cfg_destination=$(cb_abspath "$cfg_destination")
    if cb_is_mountpoint "$cfg_destination"; then
        cb_mounted_by_us=0
        cb_log info "назначение уже смонтировано: $cfg_destination"
    elif [ "$cfg_cifs_mode" = mount ]; then
        cb_mount_cifs
    fi
    probe=$cfg_destination/.cifsbak-write-test.$$
    if ! : >"$probe" 2>/dev/null; then
        cb_die "нет права записи в $cfg_destination"
    fi
    rm -f -- "$probe"
}

cb_check_space() {
    [ "${cfg_min_free_mb:-0}" -eq 0 ] && return 0
    avail=$(cb_free_kb "$cfg_destination")
    case ${avail:-} in
        ''|*[!0-9]*)
            cb_log warn "не понял, сколько места свободно, продолжаю"
            ;;
        0)
            cb_log warn "сервер сообщил 0 КБ свободно. Если шара так врёт о квоте, поставьте min_free_mb=0"
            ;;
        *)
            need=$((cfg_min_free_mb * 1024))
            if [ "$avail" -lt "$need" ]; then
                cb_die "на назначении свободно ${avail} КБ, нужно минимум ${need} КБ (min_free_mb)"
            fi
            ;;
    esac
}

cb_check_same_pool() {
    fs=$(df -P "$cfg_destination" 2>/dev/null | awk 'NR==2 {print $1}')
    [ -n "$fs" ] || return 0
    while IFS= read -r pool; do
        [ -n "$pool" ] || continue
        if cb_fs_on_pool "$fs" "$pool"; then
            if [ "$cfg_allow_same_pool" != yes ]; then
                cb_die "каталог назначения лежит на пуле $pool ($fs). Бэкап заполнит диск, который вы сохраняете. Укажите шару или явно allow_same_pool=yes"
            fi
            cb_log warn "назначение находится на пуле $pool"
        fi
    done <"$cb_pools_file"
}

cb_decide_mode() {
    cb_run_mode=full
    cb_parent_snap=
    cb_parent_id=
    cb_base_id=
    if [ "${opt_full:-0}" = 1 ] || [ "$cfg_backup_mode" = full ]; then
        cb_log info "режим: полный"
        return 0
    fi
    newest=$(cb_newest_id "$cb_hostdir" || true)
    if [ -z "$newest" ]; then
        cb_log info "прошлых бэкапов нет, будет полный"
        return 0
    fi
    parent_snap=$(cb_meta_get "$cb_hostdir/$newest" snap)
    base=$(cb_meta_get "$cb_hostdir/$newest" base_id)
    [ -n "$base" ] || base=$newest
    created=$(cb_meta_get "$cb_hostdir/$base" created_epoch)
    if [ -z "$parent_snap" ] || [ -z "$created" ] || ! cb_is_uint "$created"; then
        cb_log warn "у $newest нет данных для инкремента, будет полный"
        return 0
    fi
    now=$(cb_epoch)
    age_days=$(( (now - created) / 86400 ))
    if [ "$age_days" -ge "$cfg_full_every_days" ]; then
        cb_log info "последний полный бэкап старше ${cfg_full_every_days} дн. (прошло $age_days), будет полный"
        return 0
    fi
    while IFS= read -r pool; do
        [ -n "$pool" ] || continue
        if ! zfs list -H -o name -t snapshot -- "$pool@$parent_snap" >/dev/null 2>&1; then
            cb_log warn "снимка $pool@$parent_snap уже нет, будет полный"
            return 0
        fi
    done <"$cb_pools_file"
    cb_run_mode=incr
    cb_parent_snap=$parent_snap
    cb_parent_id=$newest
    cb_base_id=$base
    cb_log info "режим: инкремент от $newest ($parent_snap)"
}

cb_snapshot_pools() {
    cb_snap="${cfg_snapshot_prefix}-${cb_id}"
    : >"$cb_runtime/snapped-pools"
    if [ "$(cb_pool_count)" -eq 0 ]; then
        return 0
    fi
    cb_snap_rollback=1
    while IFS= read -r pool; do
        [ -n "$pool" ] || continue
        cb_log info "снимок $pool@$cb_snap"
        cb_nice_cmd zfs snapshot -r -- "$pool@$cb_snap" || cb_die "не удалось снять $pool@$cb_snap"
        printf '%s\n' "$pool" >>"$cb_runtime/snapped-pools"
        if ! zfs hold -r -- "$cfg_snapshot_prefix" "$pool@$cb_snap"; then
            cb_log warn "hold не поставлен на $pool@$cb_snap"
        fi
    done <"$cb_pools_file"
}

cb_rollback_snapshots() {
    [ "${cb_snap_rollback:-0}" = 1 ] || return 0
    [ -n "${cb_snap:-}" ] || return 0
    [ -n "${cb_runtime:-}" ] || return 0
    [ -f "$cb_runtime/snapped-pools" ] || return 0
    while IFS= read -r pool; do
        [ -n "$pool" ] || continue
        zfs release -r -- "${cfg_snapshot_prefix:-cifsbak}" "$pool@$cb_snap" >/dev/null 2>&1 || true
        if ! zfs destroy -r -- "$pool@$cb_snap" >/dev/null 2>&1; then
            cb_log warn "не смог откатить снимок $pool@$cb_snap"
        fi
    done <"$cb_runtime/snapped-pools"
    cb_snap_rollback=0
}

cb_run_send() {
    if [ "$send_raw" = 1 ] && [ -n "$send_parent" ]; then
        cb_nice_cmd zfs send -v -w -p -i "$send_ds@$send_parent" -- "$send_ds@$cb_snap"
    elif [ "$send_raw" = 1 ]; then
        cb_nice_cmd zfs send -v -w -p -- "$send_ds@$cb_snap"
    elif [ -n "$send_parent" ]; then
        cb_nice_cmd zfs send -v -p -i "$send_ds@$send_parent" -- "$send_ds@$cb_snap"
    else
        cb_nice_cmd zfs send -v -p -- "$send_ds@$cb_snap"
    fi
}

cb_send_datasets() {
    printf 'seq\tpool\tdataset\tkind\tparent_snap\tsnap\traw\tfile\n' >"$cb_partial/meta/streams.tsv"
    n=0
    while IFS=$(printf '\t') read -r pool dataset mp enc origin canmount; do
        [ -n "${dataset:-}" ] || continue
        if ! zfs list -H -o name -t snapshot -- "$dataset@$cb_snap" >/dev/null 2>&1; then
            cb_log warn "пропускаю $dataset: снимка $cb_snap нет (датасет появился после снимка)"
            continue
        fi
        send_parent=
        kind=full
        if [ "$cb_run_mode" = incr ] && [ -n "$cb_parent_snap" ]; then
            if zfs list -H -o name -t snapshot -- "$dataset@$cb_parent_snap" >/dev/null 2>&1; then
                kind=incr
                send_parent=$cb_parent_snap
            else
                cb_log info "$dataset нет на снимке $cb_parent_snap, отправляю целиком"
            fi
        fi
        send_raw=0
        case ${enc:-off} in
            ""|off|-) send_raw=0 ;;
            *) send_raw=1 ;;
        esac
        n=$((n + 1))
        seq=$(printf '%04d' "$n")
        ext=$(cb_ext_for "$cb_compress" "$cb_encrypt")
        rel="zfs/$seq.$ext"
        send_ds=$dataset
        cb_log info "отправка $dataset ($kind)"
        ok=0
        attempt=1
        while [ "$attempt" -le "$cfg_send_attempts" ]; do
            if cb_produce_file "$cb_partial/$rel" "$cb_compress" "$cb_keyflag" -- cb_run_send; then
                ok=1
                break
            fi
            cb_log warn "попытка $attempt не удалась: $dataset"
            attempt=$((attempt + 1))
        done
        [ "$ok" = 1 ] || cb_die "отправка $dataset не удалась"
        # Пустое поле в TSV схлопывается при read: «-» значит «родителя нет».
        case $send_parent in
            "") parent_col=- ;;
            *) parent_col=$send_parent ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$seq" "$pool" "$dataset" "$kind" "$parent_col" "$cb_snap" "$send_raw" "$rel" \
            >>"$cb_partial/meta/streams.tsv"
    done <"$cb_included"
    cb_zfs_count=$n
}

cb_dump_one_ufs() {
    cb_nice_cmd dump $dump_flags -f - "$dump_mp"
}

cb_dump_ufs() {
    printf 'seq\tmountpoint\tdevice\tfile\n' >"$cb_partial/meta/ufs.tsv"
    cb_ufs_count=0
    if ! mount -p >"$cb_runtime/mount-p" 2>"$cb_runtime/mount-p.err"; then
        cb_log warn "mount -p не удался, UFS не сохраняю"
        return 0
    fi
    cb_list_ufs "$cb_runtime/mount-p" >"$cb_runtime/ufs.list"
    n=0
    while IFS=$(printf '\t') read -r dev mp; do
        [ -n "${mp:-}" ] || continue
        n=$((n + 1))
        seq=$(printf '%04d' "$n")
        ext=$(cb_ext_for "$cb_compress" "$cb_encrypt")
        rel="ufs/$seq.$ext"
        dump_mp=$mp
        cb_log info "дамп UFS $mp ($dev)"
        ok=0
        attempt=1
        while [ "$attempt" -le "$cfg_send_attempts" ]; do
            dump_flags="-0aL"
            if cb_produce_file "$cb_partial/$rel" "$cb_compress" "$cb_keyflag" -- cb_dump_one_ufs; then
                ok=1
                break
            fi
            cb_log warn "dump -L не удался для $mp, повторяю без снимка UFS"
            dump_flags="-0a"
            if cb_produce_file "$cb_partial/$rel" "$cb_compress" "$cb_keyflag" -- cb_dump_one_ufs; then
                ok=1
                break
            fi
            attempt=$((attempt + 1))
        done
        [ "$ok" = 1 ] || cb_die "дамп $mp не удался"
        printf '%s\t%s\t%s\t%s\n' "$seq" "$mp" "$dev" "$rel" >>"$cb_partial/meta/ufs.tsv"
    done <"$cb_runtime/ufs.list"
    cb_ufs_count=$n
}

cb_copy_tool() {
    mkdir -p "$cb_partial/tool/bin" "$cb_partial/tool/lib"
    cp -- "$cb_self" "$cb_partial/tool/bin/cifsbak"
    cp -- "$cb_lib"/*.sh "$cb_partial/tool/lib/"
    chmod 755 "$cb_partial/tool/bin/cifsbak"
    chmod 644 "$cb_partial/tool/lib/"*.sh
}

cb_write_env() {
    if [ "$cb_run_mode" = full ]; then
        base=$cb_id
        parent_id=
        parent_snap=
    else
        base=$cb_base_id
        parent_id=$cb_parent_id
        parent_snap=$cb_parent_snap
    fi
    cat >"$cb_partial/meta/backup.env" <<EOF
tool_version=${CB_VERSION}
backup_id=${cb_id}
created_epoch=$(cb_epoch)
host=${cb_hostname}
mode=${cb_run_mode}
base_id=${base}
parent_id=${parent_id}
parent_snap=${parent_snap}
snap=${cb_snap}
compress=${cb_compress}
encrypt=${cb_encrypt}
EOF
}

cb_write_manifest() {
    list=$cb_runtime/files
    (
        cd "$cb_partial" && find . -type f ! -name MANIFEST ! -name MANIFEST.sha256 -print
    ) | sed 's|^\./||' | sort >"$list"
    : >"$cb_partial/MANIFEST"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        hash=$(cb_sha256 "$cb_partial/$rel")
        printf '%s  %s\n' "$hash" "$rel" >>"$cb_partial/MANIFEST"
    done <"$list"
    hash=$(cb_sha256 "$cb_partial/MANIFEST")
    printf '%s  %s\n' "$hash" MANIFEST >"$cb_partial/MANIFEST.sha256"
}

cb_prune_source_snaps() {
    [ "$(cb_pool_count)" -gt 0 ] || return 0
    [ -n "${cb_snap:-}" ] || return 0
    keep=$cfg_keep_source_snapshots
    while IFS= read -r pool; do
        [ -n "$pool" ] || continue
        list=$cb_runtime/snaps-$pool
        if ! zfs list -H -t snapshot -o name -r -- "$pool" >"$list" 2>>"$cb_logfile"; then
            cb_log warn "не смог перечислить снимки $pool"
            continue
        fi
        names=$cb_runtime/snapnames-$pool
        awk -F@ -v p="$cfg_snapshot_prefix" '
            {
                n = $0
                ds = $1
                snap = $2
                if (index(snap, p "-") == 1) print snap
            }
        ' "$list" | sort -u >"$names"
        total=$(awk 'END {print NR+0}' "$names")
        idx=0
        while IFS= read -r snapname; do
            [ -n "$snapname" ] || continue
            idx=$((idx + 1))
            drop=1
            if [ "$idx" -gt $((total - keep)) ]; then
                drop=0
            fi
            if [ "$snapname" = "$cb_snap" ]; then
                drop=0
            fi
            if [ -n "${cb_parent_snap:-}" ] && [ "$snapname" = "$cb_parent_snap" ]; then
                drop=0
            fi
            if [ "$drop" = 1 ]; then
                cb_log info "удаляю старый снимок $pool@$snapname"
                zfs release -r -- "$cfg_snapshot_prefix" "$pool@$snapname" >/dev/null 2>&1 || true
                if ! zfs destroy -r -- "$pool@$snapname"; then
                    cb_log warn "не удалился снимок $pool@$snapname"
                fi
            fi
        done <"$names"
    done <"$cb_pools_file"
}

cb_chain_oldest_first() {
    hostdir=$1
    id=$2
    acc=
    steps=0
    cur=$id
    nl='
'
    while [ -n "$cur" ]; do
        steps=$((steps + 1))
        [ "$steps" -le 10000 ] || cb_die "цикл в цепочке бэкапов у $cur"
        cb_valid_id "$cur" || cb_die "битый id в цепочке: $cur"
        [ -d "$hostdir/$cur" ] || cb_die "в цепочке нет каталога $cur"
        if [ -z "$acc" ]; then
            acc=$cur
        else
            acc="$cur$nl$acc"
        fi
        cur=$(cb_meta_get "$hostdir/$cur" parent_id)
    done
    printf '%s\n' "$acc"
}

cb_ids_to_keep() {
    hostdir=$1
    keep=$2
    ids=$(cb_list_ids "$hostdir" | sort -r | awk -v n="$keep" 'NR <= n')
    required=
    nl='
'
    for id in $ids; do
        chain=$(cb_chain_oldest_first "$hostdir" "$id")
        required="${required}${nl}${chain}"
    done
    printf '%s\n' "$required" | awk 'NF && !seen[$0]++'
}

cb_rm_backup() {
    id=$1
    cb_valid_id "$id" || cb_die "отказ удалять странный id: $id"
    dir=$cb_hostdir/$id
    case $dir in
        /*/*/*) ;;
        *) cb_die "странный путь бэкапа: $dir" ;;
    esac
    if [ -L "$dir" ]; then
        cb_die "отказ удалять ссылку: $dir"
    fi
    [ -d "$dir" ] || return 0
    rm -rf -- "$dir"
}

cb_prune_dest() {
    [ -d "$cb_hostdir" ] || return 0
    required=$(cb_ids_to_keep "$cb_hostdir" "$cfg_keep_copies")
    cb_list_ids "$cb_hostdir" >"$cb_runtime/all-ids"
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        if printf '%s\n' "$required" | grep -Fxq "$id"; then
            continue
        fi
        cb_log info "удаляю старый бэкап $id"
        cb_rm_backup "$id"
    done <"$cb_runtime/all-ids"
}

cb_clean_partials() {
    for p in "$cb_hostdir"/.partial.*; do
        [ -e "$p" ] || continue
        cb_log warn "удаляю незавершённый каталог $p"
        cb_rm_partial "$p"
    done
}

cb_prepare_partial() {
    cb_hostdir=$cfg_destination/$cb_hostname
    mkdir -p -- "$cb_hostdir" || cb_die "не создать $cb_hostdir"
    cb_clean_partials
    if [ -e "$cb_hostdir/$cb_id" ]; then
        cb_die "бэкап $cb_id уже существует"
    fi
    cb_partial=$cb_hostdir/.partial.$$
    mkdir -p "$cb_partial/meta" "$cb_partial/zfs" "$cb_partial/ufs" \
        "$cb_partial/inventory" "$cb_partial/tool/bin" "$cb_partial/tool/lib"
}

cb_dry_run() {
    cb_log info "сухой прогон, снимок не снимается"
    if [ -d "$cfg_destination" ]; then
        cfg_destination=$(cb_abspath "$cfg_destination")
    fi
    cb_hostdir=$cfg_destination/$cb_hostname
    cb_discover_pools
    if [ -d "$cb_hostdir" ] && { [ "$cfg_cifs_mode" = nomount ] || cb_is_mountpoint "$cfg_destination"; }; then
        cb_decide_mode
    else
        cb_run_mode=full
        cb_log info "шара не смонтирована, прошлые бэкапы не видны, считаю бэкап полным"
    fi
    if [ "$(cb_pool_count)" -gt 0 ] && cb_have zfs; then
        cb_snap=dry
        cb_enumerate_pools || true
    fi
    printf 'сухой прогон: %s\n' "$cb_run_mode"
    printf 'хост: %s\n' "$cb_hostname"
    printf 'назначение: %s\n' "$cfg_destination"
    printf 'пулы:\n'
    if [ -f "${cb_pools_file:-}" ]; then
        cat "$cb_pools_file"
    fi
    if [ -f "${cb_included:-}" ]; then
        printf 'датасеты:\n'
        awk -F '\t' '{print $2}' "$cb_included"
    fi
    if [ -f "${cb_excluded_list:-}" ]; then
        printf 'исключены:\n'
        awk -F '\t' '{print $2}' "$cb_excluded_list"
    fi
}

cb_cmd_backup() {
    cb_job=backup
    cb_begin
    cb_require_root
    cb_need_config
    cb_hostname=$(cb_compute_hostname)
    if [ "${opt_dry_run:-0}" = 1 ]; then
        cb_dry_run
        return 0
    fi
    cb_lock
    cb_id=$(cb_now_stamp)
    cb_valid_id "$cb_id" || cb_die "странная метка времени: $cb_id"
    cb_ensure_destination
    cb_check_space
    cb_discover_pools
    cb_check_same_pool
    cb_prepare_partial
    cb_decide_mode
    cb_compress=$(cb_pick_compress)
    cb_compress_available "$cb_compress" || cb_die "нет программы сжатия: $cb_compress"
    if [ -n "$cfg_encrypt_keyfile" ]; then
        cb_encrypt=1
        cb_keyflag=$cfg_encrypt_keyfile
    else
        cb_encrypt=0
        cb_keyflag=-
    fi
    if [ "$(cb_pool_count)" -eq 0 ] && ! cb_have zpool; then
        cb_log warn "ZFS на этой системе не найден"
    fi
    cb_post_needed=0
    if [ -n "${cfg_post_hook:-}" ]; then
        cb_post_needed=1
    fi
    if ! cb_run_hook pre; then
        cb_die "pre_hook завершился с ошибкой"
    fi
    if ! cb_snapshot_pools; then
        cb_die "снимок не снят"
    fi
    cb_post_once
    cb_enumerate_pools
    cb_dump_ufs
    ufs_n=${cb_ufs_count:-0}
    zfs_rows=$(awk 'END {print NR+0}' "$cb_included")
    if [ "$ufs_n" -eq 0 ] && [ "$zfs_rows" -eq 0 ]; then
        cb_die "нечего сохранять: нет датасетов ZFS и файловых систем UFS"
    fi
    cb_collect_inventory
    cb_send_datasets
    if [ "$zfs_rows" -gt 0 ] && [ "${cb_zfs_count:-0}" -eq 0 ]; then
        cb_die "ни один датасет не был отправлен"
    fi
    cb_copy_tool
    cb_write_env
    cb_write_plan "$cb_partial/RESTORE.txt"
    if [ -f "$cb_logfile" ]; then
        cp -- "$cb_logfile" "$cb_partial/backup.log" || true
    fi
    cb_write_manifest
    final=$cb_hostdir/$cb_id
    mv -- "$cb_partial" "$final" || cb_die "не удалось опубликовать $final"
    cb_published=1
    cb_partial=
    cb_snap_rollback=0
    printf '%s\n' "$cb_id" >"$cb_hostdir/LATEST.tmp" || cb_die "не удалось записать LATEST"
    mv -- "$cb_hostdir/LATEST.tmp" "$cb_hostdir/LATEST" || cb_die "не удалось обновить LATEST"
    cb_prune_source_snaps || cb_log warn "не все старые снимки удалились"
    cb_prune_dest || cb_log warn "не все старые копии удалились"
    sync || cb_log warn "sync не удался"
    summary="cifsbak OK ${cb_hostname} ${cb_id} ${cb_run_mode} datasets=${cb_zfs_count:-0} ufs=${cb_ufs_count:-0}"
    printf '%s\n' "$summary"
    cb_log info "$summary"
    cb_notified=1
    cb_notify OK "$summary"
}
