# Чтение конфигурации. Неизвестный параметр — ошибка, чтобы опечатка не молчала.

cb_config_defaults() {
    cfg_destination=
    cfg_cifs_mode=nomount
    cfg_cifs_host=
    cfg_cifs_share=
    cfg_cifs_user=
    cfg_cifs_password=
    cfg_cifs_password_file=
    cfg_cifs_workgroup=
    cfg_backup_mode=full
    cfg_full_every_days=7
    cfg_keep_copies=3
    cfg_keep_source_snapshots=2
    cfg_compress=auto
    cfg_encrypt_keyfile=
    cfg_snapshot_prefix=cifsbak
    cfg_pre_hook=
    cfg_post_hook=
    cfg_min_free_mb=2048
    cfg_max_efi_mb=768
    cfg_send_attempts=2
    cfg_nice_level=10
    cfg_allow_same_pool=no
    cfg_mail_to=
    cfg_drill_dir=/var/tmp
    cfg_drill_size_gb=8
}

cb_is_uint() {
    case $1 in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

cb_append_words() {
    file=$1
    val=$2
    rest=$val
    while [ -n "$rest" ]; do
        item=${rest%% *}
        case $rest in
            *" "*) rest=${rest#* } ;;
            *) rest= ;;
        esac
        [ -n "$item" ] || continue
        printf '%s\n' "$item" >>"$file"
    done
}

cb_set_cfg() {
    key=$1
    val=$2
    case $key in
        destination) cfg_destination=$val ;;
        cifs_mode) cfg_cifs_mode=$val ;;
        cifs_host) cfg_cifs_host=$val ;;
        cifs_share) cfg_cifs_share=$val ;;
        cifs_user) cfg_cifs_user=$val ;;
        cifs_password) cfg_cifs_password=$val ;;
        cifs_password_file) cfg_cifs_password_file=$val ;;
        cifs_workgroup) cfg_cifs_workgroup=$val ;;
        backup_mode) cfg_backup_mode=$val ;;
        full_every_days) cfg_full_every_days=$val ;;
        keep_copies) cfg_keep_copies=$val ;;
        keep_source_snapshots) cfg_keep_source_snapshots=$val ;;
        compress) cfg_compress=$val ;;
        encrypt_keyfile) cfg_encrypt_keyfile=$val ;;
        snapshot_prefix) cfg_snapshot_prefix=$val ;;
        pre_hook) cfg_pre_hook=$val ;;
        post_hook) cfg_post_hook=$val ;;
        min_free_mb) cfg_min_free_mb=$val ;;
        max_efi_mb) cfg_max_efi_mb=$val ;;
        send_attempts) cfg_send_attempts=$val ;;
        nice_level) cfg_nice_level=$val ;;
        allow_same_pool) cfg_allow_same_pool=$val ;;
        mail_to) cfg_mail_to=$val ;;
        drill_dir) cfg_drill_dir=$val ;;
        drill_size_gb) cfg_drill_size_gb=$val ;;
        pools) cb_append_words "$cfg_pool_file" "$val" ;;
        exclude_datasets) cb_append_words "$cfg_exclude_file" "$val" ;;
        exclude_file)
            [ -f "$val" ] || cb_die "нет exclude_file: $val"
            while IFS= read -r line || [ -n "$line" ]; do
                line=$(printf '%s' "$line" | tr -d '\r')
                case $line in
                    ''|\#*) continue ;;
                esac
                printf '%s\n' "$line" >>"$cfg_exclude_file"
                line=
            done <"$val"
            ;;
        *) cb_die "неизвестный параметр в конфиге: $key" ;;
    esac
}

