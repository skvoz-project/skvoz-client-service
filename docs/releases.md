# Поставка образа и готовые зависимости

Обычная цепочка: Network Actions публикует Linux bundle в Releases → Client Service
закрепляет точный release → собственные Actions получают bundle, упаковывают и
публикуют готовый Docker image в GHCR. Core входит в Network bundle.
Server не нужен для host checks, native packaging и ordinary Client Service CI.

## Получение готового образа

После успешных проверок push или ручного запуска из `main` отдельный job
публикует тот же проверенный образ в `ghcr.io/skvoz-project/skvoz-client-service`:

- `latest` — последняя успешно опубликованная сборка `main`;
- `sha-<полный40SHA>` — образ выбранного исходного commit.

```sh
docker pull ghcr.io/skvoz-project/skvoz-client-service:latest
docker compose up -d
```

Перед запуском сохраните [Compose-файл](../compose.yaml) и задайте `server`,
`username`, `password`, как описано в [быстром запуске](container-client.md#быстрый-запуск).
Compose использует этот GHCR image и `pull_policy: missing`. Ruby, Core/Network
исходники и локальная сборка не требуются. Для фиксации точного содержимого
укажите в `image` registry digest
`ghcr.io/skvoz-project/skvoz-client-service@sha256:<digest>`.

Publisher получает проверенный gzip-архив Docker и `SHA256SUMS` из Actions
artifact, сверяет checksum, выполняет `docker load` и `docker push` без повторной
сборки. Архив используется для передачи между jobs; обычная поставка пользователю
идёт через GHCR. Pull request и другие ветки не публикуют образ.
Вход выполняется штатным `GITHUB_TOKEN` с `packages: write`, отдельный PAT для
workflow не нужен. Метка `org.opencontainers.image.source` связывает пакет
с репозиторием клиента.

При первой публикации GHCR создаёт пакет Private. Для анонимного `docker pull`
выберите Public в настройках пакета, как описано в
[документации GitHub](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).

## Обновление Network

После успешной публикации нужного owning commit задайте полный tag
`network-v0.7.0-<full40sha>` и выполните в Ruby4.0.7/Bundler4.0.22 с gems из lock:

```sh
bundle exec ruby bin/pin-network-release "$NETWORK_RELEASE_TAG"
```

Команда получает `SHA256SUMS` и
`skvoz-network-0.7.0-x86_64-unknown-linux-gnu.tar.gz` из точного release. Сначала
проверяется SHA256 всего архива. Стандартный `tar` извлекает только нужные
runtime/helper/Core, ресурсы, лицензии и исходный manifest; исполняемый установщик
не загружается. Существующий destination не заменяется, ошибка не публикует
частичный результат. Версии/target/ABI квалифицирует поставщик; клиент сохраняет
собственные runtime/version checks. `bin/install-native` — короткая собственная
обвязка этих команд, полная копия supplier validator не сопровождается.

Текущий pin указывает реальный immutable Network release. Его native bundle
подходит этому пути напрямую. Обновляйте pin только после публикации выбранного
нового выпуска; будущие hashes и локальные candidates не подменяют релизы.

## Обычный CI и отдельная совместимость

[Workflow](../.github/workflows/client-service.yml) выполняет собственные host и
проверки получения зависимости, получает точный Network archive, собирает deploy и проверяет
версии host/runtime. Он не получает Server fixture/source archive, не требует
образа Server. После проверок образ сохраняется как Actions artifact; из
`main` отдельный job публикует его в GHCR. Неверный или отсутствующий native
asset завершает упаковку ошибкой без source rebuild fallback.

[Отдельная opt-in проверка](../test-support/README.md) использует готовый Server
product image и публичные setup/admin команды. Обновление Server product для
этого сценария не блокирует обычную сборку Client Service.
