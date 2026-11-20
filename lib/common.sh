# Общие функции cifsbak. Файл подключается через `.`, сам по себе ничего не делает.

cb_log() {
    level=$1
    shift
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    line="$ts $level $*"
    printf '%s\n' "$line" >&2
    if [ -n "${cb_logfile:-}" ]; then
        printf '%s\n' "$line" >>"$cb_logfile" 2>/dev/null || true
    fi
}

cb_notify() {
    status=$1
    shift
    [ -n "${cfg_mail_to:-}" ] || return 0
    if ! command -v mail >/dev/null 2>&1; then
        cb_log warn "mail(1) нет, письмо не отправлено"
        return 0
    fi
    printf '%s\n' "$*" | mail -s "cifsbak ${cb_hostname:-host} $status" "$cfg_mail_to" \
        || cb_log warn "почта не ушла"
}

cb_die() {
    cb_log error "$*"
    if [ "${cb_job:-}" = backup ]; then
        cb_notified=1
        cb_notify FAIL "$*"
    fi
    exit 1
}

cb_have() {
    command -v "$1" >/dev/null 2>&1
}

cb_debug() {
    [ "${CIFSBAK_DEBUG:-0}" = 1 ] || return 0
    cb_log debug "$*"
}

cb_save_errexit() {
    case $- in
        *e*) cb_errexit_on=1 ;;
        *) cb_errexit_on=0 ;;
    esac
    set +e
}

cb_restore_errexit() {
    if [ "${cb_errexit_on:-0}" = 1 ]; then
        set -e
    fi
}

cb_abspath() {
    (cd "$1" && pwd)
}

cb_valid_id() {
    case $1 in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) return 0 ;;
        *) return 1 ;;
    esac
}

cb_assert_pool() {
    case $1 in
        ''|*[!A-Za-z0-9._-]*) cb_die "странное имя пула: $1" ;;
    esac
}

cb_assert_dataset() {
    name=$1
    [ -n "$name" ] || cb_die "пустое имя датасета"
    case $name in
        /*|*/|.|..) cb_die "странное имя датасета: $name" ;;
        *//*) cb_die "странное имя датасета: $name" ;;
        *[!A-Za-z0-9._/-]*) cb_die "странное имя датасета: $name" ;;
        ../*|*/../*|*/..) cb_die "странное имя датасета: $name" ;;
    esac
}

cb_assert_prefix() {
    case $1 in
        ''|*[!A-Za-z0-9._-]*) cb_die "snapshot_prefix может содержать только буквы, цифры, точку, _ и -: $1" ;;
    esac
}

cb_pid_alive() {
    pid=$1
    case $pid in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ -d /proc ]; then
        [ -d "/proc/$pid" ]
        return $?
    fi
    kill -0 "$pid" 2>/dev/null
}

cb_mode_too_open() {
    file=$1
    [ -e "$file" ] || return 1
    found=$(find "$file" -maxdepth 0 \( -perm -040 -o -perm -020 -o -perm -010 -o -perm -004 -o -perm -002 -o -perm -001 \) -print 2>/dev/null || true)
    [ -n "$found" ]
}

cb_assert_private() {
    file=$1
    why=$2
    if cb_mode_too_open "$file"; then
        cb_die "$why должен быть доступен только владельцу (chmod 600): $file"
    fi
}

cb_hash_init() {
    if [ -n "${cb_hash_tool:-}" ]; then
        return 0
    fi
    if cb_have sha256 && sha256 -q /dev/null >/dev/null 2>&1; then
        cb_hash_tool=sha256
    elif cb_have sha256sum; then
        cb_hash_tool=sha256sum
    elif cb_have openssl; then
        cb_hash_tool=openssl
    else
        cb_die "нет sha256, sha256sum или openssl для контрольных сумм"
    fi
}

cb_sha256() {
    cb_hash_init
    case $cb_hash_tool in
        sha256) sha256 -q "$1" ;;
        sha256sum) sha256sum "$1" | awk '{print $1}' ;;
        openssl) openssl dgst -sha256 "$1" | awk '{print $NF}' ;;
    esac
}

cb_epoch() {
    if [ -n "${CIFSBAK_EPOCH:-}" ]; then
        printf '%s\n' "$CIFSBAK_EPOCH"
        return 0
    fi
    date -u +%s
}

cb_now_stamp() {
    if [ -n "${CIFSBAK_NOW:-}" ]; then
        printf '%s\n' "$CIFSBAK_NOW"
        return 0
    fi
    date -u +%Y%m%dT%H%M%SZ
}

cb_compute_hostname() {
    if [ -n "${CIFSBAK_HOSTNAME:-}" ]; then
        h=$CIFSBAK_HOSTNAME
    else
        h=$(hostname -s 2>/dev/null || hostname)
    fi
    case $h in
        ''|*[!A-Za-z0-9._-]*) cb_die "имя хоста содержит неподдерживаемые символы: $h" ;;
    esac
    printf '%s\n' "$h"
}

