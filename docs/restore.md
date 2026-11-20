# Восстановление FreeBSD из cifsbak

Команды ниже — общий порядок. Точные строки для конкретной машины уже
лежат в `RESTORE.txt` внутри бэкапа: имена дисков, ashift, bootfs и список
потоков взяты с сервера в момент копии. Если текст здесь и `RESTORE.txt`
расходятся, верен `RESTORE.txt`.

Носитель — установщик FreeBSD той же или более новой версии, чем исходная
система. Потоки, снятые на 14, не стоит принимать на 13.

Шара с бэкапом содержит те же секреты, что и сервер.

## 1. Добраться до копии

С установочного носителя поднимите сеть и смонтируйте шару:

```sh
mkdir -p /mnt/backup
mount_smbfs -I nas.example //backup@nas.example/freebsd-backup /mnt/backup
```

Пароль `mount_smbfs` спросит сам. Каталог хоста:

```sh
cd /mnt/backup/<hostname>
cat LATEST
cd <id из LATEST>
```

Проверка сумм, пока пул ещё не создан:

```sh
sh tool/bin/cifsbak verify
```

Если копия шифровалась, положите ключ, например в `/root/cifsbak.key`
(режим 600), и добавьте `--keyfile /root/cifsbak.key`. Без ключа `verify`
проверит только файлы и предупредит, что потоки не расшифрованы.

## 2. Диск и пул

Из каталога бэкапа, как написано в `RESTORE.txt`:

```sh
gpart restore -F nda0 < inventory/gpart/nda0.backup
dd if=inventory/efi/nda0p1.img of=/dev/nda0p1 bs=1m
```

Имена `nda0` и `nda0p1` на новой машине могут отличаться. Сверьте
`gpart show` с `inventory/gpart-list.txt` и подставьте свой диск. Образ ESP
пишется поверх уже созданного раздела `efi`, не на весь диск.

Если в `RESTORE.txt` есть строка `zpool create` — это один диск или один
mirror. Для raidz и нескольких vdev соберите пул по
`inventory/zpool-status-<пул>.txt`. Имя пула оставьте прежним, иначе
придётся поправлять `bootfs` и `fstab`.

```sh
zpool create -o ashift=12 -o altroot=/mnt -O mountpoint=none -O canmount=off zroot <диски>
```

`altroot=/mnt` обязателен: у датасета корня mountpoint `/`, и без altroot
приём лёг бы на живую систему установщика.

Дальше можно не набирать потоки руками:

```sh
zpool export zroot
zpool import -N -R /mnt zroot
sh tool/bin/cifsbak restore --yes
```

`-N` не монтирует датасеты при импорте. `restore` принимает цепочку от
полного бэкапа к выбранному инкременту, каждый поток с `zfs receive -u -F`,
и проверяет, что снимок после приёма существует. В пул, с которого загружена
текущая система, команда писать отказывается. Без абсолютного `altroot` тоже.

Флаг `-F` откатывает целевой датасет к потоку. На только что созданном пуле
откатывать нечего. На пуле, где уже лежат данные, они будут заменены.

Другой пул (другое имя) указывается явно:

```sh
sh tool/bin/cifsbak restore --yes --from zroot --to tank
```

`tank` должен быть импортирован с altroot. Имена датасетов внутри станут
`tank/...`. `bootfs` после этого поправьте сами.

Ручные команды из `RESTORE.txt` делают то же самое базовыми программами.
Для инкремента сначала идут строки `../<старший-id>/zfs/...`, потом потоки
текущего каталога. Порядок менять нельзя.

## 3. Загрузчик

```sh
zpool set bootfs=zroot/ROOT/default zroot
zpool set cachefile=/mnt/boot/zfs/zpool.cache zroot
zfs mount zroot/ROOT/default
test -f /mnt/etc/rc.conf && test -x /mnt/bin/sh
zpool export zroot
```

`zfs mount` здесь монтирует корень в `/mnt` за счёт altroot. Если этих
файлов нет, приём прошёл не туда или в копии не было корня.

Исключённые датасеты (`zroot/tmp` и подобные) в потоке отсутствуют.
`RESTORE.txt` содержит `zfs create` для них. Создайте до экспорта пула,
если они нужны пустыми.

Перезагрузка — с нового диска, уже без установщика.

### Если EFI не находится

Образ ESP мог не сняться (раздел больше `max_efi_mb` или устройства не было
в `/dev`). С установщика, пока пул ещё с altroot и корень смонтирован:

```sh
mount -t msdosfs /dev/nda0p1 /mnt/efi
mkdir -p /mnt/efi/efi/boot /mnt/efi/efi/freebsd
cp /mnt/boot/loader.efi /mnt/efi/efi/boot/bootx64.efi
cp /mnt/boot/loader.efi /mnt/efi/efi/freebsd/loader.efi
umount /mnt/efi
```

`/boot/loader.efi` с носителя тоже годится, если версия не старше системы.
Для схемы BIOS/GPT в `RESTORE.txt` есть `gpart bootcode` с `gptboot`, когда
на диске был раздел `freebsd-boot`.

## 4. UFS

ZFS-корень и отдельный UFS — разные команды. Дамп лежит в `ufs/`:

```sh
# новая ФС уже смонтирована, например в /mnt/var
sh tool/bin/cifsbak restore-ufs --yes --mountpoint /var --target /mnt/var
```

Каталог `--target` не может быть `/` и не должен лежать на корневой ФС
установщика: `restore` распаковывает дамп в текущий каталог. Та же команда
вручную есть в `RESTORE.txt` (`gzip -dc ... | (cd /mnt/ufs && restore -r -f -)`).
Подставьте свою точку монтирования вместо `/mnt/ufs`.

## 5. После загрузки

- `zpool status`, `zfs list`, `bectl list`.
- `fstab` и `rc.conf` из `inventory/` — это снимок настроек, не замена
  принятой системы. Сверьте, если меняли диск.
- Пакеты: `inventory/pkg-prime-list.txt` и `pkg-query.txt`.
- Смените ключи ssh хоста, если шара могла быть прочитана кем-то ещё.
  Они восстановились вместе с `/etc`.

## Частые ошибки

| Сообщение | Что сделать |
| --- | --- |
| пул держит корень системы | Вы загружены с этого пула. Нужен установщик или `cifsbak drill` на живой системе, а не `restore` в свой корень. |
| не задан altroot | `zpool export <пул> && zpool import -N -R /mnt <пул>` |
| пул не импортирован | Создайте его по `RESTORE.txt` и импортируйте с `-N -R /mnt`. |
| в бэкапе несколько пулов | `restore --from <пул>`. |
| приём не удался на инкременте | Не пропускайте полный бэкап в начале цепочки. `verify` проходит по всей цепочке. |
| поток не читается, копия зашифрована | `--keyfile`. Чужой ключ не подойдёт, суммы при этом могут сходиться. |
| drill: нет места | Увеличьте диск под `drill_dir` или уменьшите задачу: `drill_size_gb` не меньше занятых данных. |
| нет mount_smbfs на установщике | Он в базовой системе. Если носитель урезан, скопируйте каталог бэкапа на локальный диск заранее. |
