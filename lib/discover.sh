# Сбор сведений о дисках и датасетах. Ошибка инвентаризации не отменяет бэкап:
# без потоков ZFS/UFS восстановление данных всё равно невозможно, а вот без
# gpart оно возможно, просто разметку придётся вспомнить руками.

cb_capture() {
    outfile=$1
    shift
    if "$@" >"$outfile" 2>"$outfile.err"; then
        rm -f -- "$outfile.err"
        return 0
    fi
    cb_log warn "команда не удалась: $*"
    return 0
}

cb_copy_if() {
    src=$1
    dst=$2
    if [ -f "$src" ]; then
        cp -- "$src" "$dst" || cb_log warn "не скопировался $src"
    fi
}

cb_parse_gpart_list() {
    awk '
        function flush() {
            if (name != "" && inconsumer == 0) {
                if (label == "(null)") label = ""
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", disk, scheme, partindex, name, type, mediasize, label
            }
            name = ""
            partindex = ""
            type = ""
            mediasize = ""
            label = ""
        }
        BEGIN { inconsumer = 0 }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
        }
        line ~ /^Geom name: / {
            flush()
            inconsumer = 0
            disk = line
            sub(/^Geom name: /, "", disk)
            scheme = ""
            next
        }
        line ~ /^scheme: / {
            scheme = line
            sub(/^scheme: /, "", scheme)
            next
        }
        line ~ /^[0-9]+\. Name: / {
            flush()
            if (inconsumer) next
            name = line
            sub(/^[0-9]+\. Name: /, "", name)
            next
        }
        line ~ /^Consumers:/ { flush(); inconsumer = 1; next }
        line ~ /^Mediasize: / {
            mediasize = line
            sub(/^Mediasize: /, "", mediasize)
            sub(/ .*/, "", mediasize)
            next
        }
        line ~ /^label: / {
            label = line
            sub(/^label: /, "", label)
            next
        }
        line ~ /^type: / {
            type = line
            sub(/^type: /, "", type)
            next
        }
        line ~ /^index: / {
            partindex = line
            sub(/^index: /, "", partindex)
            next
        }
        END { flush() }
    ' "$1"
}

# Печатает одну строку:
#   ok disk /dev/xxx
#   ok mirror /dev/a /dev/b
#   no причина
# Намеренно не угадывает raidz, лог и кэш: неверная команда create хуже её отсутствия.
cb_parse_zpool_status() {
    expand "$1" | awk '
        function dev(n) {
            if (n ~ /^\//) return n
            return "/dev/" n
        }
        BEGIN { inconf = 0; nlines = 0 }
        /^[[:space:]]*NAME[[:space:]]+STATE/ { inconf = 1; next }
        inconf && (/^[[:space:]]*$/ || /^errors:/) { inconf = 0 }
        inconf {
            n = 0
            line = $0
            while (length(line) > 0) {
                c = substr(line, 1, 1)
                if (c == " ") { n++; line = substr(line, 2); continue }
                if (c == "\t") { n += 8; line = substr(line, 2); continue }
                break
            }
            split(line, a, /[[:space:]]+/)
            if (a[1] == "") next
            nlines++
            ind[nlines] = n
            nm[nlines] = a[1]
        }
        END {
            if (nlines < 1) { print "no пустой вывод zpool status"; exit }
            pool_indent = ind[1]
            min = -1
            for (i = 2; i <= nlines; i++) {
                if (ind[i] > pool_indent && (min < 0 || ind[i] < min)) min = ind[i]
            }
            if (min < 0) { print "no в status нет vdev"; exit }
            for (i = 2; i <= nlines; i++) {
                name = nm[i]
                if (name ~ /^(raidz|draid|replacing|indirect)/ || name == "log" || name == "cache" || name == "special" || name == "spare") {
                    print "no сложная топология (" name "), соберите zpool create по сохранённому zpool status"
                    exit
                }
            }
            topn = 0
            for (i = 2; i <= nlines; i++) if (ind[i] == min) { topn++; top[topn] = i }
            if (topn != 1) { print "no несколько групп vdev, соберите zpool create по сохранённому zpool status"; exit }
            ti = top[1]
            tname = nm[ti]
            cn = 0
            for (i = ti + 1; i <= nlines; i++) {
                if (ind[i] <= min) break
                cn++
                child[cn] = nm[i]
                childind[cn] = ind[i]
            }
            if (cn > 0) {
                cmin = childind[1]
                for (i = 1; i <= cn; i++) if (childind[i] < cmin) cmin = childind[i]
                for (i = 1; i <= cn; i++) if (childind[i] != cmin) { print "no вложенная топология, соберите zpool create вручную"; exit }
            }
            if (tname ~ /^mirror/) {
                if (cn < 2) { print "no mirror без дисков"; exit }
                printf "ok mirror"
                for (i = 1; i <= cn; i++) printf " %s", dev(child[i])
                printf "\n"
                exit
            }
            if (cn == 0) {
                printf "ok disk %s\n", dev(tname)
                exit
            }
            print "no не разобрал топологию"
        }
    '
}

cb_suggest_create() {
    pool=$1
    status=$2
    ashift=$3
    [ -f "$status" ] || return 1
    parsed=$(cb_parse_zpool_status "$status") || return 1
    case $parsed in
        "ok "*) ;;
        *)
            printf '%s\n' "$parsed"
            return 1
            ;;
    esac
    vdevs=${parsed#ok }
    case $vdevs in
        "disk "*) spec=${vdevs#disk } ;;
        *) spec=$vdevs ;;
    esac
    ashopt=
    case ${ashift:-} in
        ''|0|-|*[!0-9]*) ashopt= ;;
        *) ashopt="-o ashift=$ashift " ;;
    esac
    printf 'zpool create %s-o altroot=/mnt -O mountpoint=none -O canmount=off %s %s\n' \
        "$ashopt" "$pool" "$spec"
}

