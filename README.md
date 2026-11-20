# cifsbak

Бэкап сервера FreeBSD на шару CIFS, из которого систему можно поднять заново.
Копия — это потоки `zfs send` (и `dump` для UFS), разметка диска, образ EFI и
файл `RESTORE.txt`. Это не архив tar: файлы по одному из него не достают,
зато пул принимается целиком командой `zfs receive`.

Программа — один сценарий на `/bin/sh`. Порты, bash и Python не нужны.
На шару рядом с данными кладётся сама утилита, поэтому с установочного
носителя достаточно каталога бэкапа.

Имена каталогов — время UTC (`20260115T030000Z`). Расписание cron — локальное
время сервера.

## Что сохраняется

- Рекурсивный снимок каждого пула ZFS, затем `zfs send -p` по каждому
  датасету. Чужие снимки в поток не входят: `-R` не используется.
  Зашифрованный датасет уходит как `zfs send -w`, иначе ключ ZFS на приёме
  не понадобится.
- Дамп каждой смонтированной ФС UFS (`dump -0aL`, при неудаче без `-L`).
- `gpart backup`, список разделов и образ раздела `efi`, если он не больше
  `max_efi_mb`.
- Свойства пула: ashift, bootfs, autoexpand, autotrim, `zpool status`.
- Копии `fstab`, `rc.conf`, `loader.conf`, список BE и установленных пакетов.
- Сам `cifsbak` и `RESTORE.txt` с командами для установщика.

Снимок атомарный на весь пул, в том числе на датасеты из `exclude_datasets`.
Исключённые датасеты в поток не пишутся: после восстановления их создают
пустыми, команда для этого есть в `RESTORE.txt`.

## Требования

- FreeBSD 13 или новее, запуск от root.
- `zfs`, `zpool`, `gpart`, `dump` / `restore` — из базовой системы.
- Для шары: `mount_smbfs` (тоже базовая система).
- Сжатие: `zstd`, `xz` или `gzip`. По умолчанию берётся первая найденная.
- Для `encrypt_keyfile` — `openssl` из базы.

## Перенос на сервер

На сервер едут только сценарии. Собирать нечего, порты ставить не нужно.
`tests/` и `docs/` на FreeBSD не копируйте: это проверка и инструкция,
они работают без сервера.

С машины, где лежит этот каталог и откуда есть ssh до сервера:

```sh
tar czf /tmp/cifsbak.tar.gz bin lib Makefile cifsbak.conf.example contrib
scp /tmp/cifsbak.tar.gz root@server:/root/
ssh root@server
tar xzf cifsbak.tar.gz
make install
```

Без make те же файлы кладутся так:

```sh
install -d /usr/local/sbin /usr/local/libexec/cifsbak /usr/local/etc
install -m 755 bin/cifsbak /usr/local/sbin/cifsbak
install -m 644 lib/*.sh /usr/local/libexec/cifsbak/
install -m 644 cifsbak.conf.example /usr/local/etc/cifsbak.conf.example
```

## Установка

Если файлы уже на сервере:

```sh
make install
cp /usr/local/etc/cifsbak.conf.example /usr/local/etc/cifsbak.conf
chmod 600 /usr/local/etc/cifsbak.conf
```

Библиотеки ставятся в `/usr/local/libexec/cifsbak`. Каталог `contrib/`
устанавливать не обязательно: это пример cron и periodic.

## Шара

Пароли, `master.passwd` и ключи ssh хоста оказываются внутри потоков.
Права на шару должны быть такими же, как на сам сервер. Не открывайте её
на запись всем пользователям NAS.

### Уже смонтирована (предпочтительно)

`/etc/fstab`:

```
//backup@nas.example/freebsd-backup /mnt/backup smbfs rw,late,-N,-I=nas.example 0 0
```

`/etc/nsmb.conf`, режим 600:

```
[NAS.EXAMPLE:BACKUP]
addr=nas.example
password=секрет
workgroup=WORKGROUP
```

Имя хоста в квадратных скобках — в верхнем регистре. В конфиге cifsbak:

```
destination=/mnt/backup
cifs_mode=nomount
```

Пользователь в fstab и секция `nsmb.conf` должны совпадать. Домен, если он
есть, задаётся `workgroup`, а не суффиксом `@` в имени.

### Монтирует сам cifsbak

```
cifs_mode=mount
cifs_host=nas.example
cifs_share=freebsd-backup
cifs_user=backup
cifs_password=секрет
cifs_workgroup=WORKGROUP
```

Пароль можно вынести в `cifs_password_file` (одна строка, режим 600).
Пока в конфиге написано `CHANGE-ME` или файл доступен группе, `cifsbak`
отказывается стартовать и пароль в журнал не пишет. После бэкапа шара
размонтируется. Пароль в копию не попадает: в сохранённом конфиге стоит
`cifs_password=***`.

Не ставьте `destination` на тот же пул, который сохраняете. Копия заполнит
единственный диск. `allow_same_pool=yes` снимает этот запрет, но не лечит
проблему.

## Первый запуск