cb_load_config() {
    file=$1
    [ -f "$file" ] || cb_die "нет файла конфигурации: $file"
    cfg_file=$file
    if [ -z "${cb_runtime:-}" ]; then
        cb_runtime=$(mktemp -d "${TMPDIR:-/tmp}/cifsbak-run.XXXXXX")
        chmod 700 "$cb_runtime"
    fi
    cfg_exclude_file=$cb_runtime/excludes
    cfg_pool_file=$cb_runtime/pools.conf
    : >"$cfg_exclude_file"
    : >"$cfg_pool_file"
    cb_config_defaults
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case $line in
            ''|\#*) continue ;;
        esac
        case $line in
            *=*) ;;
            *) cb_die "строка конфига без '=': $line" ;;
        esac
        key=${line%%=*}
        val=${line#*=}
        key=$(printf '%s' "$key" | sed 's/[[:space:]]*$//')
        val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//')
        case $val in
            \"*\") val=${val#\"}; val=${val%\"} ;;
            \'*\') val=${val#\'}; val=${val%\'} ;;
        esac
        case $key in
            ''|*[!A-Za-z0-9_]*) cb_die "странное имя параметра: $key" ;;
        esac
        cb_set_cfg "$key" "$val"
        line=
    done <"$file"
}

cb_validate_config() {
    [ -n "$cfg_destination" ] || cb_die "в конфиге не задан destination"
    [ "$cfg_destination" != / ] || cb_die "destination не может быть /"
    case $cfg_destination in
        /*) ;;
        *) cb_die "destination должен быть абсолютным путём: $cfg_destination" ;;
    esac
    case $cfg_cifs_mode in
        mount|nomount) ;;
        *) cb_die "cifs_mode должен быть mount или nomount" ;;
    esac
    case $cfg_backup_mode in
        full|auto) ;;
        *) cb_die "backup_mode должен быть full или auto" ;;
    esac
    case $cfg_allow_same_pool in
        yes|no) ;;
        *) cb_die "allow_same_pool должен быть yes или no" ;;
    esac
    case $cfg_compress in
        auto|none|gzip|xz|zstd) ;;
        *) cb_die "compress должен быть auto, zstd, xz, gzip или none" ;;
    esac
    cb_is_uint "$cfg_full_every_days" || cb_die "full_every_days должен быть целым числом"
    cb_is_uint "$cfg_keep_copies" || cb_die "keep_copies должен быть целым числом"
    [ "$cfg_keep_copies" -ge 1 ] || cb_die "keep_copies должен быть не меньше 1"
    cb_is_uint "$cfg_keep_source_snapshots" || cb_die "keep_source_snapshots должен быть целым числом"
    [ "$cfg_keep_source_snapshots" -ge 1 ] || cb_die "keep_source_snapshots должен быть не меньше 1"
    cb_is_uint "$cfg_min_free_mb" || cb_die "min_free_mb должен быть целым числом"
    cb_is_uint "$cfg_max_efi_mb" || cb_die "max_efi_mb должен быть целым числом"
    cb_is_uint "$cfg_send_attempts" || cb_die "send_attempts должен быть целым числом"
    [ "$cfg_send_attempts" -ge 1 ] && [ "$cfg_send_attempts" -le 10 ] || cb_die "send_attempts должен быть от 1 до 10"
    cb_is_uint "$cfg_nice_level" || cb_die "nice_level должен быть целым числом"
    [ "$cfg_nice_level" -le 20 ] || cb_die "nice_level должен быть от 0 до 20"
    cb_is_uint "$cfg_drill_size_gb" || cb_die "drill_size_gb должен быть целым числом"
    [ "$cfg_drill_size_gb" -ge 1 ] && [ "$cfg_drill_size_gb" -le 1024 ] || cb_die "drill_size_gb должен быть от 1 до 1024"
    cb_assert_prefix "$cfg_snapshot_prefix"
    if [ "$cfg_cifs_mode" = mount ]; then
        [ -n "$cfg_cifs_host" ] || cb_die "для cifs_mode=mount нужен cifs_host"
        [ -n "$cfg_cifs_share" ] || cb_die "для cifs_mode=mount нужен cifs_share"
        [ -n "$cfg_cifs_user" ] || cb_die "для cifs_mode=mount нужен cifs_user"
        case $cfg_cifs_host in
            *[!A-Za-z0-9._-]*) cb_die "cifs_host содержит неподдерживаемый символ" ;;
        esac
        share_bad=$(printf '%s' "$cfg_cifs_share" | tr -d 'A-Za-z0-9._$-')
        [ -z "$share_bad" ] || cb_die "cifs_share содержит неподдерживаемый символ"
        case $cfg_cifs_user in
            ''|*@*|*/*|*\\*|*[[:space:]]*) cb_die "cifs_user не должен содержать @, / или пробел. Домен укажите в cifs_workgroup" ;;
        esac
        pass=$(cb_cifs_password || true)
        if [ -z "$pass" ] || [ "$pass" = "CHANGE-ME" ]; then
            cb_die "задайте пароль CIFS в cifs_password или cifs_password_file"
        fi
        case $pass in
            *"
