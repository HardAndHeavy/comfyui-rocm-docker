ROCM_GPU ?= $(strip $(shell rocminfo | grep -m 1 -E gfx[^0]{1} | sed -e 's/ *Name: *//'))
ifeq ($(ROCM_GPU), gfx1030)
  HSA_OVERRIDE_GFX_VERSION = 10.3.0
else ifeq ($(ROCM_GPU), gfx1100)
  HSA_OVERRIDE_GFX_VERSION = 11.0.0
else
  HSA_OVERRIDE_GFX_VERSION = "GFX version detection error"
endif

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
		-v ./data/home:/root \
		-v ./data/miniconda_comfyui_v1.0.0:/opt/miniconda_comfyui_v1.0.0 \
		-v ./data/models:/app/models \
		-v ./data/custom_nodes:/app/custom_nodes \
		comfyui-rocm:$(tag) bash

run:
	docker run -it --rm \
		-p 80:80 \
		--device=/dev/kfd \
		--device=/dev/dri \
		-e HSA_OVERRIDE_GFX_VERSION=$(HSA_OVERRIDE_GFX_VERSION) \
		-v ./data/home:/root \
		-v ./data/miniconda_comfyui_v1.0.0:/opt/miniconda_comfyui_v1.0.0 \
		-v ./data/models:/app/models \
		-v ./data/custom_nodes:/app/custom_nodes \
		hardandheavy/comfyui-rocm:latest
