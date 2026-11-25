#!/bin/sh
# Прогон cifsbak без FreeBSD: zfs/zpool/gpart/mount_smbfs подменены.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FIX=$ROOT/tests/fixtures
BIN=$ROOT/bin/cifsbak
WORK=$(mktemp -d /tmp/cifsbak-tests.XXXXXX)
ORIG_PATH=$PATH
export PATH="$ROOT/tests/mocks:$ORIG_PATH"
export CIFSBAK_ALLOW_NONROOT=1
export CIFSBAK_HOSTNAME=testbox

cleanup() {
    rm -rf -- "$WORK"
    find /tmp /var/tmp -maxdepth 1 -name 'cifsbak*' -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    printf '%s\n' "FAIL: $*" >&2
    if [ -n "${STATE:-}" ]; then
        printf '%s\n' '--- stdout ---' >&2
        cat "$STATE/stdout" >&2 2>/dev/null || true
        printf '%s\n' '--- stderr ---' >&2
        cat "$STATE/stderr" >&2 2>/dev/null || true
        printf '%s\n' '--- run.log ---' >&2
        cat "$STATE/run.log" >&2 2>/dev/null || true
        if [ -f "$STATE/zfs.log" ]; then
            printf '%s\n' '--- zfs.log ---' >&2
            cat "$STATE/zfs.log" >&2
        fi
    fi
    exit 1
}

need() {
    file=$1
    needle=$2
    if ! grep -F "$needle" "$file" >/dev/null 2>&1; then
        fail "в $file нет «$needle»"
    fi
}

need_not() {
    file=$1
    needle=$2
    if [ -f "$file" ] && grep -F "$needle" "$file" >/dev/null 2>&1; then
        fail "в $file нашлось «$needle»"
    fi
}

ok() {
    label=$1
    shift
    if ! "$@" >"$STATE/stdout" 2>"$STATE/stderr"; then
        fail "$label"
    fi
    printf 'ok %s\n' "$label"
}

bad() {
    label=$1
    needle=$2
    shift 2
    if "$@" >"$STATE/stdout" 2>"$STATE/stderr"; then
        fail "$label: команда должна была завершиться с ошибкой"
    fi
    if ! grep -F "$needle" "$STATE/stderr" >/dev/null 2>&1; then
        fail "$label: в stderr нет «$needle»"
    fi
    printf 'ok %s\n' "$label"
}

new_env() {
    STATE=$(mktemp -d "$WORK/state.XXXXXX")
    export CIFSBAK_MOCK_STATE=$STATE
    export CIFSBAK_LOCKDIR=$STATE/lock
    export CIFSBAK_LOG=$STATE/run.log
    export CIFSBAK_DEV_PREFIX=$STATE/dev
    unset CIFSBAK_NOW CIFSBAK_EPOCH CIFSBAK_MOCK_MOUNT_FAIL
    cp "$FIX/datasets" "$FIX/pools" "$FIX/snapshots" "$FIX/poolprops.zroot" \
        "$FIX/root" "$FIX/mount-p.txt" "$FIX/gpart-list.txt" \
        "$FIX/gpart-backup.nda0" "$FIX/status.zroot" "$STATE/"
    mkdir -p "$STATE/dev" "$STATE/share" "$STATE/drill"
    printf 'EFI-IMAGE\n' >"$STATE/dev/nda0p1"
    : >"$STATE/stdout"
    : >"$STATE/stderr"
}

write_conf() {
    mode=${1:-full}
    cat >"$STATE/cifsbak.conf" <<EOF
destination=$STATE/share
cifs_mode=nomount
backup_mode=$mode
full_every_days=30
keep_copies=3
keep_source_snapshots=2
compress=gzip
min_free_mb=0
nice_level=0
drill_dir=$STATE/drill
drill_size_gb=1
exclude_datasets=zroot/tmp zroot/var/tmp zroot/var/crash
EOF
    chmod 600 "$STATE/cifsbak.conf"
}