"*) cb_die "пароль CIFS не должен содержать перевод строки" ;;
        esac
        if [ -n "$cfg_cifs_password" ]; then
            cb_assert_private "$cfg_file" "конфиг с паролем"
        fi
        if [ -n "$cfg_cifs_password_file" ]; then
            cb_assert_private "$cfg_cifs_password_file" "файл пароля"
        fi
    fi
    if [ -n "$cfg_encrypt_keyfile" ]; then
        [ -f "$cfg_encrypt_keyfile" ] || cb_die "нет encrypt_keyfile: $cfg_encrypt_keyfile"
        [ -s "$cfg_encrypt_keyfile" ] || cb_die "encrypt_keyfile пуст"
        cb_assert_private "$cfg_encrypt_keyfile" "файл ключа"
    fi
    if [ -n "${opt_keyfile:-}" ]; then
        [ -f "$opt_keyfile" ] || cb_die "нет --keyfile: $opt_keyfile"
        cb_assert_private "$opt_keyfile" "файл ключа"
    fi
    while IFS= read -r ex || [ -n "$ex" ]; do
        if [ -n "$ex" ]; then
            cb_assert_dataset "$ex"
        fi
        ex=
    done <"$cfg_exclude_file"
    while IFS= read -r pool || [ -n "$pool" ]; do
        if [ -n "$pool" ]; then
            cb_assert_pool "$pool"
        fi
        pool=
    done <"$cfg_pool_file"
}

cb_cifs_password() {
    if [ -n "$cfg_cifs_password_file" ]; then
        [ -f "$cfg_cifs_password_file" ] || cb_die "нет файла пароля $cfg_cifs_password_file"
        lines=$(awk 'END {print NR+0}' "$cfg_cifs_password_file")
        [ "$lines" -le 1 ] || cb_die "файл пароля должен состоять из одной строки"
        IFS= read -r pass <"$cfg_cifs_password_file" || true
        printf '%s' "$pass"
        return 0
    fi
    printf '%s' "$cfg_cifs_password"
}

cb_find_default_config() {
    for cand in ${CIFSBAK_CONFIG:-} /usr/local/etc/cifsbak.conf /etc/cifsbak.conf ./cifsbak.conf; do
        [ -n "$cand" ] || continue
        if [ -f "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

cb_need_config() {
    if [ -n "${cfg_loaded:-}" ]; then
        return 0
    fi
    if [ -z "${opt_config:-}" ]; then
        opt_config=$(cb_find_default_config || true)
    fi
    [ -n "${opt_config:-}" ] || cb_die "не найден конфиг. Укажите -c путь или положите /usr/local/etc/cifsbak.conf"
    case $opt_config in
        /*) ;;
        *) opt_config=$(pwd)/$opt_config ;;
    esac
    cb_load_config "$opt_config"
    cb_validate_config
    cfg_loaded=1
}

cb_write_sanitized_config() {
    dest=$1
    [ -n "${cfg_file:-}" ] || return 0
    [ -f "$cfg_file" ] || return 0
    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            key = line
            sub(/^[[:space:]]*/, "", key)
            if (key ~ /^#/ || key == "") { print line; next }
            name = key
            sub(/=.*/, "", name)
            gsub(/[[:space:]]/, "", name)
            if (name == "cifs_password") { print "cifs_password=***"; next }
            print line
        }
    ' "$cfg_file" >"$dest"
}
