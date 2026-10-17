# Установка RefursWM и RefursLine

Пошаговая инструкция: от чистой системы до рабочего сеанса с баром. Команды даны для Void Linux (на нём всё и проверялось). Для других дистрибутивов смысл тот же, отличаются только имена пакетов — см. [«Другие дистрибутивы»](#другие-дистрибутивы).

- [RefursWM](https://github.com/FalconBinary/RefursWM) — композитор.
- [RefursLine](https://github.com/FalconBinary/RefursLine) — бар. Работает только внутри RefursWM.

Что получится в конце:

| Файл | Что это |
|---|---|
| `/usr/local/bin/refurswm` | композитор (wlroots, libinput, libseat внутри) |
| `/usr/local/share/refurswm/libinput/` | quirks libinput той же версии, что внутри композитора |
| `/usr/local/bin/refursline` | бар и все его меню, один статический бинарник |

Пути важны. RefursWM ищет quirks рядом с собой (`<каталог бинарника>/../share/refurswm/libinput`), а бару права выдаются по точному пути `/usr/local/bin/refursline`.

## 0. Что нужно

- Linux на x86_64 или aarch64.
- Видеокарта с KMS-драйвером (intel, amdgpu, nouveau, virtio-gpu и т. п.). Без GPU тоже заработает через pixman, только медленнее.
- Ядро 5.13+ с включённым Landlock (часть песочницы композитора; если в логе `landlock unavailable` — добавьте `landlock` в параметр ядра `lsm=`). Без Landlock RefursWM тоже работает, остаётся только seccomp.
- Обычный пользователь с доступом к `sudo` или `doas`. Собирать под root не нужно и не стоит.

> Не проверено на реальном железе: несколько мониторов, tearing, VRR, тачпады. Если что-то не так — см. [«Если не работает»](#если-не-работает).

## 1. Zig 0.17

Оба проекта собираются только Zig 0.17. Версия из репозитория дистрибутива почти наверняка другая, поэтому берём официальный архив.

```bash
ZIG=0.17.0 ARCH=$(uname -m)
```

```bash
curl -LO https://ziglang.org/download/$ZIG/zig-$ARCH-linux-$ZIG.tar.xz
```

Проверка подписи (по желанию, но лучше сделать; нужен пакет `minisign`, ключ — со страницы https://ziglang.org/download/):

```bash
curl -LO https://ziglang.org/download/$ZIG/zig-$ARCH-linux-$ZIG.tar.xz.minisig
```

```bash
minisign -Vm zig-$ARCH-linux-$ZIG.tar.xz -P RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
```

Распаковать в домашний каталог и добавить в `PATH`:

```bash
mkdir -p ~/.local/opt && tar -xJf zig-$ARCH-linux-$ZIG.tar.xz -C ~/.local/opt
```

```bash
echo 'export PATH="$HOME/.local/opt/zig-'$ARCH'-linux-'$ZIG':$PATH"' >> ~/.bashrc && . ~/.bashrc
```

```bash
zig version
```

Должно напечатать `0.17.0`.

## 2. Пакеты

### Для сборки

Заголовки библиотек, с которыми линкуется RefursWM. meson, ninja, cmake и python не нужны: wlroots, libinput и seatd Zig собирает сам. RefursLine не нужно ничего — у него нет зависимостей вообще.

```bash
sudo xbps-install -S git pkg-config wayland-devel wayland-protocols libxkbcommon-devel pixman-devel libdrm-devel libgbm-devel libglvnd-devel eudev-libudev-devel libdisplay-info-devel libevdev-devel mtdev-devel hwids
```

После сборки `*-devel` можно удалить.

### Для работы

```bash
sudo xbps-install -S seatd dbus dumb_runtime_dir mesa-dri xkeyboard-config foot swaylock grim dejavu-fonts-ttf iwd
```

| Пакет | Зачем |
|---|---|
| `seatd` | доступ к GPU и устройствам ввода без root и без logind |
| `dbus` | системная шина: через неё бар говорит с iwd и BlueZ |
| `dumb_runtime_dir` | создаёт `XDG_RUNTIME_DIR` (`/run/user/UID`) при входе; без него Wayland не стартует |
| `mesa-dri` | драйверы OpenGL; для Intel видео — ещё `intel-media-driver` |
| `xkeyboard-config` | раскладки клавиатуры |
| `foot` | терминал на `Super+Enter` |
| `swaylock` | блокировка экрана на `Super+L` |
| `grim` | снимок экрана на `Print` |
| `dejavu-fonts-ttf` | шрифт бара (подойдёт и Noto Sans; нужен именно `.ttf`) |
| `iwd` | Wi‑Fi в меню бара |

По желанию: `bluez` (Bluetooth в баре), `pipewire wireplumber` (звук), `swayidle`, `wl-clipboard`.

Если в системе уже работает NetworkManager или wpa_supplicant, Wi‑Fi в баре работать не будет: RefursLine умеет только iwd. Два менеджера Wi‑Fi одновременно включать нельзя.

## 3. Сборка

Собираем от обычного пользователя, ставим через `sudo`.

### RefursWM

```bash
git clone https://github.com/FalconBinary/RefursWM && cd RefursWM
```

```bash
zig build --prefix "$PWD/out"
```

Первая сборка скачивает исходники wlroots, libinput и seatd и проверяет их по хешу из `build.zig.zon` (нужен интернет, занимает несколько минут). Результат — `out/bin/refurswm` и `out/share/refurswm/libinput/`.

```bash
sudo install -Dm755 out/bin/refurswm /usr/local/bin/refurswm
```

```bash
sudo rm -rf /usr/local/share/refurswm/libinput && sudo mkdir -p /usr/local/share/refurswm && sudo cp -R out/share/refurswm/libinput /usr/local/share/refurswm/
```

```bash
cd ..
```

### RefursLine

```bash
git clone https://github.com/FalconBinary/RefursLine && cd RefursLine
```

```bash
zig build
```

```bash
sudo install -Dm755 zig-out/bin/refursline /usr/local/bin/refursline
```

```bash
cd ..
```

Версии должны совпадать: протокол `refurs-shell` между ними меняется в обоих репозиториях одновременно. Берите `main` обоих (или коммиты одного дня) и обновляйте их вместе.

## 4. Настройка системы

### Службы

```bash
sudo ln -s /etc/sv/dbus /etc/sv/seatd /etc/sv/iwd /var/service/
```

С Bluetooth — ещё `/etc/sv/bluetoothd`.

### Группы пользователя

```bash
sudo usermod -aG _seatd,netdev "$USER"
```

- `_seatd` — без неё seatd не даст композитору экран и клавиатуру;
- `netdev` — без неё iwd не пустит бар к списку сетей.

Группы применяются при следующем входе: выйдите из системы и зайдите снова.

### XDG_RUNTIME_DIR

В Void строка для `pam_dumb_runtime_dir` уже есть в `/etc/pam.d/system-login`, достаточно пакета из шага 2. Проверка после повторного входа:

```bash
echo "$XDG_RUNTIME_DIR"
```

Должно быть `/run/user/<ваш UID>`. Если пусто — Wayland-сокету негде жить, RefursWM не запустится.

### Перезагрузка и выключение из бара

Без systemd-logind бар выключает и перезагружает машину командами `doas -n /usr/bin/poweroff` и `doas -n /usr/bin/reboot` (если doas нет — то же через `sudo -n`). Им нужно узкое правило без пароля.

doas, в `/etc/doas.conf`:

```text
permit nopass YOURUSER as root cmd /usr/bin/reboot args
permit nopass YOURUSER as root cmd /usr/bin/poweroff args
```

или sudo, в `/etc/sudoers.d/refursline` (редактировать через `sudo visudo -f /etc/sudoers.d/refursline`):

```text
YOURUSER ALL=(root) NOPASSWD: /usr/bin/reboot, /usr/bin/poweroff
```

`YOURUSER` замените на своё имя. Сна и гибернации без logind в меню нет.

### Приоритет реального времени (по желанию)

Чтобы курсор и кадры не тормозили при полной загрузке процессора, разрешите группе `_seatd` минимальный rtprio. В `/etc/security/limits.conf`:

```text
@_seatd - rtprio 1
```

Без этого RefursWM работает как обычно. В логе при старте видно `realtime: on` или `off`.

## 5. Первый запуск

Перейдите на текстовую консоль (`Ctrl+Alt+F2`), войдите и запустите:

```bash
refurswm
```

Должны появиться:
- тёмный фон (`#1e1e2e`) и бар сверху — RefursWM сам запускает `/usr/local/bin/refursline`;
- `Super+Enter` открывает foot;
- `Super+Shift+E` — выход обратно в консоль.

Лог пишется в stderr. Чтобы сохранить его:

```bash
refurswm 2>"$XDG_RUNTIME_DIR/refurswm.log"
```

Все хоткеи — в [README RefursWM](https://github.com/FalconBinary/RefursWM#хоткеи-по-умолчанию), клики по бару — в [README RefursLine](https://github.com/FalconBinary/RefursLine#мышь).

## 6. Автозапуск при входе на tty1

Дисплейный менеджер не нужен. Добавьте в конец `~/.bash_profile`:

```bash
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = /dev/tty1 ]; then
	export XDG_SESSION_TYPE=wayland MOZ_ENABLE_WAYLAND=1
	exec refurswm 2>"$XDG_RUNTIME_DIR/refurswm.log"
fi
```

Из-за `exec` выход из RefursWM (`Super+Shift+E`) возвращает к приглашению входа. На других tty остаётся обычная консоль — пригодится, если сеанс не стартует.

## Если не работает

| Симптом | Причина и что делать |
|---|---|
| `XDG_RUNTIME_DIR is not set` или ошибка сокета | нет `dumb_runtime_dir` либо вы не перелогинились, см. шаг 4 |
| ошибка libseat про `/run/seatd.sock` или `Permission denied` | не запущен `seatd` или пользователь не в группе `_seatd` (и не перелогинился) |
| Чёрный экран или сразу выход | запустите с `REFURS_DEBUG=1`, затем с `REFURS_SANDBOX=0`. Если без песочницы работает — это её запрет, пришлите лог (с включённым audit запрет виден и в `dmesg`) |
| Нет бара, в логе `cannot run /usr/local/bin/refursline` | бар не установлен или лежит по другому пути. Путь задаётся в `src/config.zig` RefursWM (`pub const bar`) |
| `refursline`, запущенный из терминала, сразу выходит | так и должно быть: бар работает только когда его запустил RefursWM. Перезапуск бара — `Super+Shift+B` |
| Бар запустился, но столы пустые или бар падает после обновления | версии RefursWM и RefursLine разошлись, пересоберите оба из `main` |
| Меню Wi‑Fi пустое или пишет, что iwd нет | не запущен `iwd`, работает другой менеджер сети или пользователь не в группе `netdev` |
| Bluetooth не виден | не установлен `bluez` или не запущен `bluetoothd`; в некоторых дистрибутивах нужна ещё группа `bluetooth` |
| В баре квадратики вместо букв | нет TrueType-шрифта, поставьте `dejavu-fonts-ttf` или задайте свой путь в `font_paths` (`src/config.zig` RefursLine) |
| `Print` не делает снимок | grim установлен не в `/usr/bin/grim`; права на снимок выдаются по точному пути, поправьте `grants` в конфиге RefursWM |
| Неверная раскладка, тачпад, монитор | всё это в `src/config.zig` RefursWM, см. ниже |

## Настройка

Конфиги вкомпилированы, файлов в `~/.config` нет. Ошибка в конфиге — это ошибка сборки, а не сюрприз после входа.

- RefursWM: правите `src/config.zig` → шаг 3 для RefursWM → выходите из сеанса и заходите снова.
- RefursLine: правите `src/config.zig` → шаг 3 для RefursLine → `Super+Shift+B`.

Что где настраивается — в разделах «Конфиг» и «Настройка» README соответствующего проекта.

## Обновление

```bash
cd RefursWM && git pull && zig build --prefix "$PWD/out" && cd ..
```

```bash
cd RefursLine && git pull && zig build && cd ..
```

Затем те же команды `install` и `cp`, что в шаге 3, и перезапуск сеанса. Обновляйте оба проекта сразу.

## Удаление

```bash
sudo rm -rf /usr/local/bin/refurswm /usr/local/bin/refursline /usr/local/share/refurswm
```

И уберите блок автозапуска из `~/.bash_profile`, если добавляли.

## Другие дистрибутивы

Нужны те же вещи, под другими именами. Для сборки RefursWM `pkg-config` должен находить:

```text
wayland-server  wayland-protocols  xkbcommon  pixman-1  libdrm  gbm  egl  glesv2  libudev  libdisplay-info  libevdev  mtdev
```

а также `wayland-scanner` и база `hwids` (pci.ids / usb.ids). Для работы — `seatd` (или logind), Mesa, `xkeyboard-config`, iwd, TrueType-шрифт.

С systemd-logind:
- libseat внутри RefursWM собран только с seatd, поэтому `seatd` всё равно нужен (поставить, запустить, группа). Другой путь — `zig build -Dsystem-libs=true`: тогда берутся системные wlroots 0.20, libinput и libseat, а он умеет logind;
- `XDG_RUNTIME_DIR` создаёт сам logind;
- сон, гибернация, перезагрузка и выключение в баре работают через logind, правила doas/sudo не нужны.

Бар ищет шрифт по путям Arch, Void, Debian/Ubuntu и Fedora (`font_paths` в его конфиге). Если вашего пути там нет — допишите его первым.