conf_set() {
    printf '%s\n' "$1" >>"$STATE/cifsbak.conf"
}

latest_id() {
    cat "$STATE/share/testbox/LATEST"
}

bkdir() {
    printf '%s\n' "$STATE/share/testbox/$(latest_id)"
}

unit_parsers() {
    (
        set -eu
        # shellcheck disable=SC1091
        . "$ROOT/lib/common.sh"
        # shellcheck disable=SC1091
        . "$ROOT/lib/discover.sh"
        cb_parse_gpart_list "$FIX/gpart-list.txt" >"$WORK/gpart.tsv"
        line=$(awk -F '\t' '$5 == "efi" { print }' "$WORK/gpart.tsv")
        [ "$line" = "nda0	GPT	1	nda0p1	efi	272629760	efiboot0" ] || {
            printf 'gpart: %s\n' "$line" >&2
            exit 1
        }
        n=$(awk 'END { print NR+0 }' "$WORK/gpart.tsv")
        [ "$n" = 3 ] || exit 1
        cb_parse_zpool_status "$FIX/status.zroot" >"$WORK/st1"
        [ "$(cat "$WORK/st1")" = "ok disk /dev/nda0p3" ] || exit 1
        cb_parse_zpool_status "$FIX/status-mirror.txt" >"$WORK/st2"
        [ "$(cat "$WORK/st2")" = "ok mirror /dev/nda0p3 /dev/nda1p3" ] || exit 1
        cb_parse_zpool_status "$FIX/status-raidz.txt" >"$WORK/st3"
        grep -q '^no ' "$WORK/st3" || exit 1
        cb_fs_on_pool "zroot/ROOT/default" zroot
        cb_fs_on_pool zroot zroot
        if cb_fs_on_pool tank zroot; then
            exit 1
        fi
        [ "$(cb_rehome zroot/ROOT/default tank)" = "tank/ROOT/default" ]
        [ "$(cb_rehome zroot tank)" = tank ]
        if ( cb_assert_dataset 'zroot//tmp' ) 2>/dev/null; then
            exit 1
        fi
    ) || fail "разбор gpart/zpool"
    printf 'ok разбор gpart и zpool status\n'
}

unit_pipes() {
    (
        set -eu
        # shellcheck disable=SC1091
        . "$ROOT/lib/common.sh"
        out=$WORK/pipe.gz
        dec=$WORK/pipe.txt
        cb_produce_file "$out" gzip - -- printf '%s\n' 'hello-stream'
        cb_pipe_decoded "$out" gzip - -- sh -c 'cat > "$1"' sh "$dec"
        [ "$(cat "$dec")" = "hello-stream" ]
        bad=$WORK/missing.gz
        if cb_produce_file "$bad" gzip - -- false; then
            exit 1
        fi
        [ ! -e "$bad" ]
        key=$WORK/key
        printf '%s\n' 'correct-key' >"$key"
        chmod 600 "$key"
        enc=$WORK/secret.gz.enc
        plain=$WORK/secret.txt
        cb_produce_file "$enc" gzip "$key" -- printf '%s\n' 'secret-stream'
        cb_pipe_decoded "$enc" gzip "$key" -- sh -c 'cat > "$1"' sh "$plain"
        [ "$(cat "$plain")" = "secret-stream" ]
        wrong=$WORK/wrong
        printf '%s\n' 'other-key' >"$wrong"
        chmod 600 "$wrong"
        if cb_pipe_decoded "$enc" gzip "$wrong" -- sh -c 'cat > "$1"' sh "$WORK/nope" 2>/dev/null; then
            exit 1
        fi
    ) || fail "сжатие и шифрование"
    printf 'ok сжатие, ошибка производителя и шифрование\n'
}

