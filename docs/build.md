# Сборка образа и GitHub Actions

Обычная поставка требует только этот checkout и готовый
[закреплённый Network bundle](releases.md). Server не входит в зависимости сборки.
Dockerfile отдельно собирает `tests` с RSpec и `deploy` с production gems;
общий Core и Network из исходников не компилируются.

## GitHub Actions

Нужны Docker и Ruby стандартной поставки. `bin/build-image` запускает обычный
`docker build` для одного target:

```sh
ruby bin/build-image --target tests --tag-prefix skvoz-client:ci
ruby bin/build-image --target deploy --tag-prefix skvoz-client:ci
```

Workflow собирает test image, выполняет собственные RSpec, скачивает закреплённый
Network bundle, собирает deploy и проверяет версии host/runtime. `deploy` требует
[скачанный архив](container-client.md#сборка-и-зависимости). Результаты —
`skvoz-client:ci-tests` и `skvoz-client:ci-deploy`; Compose использует deploy image.
После проверок тот же deploy image получает тег `skvoz-client:<версия>` и
экспортируется в gzip-архив Docker вместе с `SHA256SUMS`. Actions сохраняет
`client-service-image-<полный SHA>` на 7 дней для каждого успешного запуска.
Отдельный job загружает тот же образ из архива и публикует его в
`ghcr.io/skvoz-project/skvoz-client-service` с тегами `sha-<полный SHA>` и `latest`
при push в `main` или ручном запуске из `main`. В pull request и других ветках
публикации нет. Право `packages: write` получает только publish job; повторной
сборки в нём нет. Для входа в GHCR используется штатный `GITHUB_TOKEN`,
а метка `org.opencontainers.image.source` связывает образ с репозиторием клиента.
Команды получения готового образа приведены в [руководстве поставки](releases.md#получение-готового-образа).
Версии базовых образов и gems закреплены в Dockerfile и Gemfile.lock.
GitHub использует ресурсы runner и общий job timeout; полная локальная cgroup
иерархия, имя физического диска и локальные лимиты не являются условиями CI.

## Отдельная локальная сборка

`bin/build-local` сохраняет ограниченный BuildKit launcher. Ему нужны Linux с
полной host cgroup v2 hierarchy, Docker, Ruby и заранее подготовленный образ
BuildKit по digest из скрипта:

```sh
ruby bin/build-local --io-device <local-block-device> --target tests --tag-prefix skvoz-client:local
ruby bin/build-local --io-device <local-block-device> --target deploy --tag-prefix skvoz-client:local
```

Скрипт выбирает не больше половины effective CPU/доступной RAM и максимум4CPU/3GiB,
задаёт swap0/PIDs256, read8MiB/s/write2MiB/s для указанного Docker storage device.
`--budget` выводит CPU, память и affinity без сборки; `--deadline` задаёт work
deadline1..1800s, cleanup имеет ещё60s. Проверяются настоящие cgroup ancestors и
наследование лимитов пробным `RUN`; локальная квалификация дополнительно требует
непрерывного kernel guard до cleanup.

BuildKit запускается в собственном privileged container с cache volume, выполняет
target build и отдаёт image через `docker load`. Это режим сборщика; runtime
Client Service сохраняет собственные UID/capabilities/NNP правила. Cleanup
останавливает дочерние команды и проверяет отсутствие своего имени, ID, cgroup
и volume, затем удаляет operational scratch. Host Docker import остаётся за
пределами payload cgroup. GitHub workflow этот launcher не вызывает.

## Проверки

Host и authenticated-bootstrap specs работают без готового Network и без Server:

```sh
bundle exec rspec spec
```

Для локальной проверки в Docker используйте test image с UID10001/cap-drop ALL/
no-new-privileges, без сети и с тем же локальным CPU/RAM/swap/PID/I/O бюджетом.
Проверяйте реальные limits; один набор Docker flags не подтверждает квалификацию.

Native packaging сверяет закреплённый SHA256 и стандартным `tar` извлекает
необходимые файлы. Поставщик проверяет собственный bundle; клиент проверяет
runtime version и разрешение bundled Core без `LD_LIBRARY_PATH`.
Deploy содержит только `bin/skvoz-client` и native runtime closure; build/pin/
interoperability tools в runtime image не копируются. Полный manifest поставщика
хранится как `supplier-manifest.json`, а не manifest subset.

[Opt-in сценарий](../test-support/README.md) отдельно проверяет готовые Client и
Server продукты через публичные интерфейсы. Он не входит в обычный CI и не
поставляет клиенту Server sources/spec helpers. Compose/shared-netns/TUN и
платформенная квалификация проверяются отдельно от обычной сборки.