```sh
cifsbak doctor
cifsbak backup
cifsbak verify
cifsbak list
cifsbak drill --yes
```

`doctor` ничего не меняет: проверяет конфиг, сжатие и список пулов.
`backup --dry-run` показывает датасеты и не снимает снимок.
`verify` сверяет контрольные суммы и, если есть `zstream`, разбирает потоки.
`drill` принимает копию во временный файловый пул `cifsbakdrill` и проверяет,
что в корне видны `/etc/rc.conf`, `/bin/sh` или `/boot/loader.conf`. Пул
после этого удаляется.

`drill_size_gb` должен вмещать занятые данные отправляемых датасетов.
`drill_dir` по умолчанию `/var/tmp`: на живой системе это часто тот же пул,
который вы сохраняете. Нужен свободный объём размером с `drill_size_gb`,
иначе проверка места остановит команду до создания файла.

## Расписание

`/etc/periodic.conf`:

```
daily_cifsbak_enable="YES"
```

Скрипт: `contrib/900.cifsbak`, путь установки
`/usr/local/etc/periodic/daily/900.cifsbak`.

Либо cron, время локальное для сервера. Пример в `contrib/crontab.example`:

```
15 3 * * * root /usr/local/sbin/cifsbak backup
```

Письмо в конце бэкапа уходит через `mail(1)`, если задан `mail_to`.

## Полная копия и инкремент

`backup_mode=full` (значение по умолчанию) — каждая копия независима.
Так проще восстанавливать, и сломанный инкремент не тянет за собой цепочку.

`backup_mode=auto` пишет инкремент от последней успешной копии, пока её
базовый полный бэкап моложе `full_every_days`. `cifsbak backup --full`
форсирует полный. Возраст считается по полному бэкапу в начале цепочки,
а не по последнему инкременту.

`keep_copies` оставляет столько новейших точек и всех их предков. Инкремент
без базы не хранится. На сервере остаются снимки `cifsbak-*`, не больше
`keep_source_snapshots`, плюс снимок только что отправленной копии и его
родитель. Чужие снимки не удаляются. Если отправка оборвалась, новый снимок
снимается, чтобы не вытеснить последний хороший.

## Шифрование

`encrypt_keyfile` — файл с парольной фразой. Поток сжимается, затем
шифруется `openssl enc -aes-256-cbc -pbkdf2`. Ключ на шару не копируется.
Без него `verify` проверяет только суммы и предупреждает, `restore` и
`drill` останавливаются. Это отдельный слой поверх шифрования датасетов ZFS.

## Каталог на шаре

```
/mnt/backup/<hostname>/LATEST
/mnt/backup/<hostname>/<id>/RESTORE.txt
/mnt/backup/<hostname>/<id>/MANIFEST
/mnt/backup/<hostname>/<id>/meta/backup.env
/mnt/backup/<hostname>/<id>/meta/streams.tsv
/mnt/backup/<hostname>/<id>/zfs/0001.gz
/mnt/backup/<hostname>/<id>/ufs/0001.gz
/mnt/backup/<hostname>/<id>/inventory/
/mnt/backup/<hostname>/<id>/tool/bin/cifsbak
```

`LATEST` — текстовый файл, не ссылка: CIFS и Windows плохо переносят
симлинки. Имена потоков — порядковые номера. Соответствие датасету лежит
в `meta/streams.tsv`. Незавершённый прогон пишется в `.partial.*` и
удаляется, каталог `<id>` появляется одним переименованием.

## Восстановление

Команды, которые относятся к конкретной копии, лежат в её `RESTORE.txt`.
Общий порядок — в [docs/restore.md](docs/restore.md). Коротко: загрузка с
установочного носителя той же или более новой FreeBSD, разметка, `zpool
import -N -R /mnt`, затем

```sh
sh tool/bin/cifsbak restore --yes
```

из каталога бэкапа. Приём идёт с `zfs receive -u -F` и отказывается писать
в пул, с которого сейчас загружена система.

UFS:

```sh
cifsbak restore-ufs --yes --mountpoint /var --target /mnt/var
```

## Ограничения

- Топологию raidz, draid, несколько vdev, log, cache, special и spare
  утилита не угадывает. В `RESTORE.txt` будет отказ, а `zpool status`
  сохранён в `inventory/`: пул собираете вы.
- Клон (`origin` не `-`) отправляется как обычный датасет. Если приём
  оборвётся из‑за отсутствующего origin, исключите клон или сохраняйте
  origin вместе с ним.
- Исключённые датасеты после `receive` нужно создать заново. Они пустые.
- CIFS может игнорировать `chmod`. Каталог бэкапа защищайте правами шары,
  а не правами файлов на ней.
- `drill` занимает место на диске, где лежит `drill_dir`.
- Снимок — состояние на момент сбоя, не снимок приложения. Для PostgreSQL
  перед ним имеет смысл `CHECKPOINT` (пример в `cifsbak.conf.example`).

## Проверка самого cifsbak

На машине без FreeBSD, с подменой `zfs` и `zpool`:

```sh
make test
```