unit_config() {
    new_env
    printf '%s\n' 'destination=/tmp' 'no_such_key=1' >"$STATE/cifsbak.conf"
    bad "неизвестный параметр" "неизвестный параметр" "$BIN" -c "$STATE/cifsbak.conf" doctor
    new_env
    cat >"$STATE/cifsbak.conf" <<EOF
destination=$STATE/share
cifs_mode=mount
cifs_host=nasbox
cifs_share=backups
cifs_user=bkpuser
cifs_password=S3cret-Cifs-99
EOF
    chmod 644 "$STATE/cifsbak.conf"
    bad "открытый конфиг" "chmod 600" "$BIN" -c "$STATE/cifsbak.conf" doctor
    need_not "$STATE/stderr" "S3cret-Cifs-99"
    need_not "$STATE/stdout" "S3cret-Cifs-99"
    need_not "$STATE/run.log" "S3cret-Cifs-99"
    new_env
    cat >"$STATE/cifsbak.conf" <<EOF
destination=$STATE/share
cifs_mode=mount
cifs_host=nasbox
cifs_share=backups
cifs_user=bkpuser
cifs_password=CHANGE-ME
EOF
    chmod 600 "$STATE/cifsbak.conf"
    bad "пароль-заглушка" "задайте пароль" "$BIN" -c "$STATE/cifsbak.conf" doctor
    if [ "$(id -u)" -ne 0 ]; then
        new_env
        write_conf
        if env -u CIFSBAK_ALLOW_NONROOT "$BIN" -c "$STATE/cifsbak.conf" doctor \
            >"$STATE/stdout" 2>"$STATE/stderr"; then
            fail "без root команда должна была остановиться"
        fi
        need "$STATE/stderr" "нужен root"
        printf 'ok отказ без root\n'
    fi
}

test_doctor_dry() {
    new_env
    write_conf
    before=$(cksum "$STATE/snapshots")
    ok "doctor" "$BIN" -c "$STATE/cifsbak.conf" doctor
    need "$STATE/stdout" "можно запускать cifsbak backup"
    after=$(cksum "$STATE/snapshots")
    [ "$before" = "$after" ] || fail "doctor изменил снимки"
    ok "сухой прогон" "$BIN" -c "$STATE/cifsbak.conf" backup --dry-run
    need "$STATE/stdout" "сухой прогон: full"
    need "$STATE/stdout" "zroot/ROOT/default"
    need "$STATE/stdout" "zroot/usr/home"
    need "$STATE/stdout" "zroot/tmp"
    after=$(cksum "$STATE/snapshots")
    [ "$before" = "$after" ] || fail "сухой прогон изменил снимки"
}

assert_full_backup() {
    id=$(latest_id)
    dir=$(bkdir)
    [ -d "$dir/tool/lib" ] || fail "утилита не скопирована в бэкап"
    [ -f "$dir/RESTORE.txt" ] || fail "нет RESTORE.txt"
    n=$(awk -F '\t' 'NR > 1 { c++ } END { print c+0 }' "$dir/meta/streams.tsv")
    [ "$n" = 6 ] || fail "ожидалось 6 потоков, получилось $n"
    if awk -F '\t' 'NR > 1 && $3 == "zroot/tmp" { found = 1 } END { exit found ? 0 : 1 }' \
        "$dir/meta/streams.tsv"; then
        fail "исключённый датасет попал в поток"
    fi
    ex=$(awk 'NF { c++ } END { print c+0 }' "$dir/meta/excluded.tsv")
    [ "$ex" = 3 ] || fail "исключений $ex, ожидалось 3"
    need "$dir/RESTORE.txt" "gpart restore -F"
    need "$dir/RESTORE.txt" "nda0"
    need "$dir/RESTORE.txt" "inventory/efi/nda0p1.img"
    need "$dir/RESTORE.txt" "ashift=12"
    need "$dir/RESTORE.txt" "/dev/nda0p3"
    need "$dir/RESTORE.txt" "bootfs="
    need "$dir/RESTORE.txt" "zroot/ROOT/default"
    need "$dir/RESTORE.txt" "bootx64.efi"
    need "$dir/RESTORE.txt" "zfs create"
    need "$dir/RESTORE.txt" "zroot/tmp"
    recv=$(grep -c 'zfs receive -u -F' "$dir/RESTORE.txt")
    [ "$recv" = 6 ] || fail "в RESTORE $recv приёмов, ожидалось 6"
    creates=$(grep -c '^zfs create ' "$dir/RESTORE.txt")
    [ "$creates" = 3 ] || fail "в RESTORE $creates zfs create, ожидалось 3"
    cmp "$STATE/dev/nda0p1" "$dir/inventory/efi/nda0p1.img" || fail "образ ESP отличается"
    if ! awk -F '\t' -v s="cifsbak-$id" '$1 == "zroot/tmp" && $2 == s { found = 1 } END { exit found ? 0 : 1 }' \
        "$STATE/snapshots"; then
        fail "снимок не покрыл исключённый датасет"
    fi
    need "$STATE/stdout" "datasets=6"
    need "$dir/meta/backup.env" "mode=full"
    if [ -f "$dir/inventory/cifsbak.conf" ]; then
        need_not "$dir/inventory/cifsbak.conf" "S3cret-Cifs-99"
    fi
}

