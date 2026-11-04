# keenetic-wgobfs

Модуль WireGuard для KeeneticOS со встроенным клиентом
[wg-obfuscator](https://github.com/ClusterM/wg-obfuscator) (протокол v1.6, маскировка STUN). Туннель
идёт прямо на сервер wg-obfuscator, без отдельного процесса на роутере. Режим включается у каждого
туннеля параметром AmneziaWG `I5`.

> **Статус.** Проверено на одном устройстве: Titan KN-1810, KeeneticOS 5.2 Beta 2. На остальных
> моделях модуль собирается из тех же исходников, но на устройствах не запускался.

## Как это работает

- **Патч** [`patches/wgobfs.patch`](patches/wgobfs.patch) к модулю
  [keenetic/wireguard](https://github.com/keenetic/wireguard) добавляет шифрование и расшифровку пакетов
  по протоколу wg-obfuscator. Код wg-obfuscator (GPL-3.0) не копируется: протокол реализован заново по
  описанию, совместимость проверяет тест с настоящим wg-obfuscator ([`test/`](test/)).
- **Включение.** Если в `I5` туннеля стоит значение с меткой `WGOB`, модуль включает обфускацию и
  игнорирует остальные параметры AmneziaWG (Jc, S, H, I1–I4) — пакеты до обфускации остаются обычными
  WireGuard. Формат: `<b 0x57474F42 01 MM DDDD КЛЮЧ>` — версия, маскировка (`00` нет, `01` STUN),
  max-dummy, байты ключа. Строку собирает `wgobfs-swap.sh i5 <ключ> STUN 4`.
- **Выбор модуля.** Пакет считает sha256 секции `.text` стандартного
  `/lib/modules/<ядро>/wireguard.ko` и ищет его в индексе. Совпадение значит, что стандартный модуль
  роутера скомпилирован ровно так же, как тот, из которого сделана наша сборка, — те же исходники и те же
  опции ядра. Нет совпадения (другая прошивка, неизвестная модель) — ничего не подменяется.
- **Подмена на ходу**, без перепрошивки: `rmmod` стандартного модуля, загрузка нашего с тем же номером
  семейства netlink (иначе KeeneticOS теряет связь с модулем), пересоздание интерфейсов `nwgN`, перезапуск
  туннелей. На флеш ничего не пишется: перезагрузка всегда возвращает стандартный модуль.
- **Автозапуск** `S05wgobfs` делает подмену при загрузке. Перед подменой на накопитель пишется отметка;
  если роутер упал посреди подмены, при следующей загрузке автозапуск выключается сам.
- **Режимы туннеля** (`wgobfs-mode.sh`): туннель связывается с секцией конфига внешнего
  wg-obfuscator и работает в режиме «встроенный», «внешний» или «авто» — встроенный, если модуль
  загружен, иначе внешний процесс. После обновления прошивки без подходящего модуля туннели в «авто» сами
  уходят на внешний обфускатор.

## Поддержка

KeeneticOS **5.2 Alpha 11 и новее**: с этой версии в KeeneticOS есть AmneziaWG (ASC 3.1). Это ревизии
модуля `1.0.20200623-24` … `-27` ([`revisions.conf`](revisions.conf)). Нужен Entware: модели без
поддержки накопителей сюда не входят (для них — [keenetic-firmware-obfs](https://github.com/artt652/keenetic-firmware-obfs)).

Одинаковый код стандартного модуля у моделей одной группы — одна сборка ([`variants.conf`](variants.conf)):

| Пакет | Вариант | Модели |
| --- | --- | --- |
| mipsel-3.4 | mt7621 | KN-1810, KN-1010, KN-1910, KN-1913, KN-2310, KN-2311, KN-2610, KN-2910 |
| mipsel-3.4 | mt7621-hm | KN-1011 |
| mipsel-3.4 | en7528 | KN-3810, KN-1912 |
| mipsel-3.4 | mt7628-1713 | KN-1713 |
| mips-3.4 | en7512 | KN-2011, KN-2012, KN-2111 |
| mips-3.4 | en7516 | KN-2410, KN-2112, KN-2510, KN-3610 |
| aarch64-3.10 | mt7622 | KN-2710, KN-1811 |
| aarch64-3.10 | mt7981 | KN-3811, KN-1012, KN-2312, KN-2313, KN-3611, KN-3812, KN-4110 |
| aarch64-3.10 | mt7988 | KN-1812, KN-4210 |

Ядро модели собирается из [keenetic-sdk](https://github.com/keenetic/keenetic-sdk) 5.01.C.8.0-2: SDK для
5.2 не опубликован. Для KN-1810 на 5.2 Beta 2 стандартный модуль из SDK совпал с модулем роутера байт в
байт. Для остальных это проверяет пакет на самом роутере (выбор модуля выше).

## Установка

Нужны Entware и, для пересоздания интерфейсов, `ip-full` (ставится зависимостью). Репозиторий
отдаётся по HTTPS, а busybox `wget`, которым по умолчанию пользуется opkg, HTTPS не умеет —
сначала `opkg install wget-ssl ca-certificates`.

```sh
opkg print-architecture                       # mipsel-3.4, mips-3.4 или aarch64-3.10
ARCH=mipsel-3.4
echo "src/gz wgobfs https://artt652.github.io/keenetic-wgobfs/$ARCH" >> /opt/etc/opkg.conf
opkg update && opkg install wgobfs-kmod
sh /opt/lib/wgobfs/wgobfs-swap.sh select     # какой модуль подошёл
sh /opt/lib/wgobfs/wgobfs-swap.sh swap       # подменить сейчас (или перезагрузить роутер)
```

Без репозитория — `.ipk` из [Releases](https://github.com/artt652/keenetic-wgobfs/releases):
`opkg install /opt/tmp/wgobfs-kmod_<версия>_<арх>.ipk`.

Если `select` пишет, что модуль не подходит, прошивка или модель не поддерживаются этой версией пакета;
подмены не будет.

## Настройка туннеля

Удобнее всего — вкладка «Встроенный» веб-панели
[wg-obfuscator-keenetic](https://github.com/artt652/wg-obfuscator-keenetic): режим туннеля, секция
обфускатора, автозапуск. Из консоли:

```sh
# режим «авто» по секции main из /opt/etc/wg-obfuscator.conf
sh /opt/lib/wgobfs/wgobfs-mode.sh set Wireguard0 auto main

# или вручную
I5=$(sh /opt/lib/wgobfs/wgobfs-swap.sh i5 '<ключ>' STUN 4)
ndmc -c "interface Wireguard0 wireguard asc 0 0 0 0 0 1 2 3 4 0 0 \"\" \"\" \"\" \"\" \"$I5\""
ndmc -c 'interface Wireguard0 wireguard peer <ключ пира> endpoint <сервер>:<порт обфускатора>'
ndmc -c 'system configuration save'
dmesg | grep wg-obfuscator                    # wg-obfuscator mode on
```

Проверка: `/opt/etc/init.d/S05wgobfs status`, `ndmc -c 'show interface Wireguard0'`.

## Удаление

Изменённый модуль остаётся в памяти до перезагрузки, а настройки туннелей (I5 и endpoint сервера) — в
конфигурации роутера. Если удалить пакет, не вернув их, после перезагрузки туннели во встроенном режиме
пойдут на сервер без обфускации и не подключатся. Поэтому порядок такой:

1. **Вернуть туннели на внешний обфускатор** — для каждого туннеля, у которого задан режим:

    ```sh
    sh /opt/lib/wgobfs/wgobfs-mode.sh list                          # какие туннели под управлением
    sh /opt/lib/wgobfs/wgobfs-mode.sh set Wireguard0 external main  # endpoint 127.0.0.1:<порт>, I5 сброшен
    ```

    Туннель, где I5 задавали вручную (без секции), возвращается командами роутера:

    ```sh
    ndmc -c 'interface Wireguard0 wireguard asc 0 0 0 0 0 1 2 3 4 0 0 "" "" "" "" ""'
    ndmc -c 'interface Wireguard0 wireguard peer <ключ пира> endpoint 127.0.0.1:<порт обфускатора>'
    ndmc -c 'system configuration save'
    ```

    Если внешний обфускатор больше не нужен, вместо этого укажите в туннеле адрес самого сервера WireGuard.

2. **Удалить пакет и перезагрузить роутер** — перезагрузка возвращает стандартный модуль:

    ```sh
    opkg remove wgobfs-kmod
    ndmc -c 'system reboot'
    ```

3. **Убрать оставшиеся файлы** (по желанию): пакет не удаляет режимы туннелей и состояние автозапуска.

    ```sh
    rm -rf /opt/etc/wgobfs-tunnels.conf /opt/var/lib/wgobfs
    sed -i '/keenetic-wgobfs/d' /opt/etc/opkg.conf                  # строка репозитория
    ```

    `ip-full`, поставленный зависимостью, можно оставить или удалить: `opkg remove ip-full`.

Проверка после перезагрузки: файла `/sys/module/wireguard/parameters/genl_id` нет (загружен стандартный
модуль), туннели на связи в веб-интерфейсе роутера.

## Сборка

```sh
scripts/build-variant.sh mt7621      # SDK, ядро модели, тулчейн, модули всех ревизий → out/mt7621/
scripts/build-ipk.sh mipsel-3.4      # пакет из готовых вариантов этой архитектуры → out/
scripts/make-feed.sh                 # opkg-репозиторий → dist/
test/run.sh                          # тест кодека против wg-obfuscator v1.6
```

Запускать от обычного пользователя (SDK не работает от root), нужны пакеты из README keenetic-sdk, `xxd`
и `zstd`. GitHub Actions собирает всё на каждый push; тег `vX.Y-Z` выпускает релиз и публикует
репозиторий на GitHub Pages.

Новая ревизия модуля — строка в `revisions.conf`. Новая модель — сначала проверить, с каким вариантом
совпадает её стандартный модуль (или завести новый вариант), затем строка в `variants.conf`.

## Состав

| Путь | Что |
| --- | --- |
| `patches/wgobfs.patch` | патч модуля: `wgobfs.c`, `wgobfs.h` и правки `socket.c`, `receive.c`, `netlink.c`, `device.c` |
| `tools/wgobfs-tool.c` | утилита для роутера: `genlid`, `kmload`, `texthash` |
| `files/` | `wgobfs-swap.sh`, `wgobfs-mode.sh`, init-скрипт `S05wgobfs` |
| `scripts/` | сборка вариантов, пакетов, репозитория |
| `test/` | тест кодека |
| `variants.conf`, `revisions.conf` | что собирать |

## Лицензия

GPL-2.0, как у модуля WireGuard. wg-obfuscator — © ClusterM, GPL-3.0; в репозиторий не входит.
