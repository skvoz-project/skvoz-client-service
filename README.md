# Клиентский сервис SKVOZ

Клиент для приложений и контейнеров. Docker — основной способ поставки;
текущая реализация работает без UI на Linux/amd64. Ruby host управляет
конфигурацией, identity и адаптерами, готовый Network runtime использует общий Core.

Выберите ВПН для контейнеров в общем network namespace либо Прокси:
HTTP/CONNECT/SOCKS5, именованные TCP forwards и HTTP base-URL gateways.

Обычная сборка и CI используют собственные исходники и готовый Network bundle.
Server и его release для них не нужны. [Обновление зависимостей](docs/releases.md)
закрепляет точный опубликованный Network tag; Core приходит внутри этого bundle.
Сборка проверяет SHA256 закреплённого архива и распаковывает необходимые файлы
стандартным `tar`. Дополнительный установщик не требуется.

Начните с [руководства](docs/container-client.md) и
[Compose-файла](compose.yaml). Три поля подключения находятся в inline YAML;
обязательных внешних env/config файлов нет.

Для компонентных проверок из корня репозитория:

```sh
bundle install
bundle exec rspec spec
```

Нужны Ruby4.0.7 и Bundler4.0.22; Gemfile.lock содержит точные версии и checksum.
Эти проверки не требуют готовых Core/Network или Server. Через Docker:

```sh
ruby bin/build-image --target tests --tag-prefix skvoz-client:local
```

Обычная сборка и отдельный ограниченный локальный launcher описаны в
[руководстве сборки](docs/build.md).
Для deploy нужен готовый закреплённый Network bundle;
[команды упаковки](docs/container-client.md#сборка-и-зависимости) не собирают
Core или Network из исходников. [Отдельная сквозная проверка](test-support/README.md)
использует готовый Server product и его публичный интерфейс управления.

`skvoz-client serve` читает `SKVOZ_CLIENT_CONFIG`; `check` проверяет YAML без
подключения; `health` проверяет текущий процесс и heartbeat; `--version` показывает
версии компонента и протоколов. Private named volume сохраняет одну device identity.

Версия Ruby client — 1.0.1. Совместимый runtime tuple:
Network0.7.0/API1/network protocol6/Core5.0.0. Лицензия — [MIT](LICENSE).