test_full() {
    new_env
    write_conf
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "полный бэкап" "$BIN" -c "$STATE/cifsbak.conf" backup
    assert_full_backup
    dir=$(bkdir)
    ok "verify" "$BIN" -c "$STATE/cifsbak.conf" verify
    need "$STATE/stdout" "OK "
    ok "verify из копии утилиты" sh "$dir/tool/bin/cifsbak" verify
    python3 - "$dir/zfs/0001.gz" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
b[min(10, len(b) - 1)] ^= 0xFF
open(p, "wb").write(b)
PY
    bad "verify после порчи" "не сходится" "$BIN" -c "$STATE/cifsbak.conf" verify
    bad "повтор той же метки" "уже существует" "$BIN" -c "$STATE/cifsbak.conf" backup
}

test_incremental() {
    new_env
    write_conf auto
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "база для инкремента" "$BIN" -c "$STATE/cifsbak.conf" backup
    first=$(latest_id)
    export CIFSBAK_NOW=20260116T030000Z
    export CIFSBAK_EPOCH=1768532400
    ok "инкремент" "$BIN" -c "$STATE/cifsbak.conf" backup
    dir=$(bkdir)
    need "$dir/meta/backup.env" "mode=incr"
    need "$dir/meta/backup.env" "parent_id=$first"
    if awk -F '\t' 'NR > 1 && $4 != "incr" { bad = 1 } END { exit bad ? 0 : 1 }' \
        "$dir/meta/streams.tsv"; then
        fail "не все потоки инкрементальные"
    fi
    need "$dir/RESTORE.txt" "../$first/"
    need "$STATE/zfs.log" " -i "
    export CIFSBAK_NOW=20260220T030000Z
    export CIFSBAK_EPOCH=1771556400
    conf_set "full_every_days=1"
    ok "полный по возрасту" "$BIN" -c "$STATE/cifsbak.conf" backup
    need "$(bkdir)/meta/backup.env" "mode=full"
}

test_retention() {
    new_env
    write_conf auto
    conf_set "keep_copies=1"
    export CIFSBAK_EPOCH=1768446000
    export CIFSBAK_NOW=20260101T000000Z
    ok "копия A" "$BIN" -c "$STATE/cifsbak.conf" backup
    a=$(latest_id)
    export CIFSBAK_NOW=20260102T000000Z
    ok "копия B" "$BIN" -c "$STATE/cifsbak.conf" backup
    b=$(latest_id)
    [ -d "$STATE/share/testbox/$a" ] || fail "инкремент удалил свою базу"
    [ -d "$STATE/share/testbox/$b" ] || fail "нет копии B"
    export CIFSBAK_NOW=20260103T000000Z
    ok "копия C" "$BIN" -c "$STATE/cifsbak.conf" backup --full
    c=$(latest_id)
    [ ! -d "$STATE/share/testbox/$a" ] || fail "старый полный не удалён"
    [ ! -d "$STATE/share/testbox/$b" ] || fail "старый инкремент не удалён"
    [ -d "$STATE/share/testbox/$c" ] || fail "нет копии C"
    export CIFSBAK_NOW=20260104T000000Z
    ok "копия D" "$BIN" -c "$STATE/cifsbak.conf" backup
    d=$(latest_id)
    [ -d "$STATE/share/testbox/$c" ] || fail "инкремент удалил новую базу"
    [ -d "$STATE/share/testbox/$d" ] || fail "нет копии D"
    [ ! -d "$STATE/share/testbox/$a" ] || fail "A вернулась"
}

