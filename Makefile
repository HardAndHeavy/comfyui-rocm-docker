ROCM_GPU ?= $(strip $(shell rocminfo | grep -m 1 -E gfx[^0]{1} | sed -e 's/ *Name: *//'))
ifeq ($(ROCM_GPU), gfx1030)
  HSA_OVERRIDE_GFX_VERSION = 10.3.0
else ifeq ($(ROCM_GPU), gfx1100)
  HSA_OVERRIDE_GFX_VERSION = 11.0.0
else
  HSA_OVERRIDE_GFX_VERSION = "GFX version detection error"
endif
CONDA_DIR = $(PWD)/data/miniconda_comfyui_v2.2.0

build:
	docker build -t comfyui-rocm:$(tag) -f docker/Dockerfile .

publish:
	docker image tag comfyui-rocm:$(tag) hardandheavy/comfyui-rocm:$(tag)
	docker push hardandheavy/comfyui-rocm:$(tag)
	docker image tag comfyui-rocm:$(tag) hardandheavy/comfyui-rocm:latest
	docker push hardandheavy/comfyui-rocm:latest

bash:
	docker run -it --rm \
		-p 80:80 \
		--device=/dev/kfd \
		--device=/dev/dri \
		-e HSA_OVERRIDE_GFX_VERSION=$(HSA_OVERRIDE_GFX_VERSION) \
		-v ./data/check:/check \
		-v ./data/home:/root \
		-v ./data/miniconda_comfyui_v$(tag):/opt/miniconda \
		-v ./data/comfyui:/comfyui \
		comfyui-rocm:$(tag) bash

seed-conda:
	if [ ! -f "$(CONDA_DIR)/conda-check-seed-file" ]; then \
		docker run -it --rm \
			-v $(CONDA_DIR):/opt/miniconda_seed \
			hardandheavy/comfyui-rocm:latest sh -c \
				"cp -r /opt/miniconda/* /opt/miniconda_seed && \
				touch /opt/miniconda_seed/conda-check-seed-file"; fi

run: seed-conda
	docker run -it --rm \
		-p 80:80 \
		--device=/dev/kfd \
		--device=/dev/dri \
		-e HSA_OVERRIDE_GFX_VERSION=$(HSA_OVERRIDE_GFX_VERSION) \
		-v ./data/check:/check \
		-v ./data/home:/root \
		-v $(CONDA_DIR):/opt/miniconda \
		-v ./data/comfyui:/comfyui \
		hardandheavy/comfyui-rocm:latest