cb_require_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if [ "${CIFSBAK_ALLOW_NONROOT:-}" = 1 ]; then
        cb_log warn "запуск не от root"
        return 0
    fi
    cb_die "нужен root"
}

cb_is_mountpoint() {
    dir=$1
    [ -d "$dir" ] || return 1
    parent=$(dirname "$dir")
    fs1=$(df -P "$dir" 2>/dev/null | awk 'NR==2 {print $1}')
    fs2=$(df -P "$parent" 2>/dev/null | awk 'NR==2 {print $1}')
    [ -n "$fs1" ] && [ "$fs1" != "$fs2" ]
}

cb_free_kb() {
    df -kP "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

cb_fs_on_pool() {
    fs=$1
    pool=$2
    case $fs in
        "$pool"|"$pool"/*) return 0 ;;
        *) return 1 ;;
    esac
}

cb_rehome() {
    ds=$1
    newpool=$2
    rest=${ds#*/}
    if [ "$rest" = "$ds" ]; then
        printf '%s\n' "$newpool"
    else
        printf '%s\n' "$newpool/$rest"
    fi
}

cb_meta_get() {
    dir=$1
    key=$2
    file="$dir/meta/backup.env"
    [ -f "$file" ] || return 0
    awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$file"
}

cb_list_ids() {
    hostdir=$1
    [ -d "$hostdir" ] || return 0
    found=0
    for dir in "$hostdir"/*; do
        [ -e "$dir" ] || continue
        [ -d "$dir" ] || continue
        [ -L "$dir" ] && continue
        base=$(basename "$dir")
        case $base in
            .*) continue ;;
        esac
        if cb_valid_id "$base"; then
            printf '%s\n' "$base"
            found=1
        fi
    done | sort
    return 0
}

cb_newest_id() {
    cb_list_ids "$1" | tail -n 1
}

cb_safe_rm_rf() {
    p=$1
    case $p in
        *cifsbak-run.*|*cifsbak-enc.*|*cifsbak-dec.*|*cifsbak-drill-*|*cifsbak.*) ;;
        *) cb_log warn "отказ удалять $p"; return 0 ;;
    esac
    case $p in
        /*/*) ;;
        *) cb_log warn "слишком короткий путь $p"; return 0 ;;
    esac
    case $p in
        /|/tmp|/var|/var/tmp|/usr|/home|/mnt) cb_log warn "отказ удалять $p"; return 0 ;;
    esac
    rm -rf -- "$p"
}

cb_rm_partial() {
    p=$1
    case $p in
        */.partial.[0-9]*) ;;
        *) cb_log warn "отказ удалять $p"; return 0 ;;
    esac
    case $p in
        /*/*/*) ;;
        *) cb_log warn "слишком короткий путь $p"; return 0 ;;
    esac
    rm -rf -- "$p"
}

cb_lock() {
    dir=${CIFSBAK_LOCKDIR:-/var/run/cifsbak.lock}
    n=0
    while [ "$n" -lt 3 ]; do
        if mkdir "$dir" 2>/dev/null; then
            printf '%s\n' "$$" >"$dir/pid"
            cb_lock_held=$dir
            return 0
        fi
        old=$(cat "$dir/pid" 2>/dev/null || true)
        if cb_pid_alive "$old"; then
            cb_die "уже выполняется другой cifsbak, pid $old"
        fi
        cb_log warn "снимаю устаревшую блокировку $dir"
        rm -rf -- "$dir" 2>/dev/null || true
        n=$((n + 1))
    done
    cb_die "не удалось захватить блокировку $dir"
}

cb_unlock() {
    [ -n "${cb_lock_held:-}" ] || return 0
    if [ -f "$cb_lock_held/pid" ] && [ "$(cat "$cb_lock_held/pid")" = "$$" ]; then
        rm -rf -- "$cb_lock_held"
    fi
    cb_lock_held=
}

cb_nice_cmd() {
    if [ "${cfg_nice_level:-0}" -gt 0 ] && cb_have nice; then
        nice -n "$cfg_nice_level" "$@"
    else
        "$@"
    fi
}

cb_decompress_fifo() {
    comp=$1
    stage=$2
    fifo=$3
    case $comp in
        none) cat <"$stage" >"$fifo" ;;
        gzip) gzip -dc <"$stage" >"$fifo" ;;
        xz) xz -dc <"$stage" >"$fifo" ;;
        zstd) zstd -dcq <"$stage" >"$fifo" ;;
        *) printf 'неизвестное сжатие: %s\n' "$comp" >&2; return 1 ;;
    esac
}