test_send_failure() {
    new_env
    write_conf auto
    conf_set "pre_hook=echo pre >> $STATE/hooks"
    conf_set "post_hook=echo post >> $STATE/hooks"
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "первая копия" "$BIN" -c "$STATE/cifsbak.conf" backup
    first=$(latest_id)
    first_snap=$(awk -F= '$1 == "snap" { print $2 }' "$(bkdir)/meta/backup.env")
    : >"$STATE/hooks"
    printf '1\n' >"$STATE/fail_send"
    export CIFSBAK_NOW=20260116T030000Z
    bad "обрыв отправки" "отправка" "$BIN" -c "$STATE/cifsbak.conf" backup
    [ "$(latest_id)" = "$first" ] || fail "LATEST сменился после ошибки"
    found=$(find "$STATE/share/testbox" -name '.partial.*' -print)
    [ -z "$found" ] || fail "остался каталог $found"
    if awk -F '\t' -v s="cifsbak-20260116T030000Z" '$2 == s { found = 1 } END { exit found ? 0 : 1 }' \
        "$STATE/snapshots"; then
        fail "сломанный снимок не откатили"
    fi
    if ! awk -F '\t' -v s="$first_snap" '$2 == s { found = 1 } END { exit found ? 0 : 1 }' \
        "$STATE/snapshots"; then
        fail "хороший снимок пропал"
    fi
    [ "$(grep -c pre "$STATE/hooks")" = 1 ] || fail "pre_hook не отработал на сломанном прогоне"
    [ "$(grep -c post "$STATE/hooks")" = 1 ] || fail "post_hook не отработал после снимка"
    rm -f "$STATE/fail_send"
    export CIFSBAK_NOW=20260117T030000Z
    ok "инкремент после отката" "$BIN" -c "$STATE/cifsbak.conf" backup
    need "$(bkdir)/meta/backup.env" "parent_snap=$first_snap"
    need "$(bkdir)/meta/backup.env" "mode=incr"
}

test_pre_hook() {
    new_env
    write_conf
    conf_set "pre_hook=exit 1"
    conf_set "post_hook=echo post >> $STATE/hooks"
    export CIFSBAK_NOW=20260115T030000Z
    bad "pre_hook" "pre_hook" "$BIN" -c "$STATE/cifsbak.conf" backup
    if [ -s "$STATE/snapshots" ]; then
        fail "при ошибке pre_hook снимок всё же снят"
    fi
    need "$STATE/hooks" "post"
    found=$(find "$STATE/share" -name '.partial.*' -print 2>/dev/null || true)
    [ -z "$found" ] || fail "остался $found"
}

add_pool() {
    name=$1
    alt=$2
    printf '%s\n' "$name" >>"$STATE/pools"
    cat >"$STATE/poolprops.$name" <<EOF
ashift=12
bootfs=-
autoexpand=off
autotrim=off
altroot=$alt
EOF
}

