# Dart Server: многоэтапная сборка Docker

Простой HTTP-сервер на Dart, на котором показан подход к созданию лёгкого образа:
приложение **собирается в одном образе** (`dart:stable`), а **запускается в другом** (`alpine`),
куда копируется только готовый исполняемый файл.

## Структура проекта

```
.
├── bin/server.dart       # исходный код сервера
├── pubspec.yaml          # описание проекта и зависимостей
├── pubspec.lock
├── Dockerfile            # многоэтапная сборка (build → alpine)
├── docker-compose.yml    # сборка и запуск
├── .env                  # конфигурация (переменные окружения)
└── .dockerignore
```

## Требования

- Docker 23+ (с BuildKit, включён по умолчанию)
- Docker Compose v2 (`docker compose`)
- Dart SDK 3.x — только для запуска без Docker

## Быстрый старт

```bash
docker compose up -d --build
curl http://localhost:8080/
```

Остановка:

```bash
docker compose down
```

## Конфигурация

Все настройки задаются через переменные окружения.

| Переменная  | По умолчанию        | Описание                                       |
|-------------|---------------------|------------------------------------------------|
| `HOST`      | `0.0.0.0`           | Адрес, на котором слушает сервер               |
| `PORT`      | `8080`              | Порт сервера внутри контейнера                 |
| `APP_ENV`   | `production`        | Название окружения (выводится в `/info`)       |
| `GREETING`  | `Привет из Docker!` | Текст приветствия на `/`                       |
| `HOST_PORT` | `8080`              | Порт на хосте (используется только в compose)  |

Значения по умолчанию заданы в `Dockerfile` (`ENV`), для compose их можно переопределить в файле `.env`:

```env
HOST_PORT=8080
PORT=8080
APP_ENV=production
GREETING=Привет из docker compose!
```

После изменения `.env` пересобирать образ не нужно, достаточно пересоздать контейнер:

```bash
docker compose up -d
```

## HTTP-адреса

| Адрес              | Ответ                                                                    |
|--------------------|--------------------------------------------------------------------------|
| `/`                | Приветствие и список адресов                                             |
| `/health`          | `{"status": "ok"}` (используется в healthcheck)                          |
| `/info`            | hostname (ID контейнера), ОС, пользователь, окружение, версия Dart, время работы, число запросов |
| `/echo?text=...`   | Возвращает переданный текст                                              |

Пример ответа `/info`:

```json
{
  "hostname": "8ecbd1a1cd1d",
  "os": "linux",
  "user": "app",
  "appEnv": "production",
  "dartVersion": "3.13.5",
  "uptimeSeconds": 12,
  "requests": 3
}
```

## Запуск через Docker Compose

```bash
docker compose build              # только сборка образа
docker compose up -d              # запуск в фоне
docker compose up -d --build      # сборка и запуск
docker compose ps                 # статус (должен быть healthy)
docker compose logs -f            # логи запросов
docker compose exec app id        # проверка пользователя: uid=100(app)
docker compose restart            # перезапуск
docker compose down               # остановка и удаление контейнера
```

## Запуск через Docker без Compose

```bash
# Сборка
docker build -t dart-server .

# Сборка с другими версиями базовых образов
docker build --build-arg DART_VERSION=3.5 --build-arg ALPINE_VERSION=3.21 -t dart-server .

# Запуск с настройками по умолчанию
docker run -d --name dart-demo -p 8080:8080 dart-server

# Запуск со своими настройками
docker run -d --name dart-demo2 -p 9090:9090 \
  -e PORT=9090 -e APP_ENV=staging -e GREETING="Hello!" \
  dart-server

# Запуск с настройками из файла
docker run -d --name dart-demo3 --env-file .env -p 8080:8080 dart-server

# Логи, остановка, удаление
docker logs -f dart-demo
docker stop dart-demo && docker rm dart-demo
```

## Запуск без Docker

```bash
dart pub get
dart run bin/server.dart

# со своими настройками (bash)
PORT=3000 GREETING="Локально" dart run bin/server.dart
```

PowerShell:

```powershell
$env:PORT = "3000"; dart run bin/server.dart
```

## Как устроен Dockerfile

### Этап 1: сборка (`dart:stable`)

1. Копируются только `pubspec.yaml` и `pubspec.lock`, затем выполняется `dart pub get`.
   Этот слой пересобирается **только при изменении зависимостей**.
2. Отдельно копируется `bin/`, и код компилируется в нативный файл: `dart compile exe`.
   При изменении исходников заново выполняется только этот шаг.
3. Кэш пакетов pub (`/root/.pub-cache`) подключается с хоста как кэш BuildKit
   (`RUN --mount=type=cache`) и в образ не попадает.

### Этап 2: запуск (`alpine`)

1. `apk add --no-cache gcompat` ставит слой совместимости с glibc: Dart собирает программу под glibc,
   а в alpine используется musl. Флаг `--no-cache` не оставляет кэш apk в образе.
2. Создаётся системный пользователь `app` без shell и домашнего каталога.
3. Из первого этапа копируется только файл `/app/server`.
4. В `ENV` задаются значения по умолчанию.
5. `USER app:app` — контейнер запускается **не от root**.
6. `HEALTHCHECK` раз в 15 секунд запрашивает `/health`.

В `docker-compose.yml` дополнительно включены `read_only: true` (файловая система только для чтения)
и `no-new-privileges` (запрет повышения привилегий).

## Проверка требований

```bash
# 1. Размер образа (около 23 МБ). Для сравнения можно скачать сборочный образ:
docker images dart-server
docker pull dart:stable && docker images dart

# 2. Базовый образ — alpine
docker compose exec app cat /etc/os-release

# 3. Пользователь не root
docker compose exec app id
docker compose exec app whoami

# 4. В образе только артефакт, исходников нет
docker compose exec app ls -la /app

# 5. Настройки берутся из переменных окружения
docker compose exec app env | grep -E 'HOST|PORT|APP_ENV|GREETING'
curl http://localhost:8080/

# 6. Кэширование слоёв: измените bin/server.dart и пересоберите.
#    Шаги «dart pub get» и «apk add» будут CACHED.
docker compose build --progress=plain

# 7. Слои образа
docker history dart-server
```

## Возможные проблемы

| Проблема | Решение |
|----------|---------|
| `failed to connect to the docker API ... dockerDesktopLinuxEngine` | Запустите Docker Desktop |
| `port is already allocated` | Измените `HOST_PORT` в `.env` или освободите порт 8080 |
| `the --mount option requires BuildKit` | `export DOCKER_BUILDKIT=1` (в старых версиях Docker) |
| Контейнер `unhealthy` | `docker compose logs`, проверьте, что `PORT` совпадает с портом в `ports` |