cb_compress_to_file() {
    comp=$1
    keyfile=$2
    fifo=$3
    dest=$4
    work=$5
    tmp="$work/cmp"
    case $comp in
        none) cat <"$fifo" >"$tmp" ;;
        gzip) gzip -1 -c <"$fifo" >"$tmp" ;;
        xz) xz -2 -c <"$fifo" >"$tmp" ;;
        zstd) zstd -q -3 -c <"$fifo" >"$tmp" ;;
        *) printf 'неизвестное сжатие: %s\n' "$comp" >&2; return 1 ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    if [ -n "$keyfile" ]; then
        openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$keyfile" -in "$tmp" -out "$dest"
        rc=$?
        rm -f -- "$tmp"
        return "$rc"
    fi
    mv -- "$tmp" "$dest"
}

# cb_produce_file DEST COMPRESS KEYFILE -- command...
# KEYFILE "-" means no encryption. Command stdout is the raw stream.
cb_produce_file() {
    dest=$1
    comp=$2
    keyfile=$3
    shift 3
    if [ "${1:-}" = "--" ]; then
        shift
    fi
    if [ "$keyfile" = "-" ]; then
        keyfile=
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/cifsbak-enc.XXXXXX")
    fifo="$work/fifo"
    mkfifo "$fifo"
    cb_compress_to_file "$comp" "$keyfile" "$fifo" "$dest" "$work" >"$work/comp.out" 2>"$work/comp.err" &
    cpid=$!
    cb_save_errexit
    if [ -n "${cb_logfile:-}" ]; then
        "$@" >"$fifo" 2>>"$cb_logfile"
    else
        "$@" >"$fifo"
    fi
    prc=$?
    wait "$cpid"
    crc=$?
    cb_restore_errexit
    if [ -s "$work/comp.err" ]; then
        cat "$work/comp.err" >&2
    fi
    rm -rf -- "$work"
    if [ "$prc" -ne 0 ] || [ "$crc" -ne 0 ] || [ ! -s "$dest" ]; then
        rm -f -- "$dest"
        return 1
    fi
    return 0
}

# cb_pipe_decoded FILE COMPRESS KEYFILE -- command...
# Command stdin is the decoded stream. KEYFILE "-" means plaintext.
cb_pipe_decoded() {
    file=$1
    comp=$2
    keyfile=$3
    shift 3
    if [ "${1:-}" = "--" ]; then
        shift
    fi
    if [ "$keyfile" = "-" ]; then
        keyfile=
    fi
    if [ ! -f "$file" ]; then
        cb_log error "нет файла $file"
        return 1
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/cifsbak-dec.XXXXXX")
    fifo="$work/stream"
    stage="$work/stage"
    mkfifo "$fifo"
    mkfifo "$stage"
    "$@" <"$fifo" >"$work/consumer.out" 2>"$work/consumer.err" &
    cpid=$!
    cb_decompress_fifo "$comp" "$stage" "$fifo" >"$work/dec.out" 2>"$work/dec.err" &
    dpid=$!
    cb_save_errexit
    if [ -n "$keyfile" ]; then
        openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$keyfile" -in "$file" >"$stage" 2>"$work/src.err"
        src=$?
    else
        cat "$file" >"$stage"
        src=$?
    fi
    wait "$dpid"
    drc=$?
    wait "$cpid"
    crc=$?
    cb_restore_errexit
    if [ -n "${cb_logfile:-}" ]; then
        cat "$work/consumer.out" >>"$cb_logfile" 2>/dev/null || true
        cat "$work/consumer.err" >>"$cb_logfile" 2>/dev/null || true
        cat "$work/dec.err" >>"$cb_logfile" 2>/dev/null || true
        cat "$work/src.err" >>"$cb_logfile" 2>/dev/null || true
    fi
    if [ "$src" -ne 0 ] || [ "$drc" -ne 0 ] || [ "$crc" -ne 0 ]; then
        cat "$work/src.err" "$work/dec.err" "$work/consumer.err" >&2 2>/dev/null || true
        rm -rf -- "$work"
        return 1
    fi
    rm -rf -- "$work"
    return 0
}

cb_ext_for() {
    comp=$1
    enc=$2
    case $comp in
        gzip) ext=gz ;;
        xz) ext=xz ;;
        zstd) ext=zst ;;
        none) ext=raw ;;
        *) cb_die "неизвестное сжатие: $comp" ;;
    esac
    if [ "$enc" = 1 ]; then
        ext="$ext.enc"
    fi
    printf '%s\n' "$ext"
}