test_restore_guards() {
    new_env
    write_conf
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "копия перед restore" "$BIN" -c "$STATE/cifsbak.conf" backup
    bad "restore в живой пул" "держит корень" \
        "$BIN" -c "$STATE/cifsbak.conf" restore --yes --to zroot
    add_pool noalt -
    bad "restore без altroot" "altroot" \
        "$BIN" -c "$STATE/cifsbak.conf" restore --yes --to noalt
    add_pool tank /mnt/tank
    ok "restore в tank" "$BIN" -c "$STATE/cifsbak.conf" restore --yes --from zroot --to tank
    if ! awk -F '\t' '$1 == "tank/ROOT/default" { found = 1 } END { exit found ? 0 : 1 }' \
        "$STATE/datasets"; then
        fail "датасет не принят в tank"
    fi
    if ! awk -F '\t' '$1 == "tank/ROOT/default" && $2 == "cifsbak-20260115T030000Z" { found = 1 } END { exit found ? 0 : 1 }' \
        "$STATE/snapshots"; then
        fail "снимок не принят в tank"
    fi
}

test_drill() {
    new_env
    write_conf
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "копия для drill" "$BIN" -c "$STATE/cifsbak.conf" backup
    ok "drill" "$BIN" -c "$STATE/cifsbak.conf" drill --yes
    need "$STATE/stdout" "cifsbak drill OK"
    if awk '$0 == "cifsbakdrill" { found = 1 } END { exit found ? 0 : 1 }' "$STATE/pools"; then
        fail "пробный пул не удалён"
    fi
    left=$(find "$STATE/drill" -name 'cifsbak-drill-*' -print)
    [ -z "$left" ] || fail "осталось $left"
}

test_ufs() {
    new_env
    cp "$FIX/mount-p-ufs.txt" "$STATE/mount-p.txt"
    write_conf
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "бэкап с UFS" "$BIN" -c "$STATE/cifsbak.conf" backup
    need "$STATE/stdout" "ufs=1"
    dir=$(bkdir)
    gzip -dc "$dir/ufs/0001.gz" >"$STATE/ufs-plain"
    need "$STATE/ufs-plain" "DUMPSTREAM /mnt/ufs"
    target=$STATE/ufs-restore
    mkdir -p "$target"
    ok "restore-ufs" "$BIN" -c "$STATE/cifsbak.conf" restore-ufs --yes \
        --mountpoint /mnt/ufs --target "$target"
    need "$target/RESTORED_FROM_DUMP" "DUMPSTREAM /mnt/ufs"
}

test_cifs_mount() {
    new_env
    cat >"$STATE/cifsbak.conf" <<EOF
destination=$STATE/share
cifs_mode=mount
cifs_host=nasbox
cifs_share=backups
cifs_user=bkpuser
cifs_password=S3cret-Cifs-99
cifs_workgroup=WORKGROUP
backup_mode=full
compress=gzip
min_free_mb=0
nice_level=0
keep_copies=2
keep_source_snapshots=2
full_every_days=30
drill_dir=$STATE/drill
drill_size_gb=1
exclude_datasets=zroot/tmp zroot/var/tmp zroot/var/crash
EOF
    chmod 600 "$STATE/cifsbak.conf"
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "бэкап через mount_smbfs" "$BIN" -c "$STATE/cifsbak.conf" backup
    need "$STATE/mount-smbfs.log" "nasbox"
    need "$STATE/mount-smbfs.log" "backups"
    need "$STATE/umount.log" "$STATE/share"
    need_not "$STATE/mount-smbfs.log" "S3cret-Cifs-99"
    need_not "$STATE/run.log" "S3cret-Cifs-99"
    need_not "$STATE/stderr" "S3cret-Cifs-99"
    dir=$(bkdir)
    [ -f "$dir/meta/backup.env" ] || fail "после mount бэкапа нет"
    need "$dir/inventory/cifsbak.conf" "cifs_password=***"
    need_not "$dir/inventory/cifsbak.conf" "S3cret-Cifs-99"
}

test_lock() {
    new_env
    write_conf
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    mkdir -p "$STATE/lock"
    printf '%s\n' "$$" >"$STATE/lock/pid"
    bad "занятая блокировка" "уже выполняется" "$BIN" -c "$STATE/cifsbak.conf" backup
    dead=999999
    while [ -d "/proc/$dead" ]; do
        dead=$((dead + 1))
    done
    printf '%s\n' "$dead" >"$STATE/lock/pid"
    ok "устаревшая блокировка" "$BIN" -c "$STATE/cifsbak.conf" backup
}

