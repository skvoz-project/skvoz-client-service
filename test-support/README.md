# Отдельная совместимость с Server product

Обычные component tests, сборка и CI Client Service не требуют Server.
Opt-in `spec/native_spec.rb` использует готовый runnable Server product и
документированные [Server интерфейсы](https://github.com/skvoz-project/skvoz-server/blob/main/docs/interoperability.md).
Исходники, Gemfile, spec helpers и fixture source archives Server не поставляются
клиенту и не импортируются.

Host controller получает точный готовый Server product image, фиксирует digest,
запускает его и выполняет публичные CLI setup/health/user add. Controller выбирает
три различных свободных loopback порта и разрешает в Server config только эти
точные адреса; клиентские test targets привязываются к тем же портам. Широкий
allowlist и угадывание портов после Server setup не используются.

Client test payload работает как UID10001, caps0/no-new-privileges с фактическими
CPU/RAM/swap0/PIDs/I/O caps и конечным deadline. Ему доступны собственный Client,
готовый Network runtime и единственный read-only bind существующего Server
`admin.sock`: socket должен иметь тот же UID и mode0600. Docker socket, Server
state и чужой source tree в payload не монтируются. Server сохраняет SO_PEERCRED
проверку владельца; client adapter также проверяет UID peer.

В private tmpfs payload controller создаёт regular0600 файл профиля, принадлежащий
UID10001, и передаёт его путь как `SKVOZ_SERVER_TEST_PROFILE`. Например, содержимое
имеет ровно такие ключи (реальные credentials/CA в логи не выводят):

```json
{
  "bundle": {"address": "localhost", "port": 4222, "username": "example", "password": "<test-password>", "ca_pem": "<test-CA-PEM>"},
  "admin_socket": "/server-admin.sock",
  "target_ports": [12001, 12002, 12003]
}
```

Порты примера заменяются host controller до запуска. Профиль не больше64KiB;
helper отклоняет лишние поля, не-private файл/socket и дубли/диапазоны target ports.
Он не запускает Server. Для revoke отправляется существующий bounded newline JSON
`{"operation":"remove","login":"example"}`; ответ должен иметь `ok:true` и `result`.
Server restart/setup/cleanup остаются ответственностью host controller.

## Воспроизводимый host запуск

Соберите собственный `tests` image [обычной командой](../docs/build.md) и закрепите
его реальный image ID. Получите готовые archive и `server-image.json` из явно
выбранного Server release и закрепите SHA256 обоих файлов по `SHA256SUMS`.
Потребуются Ruby4.0.7/Bundler4.0.22 с собственными gems, Docker, полная host
cgroupv2 hierarchy и готовый Network archive, совпадающий с owning lock.

```sh
bundle exec ruby bin/check-interoperability \
  --server-release "$SERVER_RELEASE_TAG" \
  --archive "$SERVER_ARCHIVE" --archive-sha256 "$SERVER_ARCHIVE_SHA256" \
  --receipt "$SERVER_IMAGE_RECEIPT" --receipt-sha256 "$SERVER_RECEIPT_SHA256" \
  --client-image "$CLIENT_TEST_IMAGE_ID" \
  --network-archive artifacts/native/network-current-identity.tar.gz \
  --io-device <local-block-device>
```

Tag содержит полный реальный40SHA. Команда сверяет оба digest и точный receipt
с image ID/source/version/tag до `docker image load`, затем Linux/amd64 и labels.
Mutable image tags и предполагаемый будущий Server pin не принимаются.
Она сама резервирует пять разных портов, создаёт unique state volume,
подготавливает0600 config через непривилегированный контейнер, запускает Server,
ждёт `health` и получает bundle через штатный `user add`. Socket берётся только
как `<Mountpoint>/admin.sock` своего exact volume; его UID/mode/dev/inode
сверяются в обоих контейнерах. Private profile передаётся через bounded stdin в
client tmpfs. Исходники Server и state directory клиенту не передаются.

Server и client получают по половине вычисленного бюджета: сумма CPU/RAM/PIDs
и I/O limits не превышает owning budget. На каждом контейнере проверяются
реальные caps, полный host ancestor headroom, OOM/swap и scope identity. Получение native dependency использует SHA256 и стандартный `tar` в приватном
scratch; rootfs остаётся read-only. Команда задаёт общий work deadline300s (допустимо240..600s) и ещё60s
cleanup, удаляет только свои контейнеры и state volume и проверяет отсутствие.
Для локальной квалификации дополнительно используется внешний sticky kernel
guard до финального cleanup. Готовые пользовательские images команда не удаляет.

Выбранные Server product release и Network bundle должны реально существовать
до этого публичного маршрута; до публикации pins не придумываются.
Обычные component tests/CI доступны независимо от него.

При отдельном собственном host controller payload можно запустить непосредственно:

```sh
SKVOZ_INTEGRATION=1 \
SKVOZ_SERVER_TEST_PROFILE=/profile/context.json \
SKVOZ_TEST_RUNTIME=/opt/skvoz-native/bin/skvoz-network-runtime \
bundle exec rspec spec/native_spec.rb
```

Сценарий проверяет TLS CA/имя, свежий health, byte-exact CONNECT, TCP half-close,
HTTP binary body, сохранение device identity после рестарта Client и физическое
закрытие трафика после revoke. Client child processes и test targets принадлежат
сценарию и закрываются в ensure; общий deadline180s, отдельные CLI/I/O/setup waits
конечны. Controller всегда удаляет свой Server и private metadata даже при ошибке.

Готовый Server release и private profile задаются явно; новый tag/digest не
выбирается автоматически. Отсутствие публичного Server product release ограничивает
этот opt-in маршрут, но не ordinary CI. Результат относится к выбранным image/
bundle; Compose/shared-netns/TUN и другие платформы требуют отдельной квалификации.
