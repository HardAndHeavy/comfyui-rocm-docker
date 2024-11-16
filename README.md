# ComfyUI on GPU AMD Radeon in Docker

<h4 align="center">
    <p>
        <b>English</b> |
        <a href="https://github.com/HardAndHeavy/comfyui-rocm-docker/blob/main/docs/README_ru.md">Русский</a>
    </p>
</h4>

[ComfyUI](https://github.com/comfyanonymous/ComfyUI) in a [Docker container with GPU Radeon support](https://hub.docker.com/repository/docker/hardandheavy/comfyui-rocm/general). Tested on AMD Radeon RX 7900 XTX.

### Requirements
- Ubuntu
- make
- Docker
- git
- ROCm (see the installation in [transformers-rocm-docker](https://github.com/HardAndHeavy/transformers-rocm-docker?tab=readme-ov-file#install-rocm))

### Launch
```bash
git clone https://github.com/HardAndHeavy/comfyui-rocm-docker
cd comfyui-rocm-docker
make run
```

At the first start, a lengthy initialization process will take place. When the process is completed, ComfyUI will be available at http://localhost.

### Remarks          
- To add new node resources, you must grant access to the directory `./data`, because the container was started as the root user. To do this, run the command `sudo chmod -R 777 ./data`
- Models are located in the directory `./data/comfyui/models/`. Models can be found on the site [civitai.com](https://civitai.com/)
- If there is a major change in the composition of python libraries, you must change the version of `CONDA_DIR` in `./Makefile`
