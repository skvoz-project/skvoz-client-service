# Готовые зависимости из GitHub Releases

Обычная цепочка: Network Actions публикует Linux bundle → Client Service
закрепляет точный release → собственные Actions получают bundle и упаковывают
Docker image. Core входит в Network bundle. Server не нужен для host checks,
native packaging и ordinary Client Service CI.

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
Server release и не публикует Docker image. Неверный или отсутствующий native
asset завершает упаковку ошибкой без source rebuild fallback.

[Отдельная opt-in проверка](../test-support/README.md) использует готовый Server
product image и публичные setup/admin команды. Обновление Server product для
этого сценария не блокирует обычную сборку Client Service.