test_encrypt_backup() {
    new_env
    write_conf
    printf '%s\n' 'backup-key-material' >"$STATE/key"
    chmod 600 "$STATE/key"
    conf_set "encrypt_keyfile=$STATE/key"
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "шифрованный бэкап" "$BIN" -c "$STATE/cifsbak.conf" backup
    dir=$(bkdir)
    need "$dir/RESTORE.txt" "openssl enc -d"
    ok "verify без ключа" env -u CIFSBAK_CONFIG "$BIN" -c "$STATE/cifsbak.conf" verify
    # конфиг всё ещё содержит ключ, поэтому verify его найдёт.
    # Отдельный конфиг без ключа проверяет предупреждение.
    grep -v '^encrypt_keyfile=' "$STATE/cifsbak.conf" >"$STATE/nokey.conf"
    chmod 600 "$STATE/nokey.conf"
    ok "verify без ключа в конфиге" "$BIN" -c "$STATE/nokey.conf" verify
    need "$STATE/stdout" "не расшифрованы"
    bad "чужой ключ" "не читается" "$BIN" -c "$STATE/nokey.conf" verify --keyfile "$STATE/cifsbak.conf"
    ok "свой ключ" "$BIN" -c "$STATE/nokey.conf" verify --keyfile "$STATE/key"
    need "$STATE/stdout" "OK "
}

test_raw_send() {
    new_env
    awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "zroot/usr/home" { $3 = "aes-256-gcm" } { print }' \
        "$STATE/datasets" >"$STATE/datasets.new"
    mv "$STATE/datasets.new" "$STATE/datasets"
    write_conf
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "бэкап с шифрованным датасетом" "$BIN" -c "$STATE/cifsbak.conf" backup
    need "$STATE/zfs.log" "send -v -w -p"
    dir=$(bkdir)
    raw=$(awk -F '\t' '$3 == "zroot/usr/home" { print $7 }' "$dir/meta/streams.tsv")
    [ "$raw" = 1 ] || fail "raw=$raw, ожидалось 1"
}

test_ashift_from_disk() {
    new_env
    cat >"$STATE/poolprops.zroot" <<EOF
ashift=0
bootfs=zroot/ROOT/default
autoexpand=off
autotrim=off
altroot=-
EOF
    printf '%s\n' '                ashift: 12' '                ashift: 9' >"$STATE/zdb.zroot"
    write_conf
    export CIFSBAK_NOW=20260115T030000Z
    export CIFSBAK_EPOCH=1768446000
    ok "ashift с метки диска" "$BIN" -c "$STATE/cifsbak.conf" backup
    dir=$(bkdir)
    if ! awk -F '\t' 'NR == 2 && $1 == "zroot" && $2 == "12" { found = 1 } END { exit found ? 0 : 1 }' \
        "$dir/inventory/poolprops.tsv"; then
        fail "в poolprops.tsv нет ashift 12"
    fi
    need "$dir/RESTORE.txt" "ashift=12"
    need "$STATE/run.log" "на диске 12"
    need "$STATE/run.log" "разный ashift"
    if [ -f "$dir/inventory/zpool-get-zroot.txt.err" ]; then
        fail "zpool get all завершился с ошибкой"
    fi
}

unit_parsers
unit_pipes
unit_config
test_doctor_dry
test_full
test_incremental
test_retention
test_send_failure
test_pre_hook
test_restore_guards
test_drill
test_ufs
test_cifs_mount
test_lock
test_encrypt_backup
test_raw_send
test_ashift_from_disk

left=$(find /tmp /var/tmp -maxdepth 1 \( -name 'cifsbak-run.*' -o -name 'cifsbak-enc.*' -o -name 'cifsbak-dec.*' -o -name 'cifsbak.*' \) -print | head)
if [ -n "$left" ]; then
    fail "после прогона остались временные каталоги: $left"
fi
printf 'все проверки прошли\n'
