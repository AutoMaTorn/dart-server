# syntax=docker/dockerfile:1

ARG DART_VERSION=stable
ARG ALPINE_VERSION=3.22

# ============================================================
# Этап 1: сборка. Компилируем Dart-код в нативный исполняемый файл.
# ============================================================
FROM dart:${DART_VERSION} AS build

WORKDIR /app

# Сначала копируем только описание зависимостей: слой с `dart pub get`
# пересобирается только при изменении pubspec.yaml / pubspec.lock.
# Кэш пакетов pub монтируется с хоста (BuildKit cache mount), в образ не попадает.
COPY pubspec.yaml pubspec.lock* ./
RUN --mount=type=cache,target=/root/.pub-cache \
    dart pub get

# Исходники копируем отдельно: их изменение не сбрасывает кэш зависимостей.
COPY bin/ bin/
RUN --mount=type=cache,target=/root/.pub-cache \
    dart pub get --offline \
 && dart compile exe bin/server.dart -o /app/server

# ============================================================
# Этап 2: запуск. Лёгкий образ alpine, в который копируется только артефакт.
# ============================================================
FROM alpine:${ALPINE_VERSION}

# Dart AOT-бинарник собран под glibc, а в alpine используется musl:
# gcompat — слой совместимости. --no-cache: индекс apk не сохраняется в образе.
RUN apk add --no-cache gcompat \
 && addgroup -S app \
 && adduser -S -D -H -G app -s /sbin/nologin app

WORKDIR /app
COPY --from=build --chown=root:root --chmod=0755 /app/server /app/server

# Значения по умолчанию; переопределяются через -e / docker-compose / .env
ENV HOST=0.0.0.0 \
    PORT=8080 \
    APP_ENV=production \
    GREETING="Привет из Docker!" \
    USER=app

# Запуск от непривилегированного пользователя
USER app:app

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- "http://127.0.0.1:${PORT}/health" || exit 1

ENTRYPOINT ["/app/server"]
