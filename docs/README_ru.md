# ComfyUI на GPU AMD Radeon в Docker

<h4 align="center">
    <p>
        <a href="https://github.com/HardAndHeavy/comfyui-rocm-docker">English</a> |
        <b>Русский</b>
    </p>
</h4>

[ComfyUI](https://github.com/comfyanonymous/ComfyUI) в Docker [контейнере с поддержкой GPU Radeon](https://hub.docker.com/repository/docker/hardandheavy/comfyui-rocm/general). Проверено на AMD Radeon RX 7900 XTX.

### Необходимое окружение
- Ubuntu
- make
- Docker
- git
- ROCm ([установка](https://github.com/HardAndHeavy/transformers-rocm-docker?tab=readme-ov-file#install-rocm))

### Запуск
```bash
git clone https://github.com/HardAndHeavy/comfyui-rocm-docker
cd comfyui-rocm-docker
make run
```

При первом запуске будет происходить длительный процесс инициализации. Когда процесс завершится, ComfyUI станет доступен по адресу http://localhost.

### Замечания
- Для добавления новых ресурсов узлов необходимо предоставить доступ к каталогу `./data`, так как контейнер запускался от имени пользователя root. Для этого нужно выполнить команду `sudo chmod a+rw -R ./data`
- Модели располагаются в каталоге `./data/comfyui/models/checkpoints`. Модели можно найти на сайте [civitai.com](https://civitai.com/)
- При серьёзном изменении состава библиотек python необходимо изменить версию `CONDA_DIR` в `./Makefile`