cb_discover_pools() {
    cb_pools_file=$cb_runtime/pools
    : >"$cb_pools_file"
    if [ -s "$cfg_pool_file" ]; then
        cp "$cfg_pool_file" "$cb_pools_file"
        return 0
    fi
    if ! cb_have zpool; then
        cb_log warn "zpool не найден, пулы ZFS пропущены"
        return 0
    fi
    if ! zpool list -H -o name >"$cb_pools_file" 2>"$cb_runtime/zpool.err"; then
        cb_log warn "zpool list не удался"
        : >"$cb_pools_file"
    fi
}

cb_pool_count() {
    awk 'NF {n++} END {print n+0}' "$cb_pools_file"
}

cb_excluded() {
    ds=$1
    [ -f "$cfg_exclude_file" ] || return 1
    while IFS= read -r ex || [ -n "$ex" ]; do
        if [ -n "$ex" ]; then
            if [ "$ds" = "$ex" ]; then
                return 0
            fi
            case $ds in
                "$ex"/*) return 0 ;;
            esac
        fi
        ex=
    done <"$cfg_exclude_file"
    return 1
}

cb_enumerate_pools() {
    cb_included=$cb_runtime/included.tsv
    cb_excluded_list=$cb_runtime/excluded.tsv
    : >"$cb_included"
    : >"$cb_excluded_list"
    while IFS= read -r pool || [ -n "$pool" ]; do
        if [ -z "$pool" ]; then
            pool=
            continue
        fi
        cb_assert_pool "$pool"
        list=$cb_runtime/zfs-list-$pool
        if ! zfs list -H -r -o name,mountpoint,encryption,origin,canmount -- "$pool" >"$list" 2>"$list.err"; then
            cb_die "не удалось получить список датасетов пула $pool"
        fi
        while IFS=$(printf '\t') read -r name mp enc origin canmount; do
            [ -n "${name:-}" ] || continue
            cb_assert_dataset "$name"
            case ${enc:-off} in
                ""|-) enc=off ;;
            esac
            case ${origin:-} in
                "") origin=- ;;
            esac
            case ${canmount:-} in
                "") canmount=- ;;
            esac
            case ${mp:-} in
                "") mp=- ;;
            esac
            if cb_excluded "$name"; then
                printf '%s\t%s\t%s\t%s\t%s\n' "$pool" "$name" "$mp" "$canmount" "$origin" >>"$cb_excluded_list"
                continue
            fi
            if [ "$origin" != "-" ]; then
                cb_log warn "$name — клон от $origin. Если отправка оборвётся, исключите его или сохраняйте origin вместе с ним"
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pool" "$name" "$mp" "$enc" "$origin" "$canmount" >>"$cb_included"
        done <"$list"
        pool=
    done <"$cb_pools_file"
}

cb_list_ufs() {
    file=$1
    [ -f "$file" ] || return 0
    awk -v dest="$cfg_destination" '
        $3 == "ufs" {
            mp = $2
            dev = $1
            if (mp == dest || index(mp, dest "/") == 1) next
            if (mp !~ /^\//) next
            printf "%s\t%s\n", dev, mp
        }
    ' "$file"
}

# Свойство пула ashift часто равно 0: сектор выбрали при создании и в метку
# диска записали 12, а в свойство пула нет. Для нового диска нужен сектор из метки.
cb_vdev_ashift() {
    pool=$1
    reported=$2
    case ${reported:-} in
        ''|0|*[!0-9]*) ;;
        *) printf '%s\n' "$reported"; return 0 ;;
    esac
    case $pool in
        *[!A-Za-z0-9_.-]*) printf '%s\n' "${reported:--}"; return 0 ;;
    esac
    if ! cb_have zdb; then
        printf '%s\n' "${reported:--}"
        return 0
    fi
    found=$(zdb -C "$pool" 2>/dev/null | awk '
        /ashift:[[:space:]]*[0-9]+/ {
            n = $2 + 0
            if (!(n in seen)) {
                seen[n] = 1
                kinds++
            }
            if (n > max) max = n
        }
        END {
            if (max > 0) print max
            if (kinds > 1) print "mixed"
        }
    ') || true
    value=$(printf '%s\n' "$found" | awk 'NR == 1 { print; exit }')
    case $value in
        ''|*[!0-9]*) printf '%s\n' "${reported:--}"; return 0 ;;
    esac
    case $found in
        *mixed*) cb_log warn "у дисков пула $pool разный ashift, в опись берётся $value" ;;
    esac
    if [ "$value" != "${reported:-0}" ]; then
        cb_log info "ashift пула $pool в свойстве ${reported:-0}, на диске $value"
    fi
    printf '%s\n' "$value"
}

cb_collect_inventory() {
    inv=$cb_partial/inventory
    mkdir -p "$inv/gpart" "$inv/efi"
    uname -a >"$inv/uname.txt" 2>/dev/null || true
    date -u >"$inv/date-utc.txt" 2>/dev/null || true
    cb_write_sanitized_config "$inv/cifsbak.conf"
    cb_copy_if /etc/fstab "$inv/fstab"
    cb_copy_if /etc/rc.conf "$inv/rc.conf"
    cb_copy_if /etc/sysctl.conf "$inv/sysctl.conf"
    cb_copy_if /boot/loader.conf "$inv/loader.conf"
    cb_copy_if /boot/loader.conf.local "$inv/loader.conf.local"
    if [ -d /etc/rc.conf.d ]; then
        tar -cf "$inv/rc.conf.d.tar" -C /etc rc.conf.d 2>/dev/null || cb_log warn "не удалось упаковать /etc/rc.conf.d"
    fi
    if [ "$(uname -s)" = FreeBSD ]; then
        if cb_have freebsd-version; then
            freebsd-version -kru >"$inv/freebsd-version.txt" 2>/dev/null || freebsd-version >"$inv/freebsd-version.txt" 2>/dev/null || true
        fi
        if cb_have sysctl; then
            sysctl kern.osrelease kern.osreldate kern.disks hw.machine hw.ncpu >"$inv/sysctl.txt" 2>/dev/null || true
        fi
        if cb_have camcontrol; then
            cb_capture "$inv/camcontrol.txt" camcontrol devlist
        fi
        if cb_have service; then
            cb_capture "$inv/services.txt" service -e
        fi
    fi
    if cb_have bectl; then
        cb_capture "$inv/bectl.txt" bectl list
    fi
    if cb_have mount; then
        cb_capture "$inv/mount-p.txt" mount -p
    fi
    if cb_have df; then
        cb_capture "$inv/df.txt" df -h
    fi
    if [ "$(uname -s)" = FreeBSD ] && cb_have pkg; then
        cb_capture "$inv/pkg-prime-list.txt" pkg prime-list
        cb_capture "$inv/pkg-query.txt" pkg query '%n %v'
    fi
    if cb_have gpart; then
        cb_capture "$inv/gpart-list.txt" gpart list
        if [ -s "$inv/gpart-list.txt" ]; then
            cb_parse_gpart_list "$inv/gpart-list.txt" >"$inv/disks.tsv" || true
            awk -F '\t' 'NF >= 1 && !seen[$1]++ {print $1}' "$inv/disks.tsv" >"$cb_runtime/disks"
            while IFS= read -r disk || [ -n "$disk" ]; do
                if [ -n "$disk" ]; then
                    case $disk in
                        *[!A-Za-z0-9._-]*) cb_log warn "пропускаю странное имя диска: $disk" ;;
                        *) cb_capture "$inv/gpart/$disk.backup" gpart backup "$disk" ;;
                    esac
                fi
                disk=
            done <"$cb_runtime/disks"
            cb_save_efi "$inv"
        fi
    else
        cb_log warn "gpart не найден, разметка диска не сохранена"
    fi
    : >"$inv/bootfs.tsv"
    : >"$inv/poolprops.tsv"
    printf 'pool\tashift\tbootfs\tautoexpand\tautotrim\n' >"$inv/poolprops.tsv"
    while IFS= read -r pool || [ -n "$pool" ]; do
        if [ -z "$pool" ]; then
            pool=
            continue
        fi
        cb_capture "$inv/zpool-status-$pool.txt" zpool status -P -- "$pool"
        # «--» после all на FreeBSD 13.2 становится именем пула, а не концом опций.
        cb_capture "$inv/zpool-get-$pool.txt" zpool get -H all "$pool"
        cb_capture "$inv/zpool-history-$pool.txt" zpool history -- "$pool"
        if [ -f "$cb_runtime/zfs-list-$pool" ]; then
            cp "$cb_runtime/zfs-list-$pool" "$inv/zfs-list-$pool.txt"
        fi
        ashift=$(zpool get -H -o value ashift -- "$pool" 2>/dev/null || true)
        ashift=$(cb_vdev_ashift "$pool" "$ashift")
        bootfs=$(zpool get -H -o value bootfs -- "$pool" 2>/dev/null || true)
        autoexpand=$(zpool get -H -o value autoexpand -- "$pool" 2>/dev/null || true)
        autotrim=$(zpool get -H -o value autotrim -- "$pool" 2>/dev/null || true)
        printf '%s\t%s\n' "$pool" "${bootfs:--}" >>"$inv/bootfs.tsv"
        printf '%s\t%s\t%s\t%s\t%s\n' "$pool" "${ashift:--}" "${bootfs:--}" "${autoexpand:--}" "${autotrim:--}" >>"$inv/poolprops.tsv"
        pool=
    done <"$cb_pools_file"
    cp "$cb_excluded_list" "$cb_partial/meta/excluded.tsv"
    cp "$cb_pools_file" "$cb_partial/meta/pools.list"
    cp "$cfg_exclude_file" "$cb_partial/meta/excludes.list"
}

cb_save_efi() {
    inv=$1
    [ -s "$inv/disks.tsv" ] || return 0
    max=$((cfg_max_efi_mb * 1024 * 1024))
    prefix=${CIFSBAK_DEV_PREFIX:-/dev}
    while IFS=$(printf '\t') read -r disk scheme index name type mediasize label; do
        [ "${type:-}" = efi ] || continue
        cb_is_uint "${mediasize:-}" || continue
        if [ "$mediasize" -gt "$max" ]; then
            cb_log warn "раздел $name больше ${cfg_max_efi_mb} МиБ, образ ESP не снимаю"
            continue
        fi
        case $name in
            *[!A-Za-z0-9._-]*) cb_log warn "странное имя раздела $name"; continue ;;
        esac
        dev="$prefix/$name"
        if [ ! -e "$dev" ]; then
            cb_log warn "нет устройства $dev, образ ESP не снят"
            continue
        fi
        if dd if="$dev" of="$inv/efi/$name.img" bs=1048576 2>>"$cb_logfile"; then
            cb_log info "сохранён образ ESP $name"
        else
            cb_log warn "dd $dev не удался"
            rm -f -- "$inv/efi/$name.img"
        fi
    done <"$inv/disks.tsv"
}
