# ComfyUI на GPU AMD Radeon в Docker

<h4 align="center">
    <p>
        <a href="../README.md">English</a> |
        <b>Русский</b>
    </p>
</h4>

[ComfyUI](https://github.com/comfyanonymous/ComfyUI) в воспроизводимом
Docker-образе для GPU AMD Radeon,
[`hardandheavy/comfyui-rocm`](https://hub.docker.com/r/hardandheavy/comfyui-rocm).

Кастомные узлы и их Python-зависимости, установленные через ComfyUI Manager,
переживают перезапуск контейнера. Модели, результаты, кастомные узлы и
overlay-окружение Python хранятся вместе на одном постоянном томе с данными.

## Быстрый старт

```bash
git clone https://github.com/HardAndHeavy/comfyui-rocm-docker
cd comfyui-rocm-docker
make run
```

После первого запуска ComfyUI доступен по адресу <http://localhost:8188>.
Первый запуск создаёт `./data` и overlay-окружение в нём; модель скачивается
только командой `make test`, но не при `make run`.

Готовый образ без сборки:

```bash
docker run -d --name comfyui \
  --ipc=host \
  --device=/dev/kfd --device=/dev/dri \
  -v "$PWD/data:/data" \
  -p 8188:8188 \
  hardandheavy/comfyui-rocm:latest
```

## Как устроено состояние

Всё, что пишется во время работы, лежит в одном томе. Внутри образа ничего не
меняется, поэтому контейнер может работать от непривилегированного
пользователя, а образ можно пересобрать, не затронув данные.

| Путь | Содержимое |
| --- | --- |
| `/data/models` | checkpoints, loras, vae, controlnet, upscale_models, diffusion_models, text_encoders, embeddings, clip_vision |
| `/data/custom_nodes` | кастомные узлы из Manager'а или добавленные вручную |
| `/data/input`, `/data/output`, `/data/temp`, `/data/user` | рабочие каталоги ComfyUI и его база данных |
| `/data/.venv` | overlay-окружение: все Python-пакеты, установленные Manager'ом |
| `/data/huggingface` | `HF_HOME`, то есть кэш скачанных моделей на томе |

`/data/.venv` — главная часть схемы. Это virtualenv, в site-packages которого
лежит один файл `base.pth` со ссылкой на
`/opt/venv/lib/python3.14/site-packages` из образа. ComfyUI запускается
интерпретатором overlay-окружения, поэтому:

- `pip install` из Manager'а пишет на том и переживает перезапуск;
- ROCm-сборка PyTorch из образа остаётся доступной, но только для чтения;
- `pip uninstall` работает как обычно, и pip сам отказывается удалять пакет,
  который лежит в слое образа;
- удаление overlay-окружения (`make reset-overlay`) возвращает контейнер к
  состоянию образа, сохраняя модели и результаты.

Поскольку overlay находится рядом с узлами и моделями, один том `/data`
сохраняет всю установку при замене контейнера.

## Стек GPU защищён

В `docker/constraints.txt` перечислен стек GPU из базового образа, и этот файл
подставлен как `PIP_CONSTRAINT` и `UV_CONSTRAINT` для каждого запуска pip и uv
в контейнере. Кастомный узел, который требует `torch` или `numpy`, получает
ошибку резолвера вместо тихой замены ROCm-сборки на CUDA-колесо с PyPI — так
обычно и ломается контейнер с ComfyUI после установки расширения.

Собственные зависимости узла, которых нет в этом списке, ставятся в overlay и
одноразовы. Если что-то из них сломало ComfyUI, `make reset-overlay` исправляет
это за секунды.

## Команды

```bash
make run                # запуск на порту 8188 (PORT=... чтобы изменить)
make logs               # смотреть лог контейнера
make stop               # остановить и удалить контейнер
make build              # собрать образ из этого репозитория
make check              # офлайн-проверки (версии, lock, синтаксис)
make smoke-test         # проверка образа; GPU и модель не нужны
make test               # рендер изображения на закреплённой модели
make reset-overlay      # удалить всё, что установил Manager
make publish            # отправить тег и :latest (только для релиза)
```

`make test` скачивает `stabilityai/sd-turbo` (около 5 ГБ) в
`./data/models/checkpoints`, сверяет SHA-256 с закреплённым в `versions.json` и
рендерит изображение 512×512 за четыре шага. Тест падает, если картинка
получилась однородной: именно так ведёт себя сломанное ядро ROCm — без ошибки.

## Настройка

Все настройки задаются переменными окружения (`-e` или compose).

| Переменная | По умолчанию | Назначение |
| --- | --- | --- |
| `COMFYUI_LAUNCH_ARGS` | пусто | дополнительные флаги ComfyUI, например `--lowvram --force-fp16` |
| `COMFYUI_LISTEN` | `0.0.0.0` | адрес прослушивания |
| `COMFYUI_PORT` | `8188` | порт внутри контейнера |
| `COMFYUI_MANAGER` | `1` | `0` — запуск без ComfyUI Manager |
| `COMFYUI_NETWORK_MODE` | `personal_cloud` | `network_mode` Manager'а: `public`, `private`, `offline`, `personal_cloud` |
| `PUID` / `PGID` | `10001` / `10001` | запуск от указанных id |
| `COMFYUI_ALLOW_ROOT` | `0` | `1` — оставить запуск от root |
| `HF_HOME` | `/data/huggingface` | расположение кэша Hugging Face |

Не передавайте через `COMFYUI_LAUNCH_ARGS` флаги `--base-directory`,
`--listen` и `--port`: их выставляет entrypoint, а повтор флага заставляет
ComfyUI использовать последнее значение.

Значение `--listen` по умолчанию — `0.0.0.0`, потому что `-p` пробрасывает
порт на eth0 контейнера, а не на его loopback: бинд на `127.0.0.1` внутри
контейнера оставляет опубликованный порт мёртвым. Поэтому `make run` публикует
порт на `127.0.0.1` хоста, и сервер доступен только с этой машины — см. `BIND`
в `Makefile`.

Именно публикация делает осмысленным режим сети Manager'а. Manager решает, что
ему можно, по двум входам — адресу прослушивания и `network_mode`. На
не-loopback адресе при значении по умолчанию `public` он запрещает действия
установки **независимо** от `security_level`; открывает их только
`personal_cloud`. Поэтому entrypoint при каждом старте записывает
`network_mode = personal_cloud` в `data/user/__manager/config.ini` (переопределяется
через `COMFYUI_NETWORK_MODE`), а собственный `security_level = normal` Manager'а
не трогает. Вместе с публикацией на loopback это обычная установка ComfyUI для
одного пользователя, и ничего сверх дефолтов самого Manager'а не ослаблено.

Значение переписывается при каждом старте, а не задаётся один раз, потому что
Manager сам записывает `network_mode = public` в этот файл: правило «записать,
если ключа нет» никогда бы не сработало на томе, где ключ уже есть, и обновление
образа оставило бы старое поведение.

Два следствия, которые стоит знать:

- **Доступ извне этой машины.** `make run BIND=0.0.0.0` или собственная
  публикация порта на всех интерфейсах делают утверждение `personal_cloud`
  ложным. В этом случае запускайте с `COMFYUI_NETWORK_MODE=public`: Manager снова
  спрячет кнопки установки, в этом и смысл. Синхронизировать эти две вещи —
  ваша задача, контейнер не видит, как опубликован порт.
- **Если нужен настоящий loopback**, запускайте с `--network host` и
  `COMFYUI_LISTEN=127.0.0.1`: тогда loopback контейнера — это loopback хоста, и
  Manager видит действительно локальный слушатель.

```bash
docker run -d --name comfyui --ipc=host --network host \
  --device=/dev/kfd --device=/dev/dri \
  -v "$PWD/data:/data" -e COMFYUI_LISTEN=127.0.0.1 \
  hardandheavy/comfyui-rocm:latest
```

## Добавление моделей

Кладите файлы в соответствующий каталог внутри `./data/models` — это можно
делать на работающем контейнере, список файлов в UI обновляется кнопкой
перезагрузки.

| Тип модели | Каталог |
| --- | --- |
| Чекпойнт | `models/checkpoints` |
| LoRA | `models/loras` |
| VAE | `models/vae` |
| ControlNet | `models/controlnet` |
| Апскейлер | `models/upscale_models` |
| Diffusion-модель | `models/diffusion_models` |
| Текстовый энкодер | `models/text_encoders` |
| CLIP vision | `models/clip_vision` |
| Эмбеддинг | `models/embeddings` |

Модели есть на [civitai.com](https://civitai.com/) и
[huggingface.co](https://huggingface.co/).

## Состав версии 3.0.2

Изменения по релизам — в [CHANGELOG](../CHANGELOG.md). Версия образа не связана
с версиями ROCm, ComfyUI и Manager.

<!-- versions:begin -->
<!-- versions:end -->

`versions.json` — единственный источник этих версий. Аргументы сборки и OCI-метки
Dockerfile, `requirements.in` и таблица выше генерируются из него скриптом
`tools/versions.py`, поэтому разойтись они не могут. Измените `versions.json`,
выполните `make versions`, и `make base-constraints`, если менялся базовый
образ. `make check` падает, если что-то устарело.

## Требования

- Linux x86_64 с GPU AMD, поддерживаемой ROCm 10.1.
- Совместимый драйвер AMDGPU, дающий `/dev/kfd` и `/dev/dri`.
- Docker Engine 24 или новее с BuildKit.
- `make` и `git` для команд репозитория.
- [`uv`](https://docs.astral.sh/uv/) 0.13.7 — только для пересборки lock-файла;
  версия закреплена в `Makefile` и проверяется в `make lock`.

Пользовательский стек ROCm находится внутри образа, поэтому устанавливать его
на хосте не нужно — нужен только драйвер ядра. Установка драйвера описана в
[руководстве AMD](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/).

## Как устроен образ

Образ собирается слоями, и каждый слой — отдельный репозиторий:

```
rocm/dev-ubuntu-26.04      ROCm, Ubuntu
  └─ transformers-rocm     закреплённый PyTorch, Transformers, venv в /opt/venv
       └─ llama-rocm       llama-cpp-python с HIP-бэкендом
            └─ comfyui-rocm   этот образ: ComfyUI, его зависимости, overlay
```

Сборка llama.cpp вынесена в отдельный образ, чтобы ComfyUI получал проверенный
бинарник, а не собирал его у каждого пользователя, и чтобы узлы, запускающие
LLM внутри ComfyUI, не требовали ничего дополнительно.

Внутри этого образа:

- **Всё закреплено.** APT заморожен на снимке `snapshot.ubuntu.com`, Python-пакеты
  приходят из lock-файлов с хешами, ComfyUI забирается по коммиту, а не по тегу,
  поэтому переехавший тег не меняет сборку.
- **Базовый образ закреплён по digest.** `make pin-base` спрашивает registry,
  куда сейчас указывает `llama-rocm:3.0.2`, и записывает ответ, а при
  расхождении версионного тега и `latest` отказывается писать пин.
- **Lock разрешается относительно базы.** `make lock` использует
  `docker/base-constraints.txt` и исключает все пакеты базового образа, поэтому
  ComfyUI не может притянуть второй numpy или старый tokenizers. `make check`
  падает, если такой пакет появился.
- **Сборка проверяет себя.** Версия ComfyUI сверяется с закреплённой в
  `versions.json`, все модули, которые импортируют ComfyUI и Manager,
  импортируются во время сборки, а `docker/constraints.txt` сверяется с
  фактически установленным.
- **Работа без привилегий.** Entrypoint читает group id устройств `/dev/kfd` и
  `/dev/dri`, выдаёт их и сбрасывает права; ни `--privileged`, ни `--group-add`
  указывать не нужно.

### Идемпотентный запуск

Раскладка каталогов создаётся, а overlay проверяется при каждом старте — обе
операции идемпотентны и дешёвы. Код ComfyUI лежит в образе в `/opt/comfyui` и
никогда не перезаписывается. Не нужно синхронизировать копию исходников или
файлы-маркеры на хосте: и новый, и существующий том `/data` проходят один и тот
же путь запуска.

## Если что-то не работает

**`no ROCm GPU visible`** — не проброшены `/dev/kfd` и `/dev/dri` или на хосте
нет драйвера. Проверьте `ls -l /dev/kfd /dev/dri` и `rocminfo` на хосте.

**`permission denied` при записи в `./data`** — контейнер работает от uid 10001.
Либо отдайте каталог ему (`sudo chown -R 10001:10001 ./data`), либо запускайте
со своими id: `make run PUID=$(id -u) PGID=$(id -g)`.

**ComfyUI запускается, но Manager ничего не устанавливает** — проверьте
`COMFYUI_NETWORK_MODE` (и `network_mode` в `data/user/__manager/config.ini`,
который entrypoint держит с ним в синхроне). На не-loopback адресе Manager
запрещает установку, пока режим `public`, что бы ни было в `security_level`;
образ по умолчанию ставит `personal_cloud`, потому что `make run` публикует порт
на loopback. Если порт открыт наружу, настройка и реальность расходятся: либо
публикуйте снова на `127.0.0.1`, либо передайте `COMFYUI_NETWORK_MODE=public` и
примите, что установка снаружи отключена. Поднимать `security_level` до `weak`
бесполезно: установка останется запрещённой, а откроются действия `high` —
git-URL и fix-pack.

**Кастомный узел сломал ComfyUI** — `make reset-overlay` удаляет все пакеты,
установленные Manager'ом, и возвращает состояние образа. Модели, результаты и
каталоги узлов остаются на месте.

**`resolver error` про torch** — так и задумано. `docker/constraints.txt` не даёт
узлу заменить ROCm-сборку.

## Лицензия

[Apache-2.0](../LICENSE). Сам ComfyUI распространяется под GPL-3.0; в этом
репозитории нет его кода, только рецепт, который забирает его при сборке.