cb_pick_compress() {
    case ${cfg_compress:-auto} in
        none|gzip|xz|zstd) printf '%s\n' "$cfg_compress" ;;
        auto)
            if cb_have zstd; then
                printf '%s\n' zstd
            elif cb_have xz; then
                printf '%s\n' xz
            elif cb_have gzip; then
                printf '%s\n' gzip
            else
                cb_die "нет zstd, xz или gzip"
            fi
            ;;
        *) cb_die "compress должен быть auto, zstd, xz, gzip или none" ;;
    esac
}

cb_compress_available() {
    comp=$1
    case $comp in
        none) return 0 ;;
        gzip) cb_have gzip ;;
        xz) cb_have xz ;;
        zstd) cb_have zstd ;;
        *) return 1 ;;
    esac
}

cb_active_keyfile() {
    if [ -n "${opt_keyfile:-}" ]; then
        printf '%s\n' "$opt_keyfile"
        return 0
    fi
    if [ -n "${cfg_encrypt_keyfile:-}" ]; then
        printf '%s\n' "$cfg_encrypt_keyfile"
        return 0
    fi
    return 1
}

cb_sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

cb_on_exit() {
    rc=$?
    trap - EXIT
    set +e
    if [ "${cb_snap_rollback:-0}" = 1 ]; then
        cb_rollback_snapshots
    fi
    if [ "${cb_published:-0}" != 1 ] && [ -n "${cb_partial:-}" ]; then
        cb_rm_partial "$cb_partial"
    fi
    if [ "${cb_drill_active:-0}" = 1 ]; then
        zpool export cifsbakdrill >/dev/null 2>&1 \
            || zpool destroy -f cifsbakdrill >/dev/null 2>&1 \
            || true
        if [ -n "${cb_drill_image:-}" ]; then
            case $cb_drill_image in
                *cifsbak-drill-*.img) rm -f -- "$cb_drill_image" ;;
            esac
        fi
        if [ -n "${cb_drill_alt:-}" ]; then
            cb_safe_rm_rf "$cb_drill_alt"
        fi
    fi
    if [ "${cb_mounted_by_us:-0}" = 1 ] && [ -n "${cfg_destination:-}" ]; then
        umount "$cfg_destination" >/dev/null 2>&1 || true
        cb_mounted_by_us=0
    fi
    if [ "${cb_post_needed:-0}" = 1 ] && [ "${cb_post_done:-0}" != 1 ]; then
        cb_post_done=1
        if [ -n "${cfg_post_hook:-}" ]; then
            sh -c "$cfg_post_hook" || cb_log warn "post_hook завершился с ошибкой"
        fi
    fi
    if [ -n "${cb_privhome:-}" ]; then
        case $cb_privhome in
            /tmp/cifsbak.*|/var/tmp/cifsbak.*) rm -rf -- "$cb_privhome" ;;
        esac
        cb_privhome=
    fi
    cb_unlock
    if [ "$rc" -ne 0 ] && [ "${cb_job:-}" = backup ] && [ "${cb_notified:-0}" != 1 ]; then
        cb_notify FAIL "завершилось с кодом $rc"
    fi
    if [ -n "${cb_runtime:-}" ] && [ "${cb_keep_runtime:-0}" != 1 ]; then
        cb_safe_rm_rf "$cb_runtime"
    fi
    exit "$rc"
}

cb_begin() {
    if [ -n "${cb_began:-}" ]; then
        return 0
    fi
    cb_began=1
    if [ -z "${cfg_snapshot_prefix:-}" ]; then
        cb_config_defaults
    fi
    cb_runtime=$(mktemp -d "${TMPDIR:-/tmp}/cifsbak-run.XXXXXX")
    chmod 700 "$cb_runtime"
    if [ -n "${CIFSBAK_LOG:-}" ]; then
        cb_logfile=$CIFSBAK_LOG
        mkdir -p "$(dirname "$cb_logfile")" 2>/dev/null || true
        if ! : >>"$cb_logfile" 2>/dev/null; then
            cb_logfile=$cb_runtime/run.log
        fi
    elif [ "$(id -u)" -eq 0 ] && [ -w /var/log ]; then
        cb_logfile=/var/log/cifsbak.log
    else
        cb_logfile=$cb_runtime/run.log
    fi
    : >>"$cb_logfile" || true
    trap 'cb_on_exit' EXIT
    cb_log info "cifsbak ${CB_VERSION:-0} pid $$"
}

cb_run_hook() {
    which=$1
    if [ "$which" = pre ]; then
        hook=${cfg_pre_hook:-}
    else
        hook=${cfg_post_hook:-}
    fi
    [ -n "$hook" ] || return 0
    cb_log info "запускаю $which-hook"
    sh -c "$hook"
}

cb_post_once() {
    [ "${cb_post_needed:-0}" = 1 ] || return 0
    [ "${cb_post_done:-0}" = 1 ] && return 0
    cb_post_done=1
    cb_run_hook post || cb_log warn "post_hook завершился с ошибкой"
}
