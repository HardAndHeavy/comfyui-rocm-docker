include hsa_override.mk

CUR_VERSION = 2.12.0
CONDA_DIR = $(PWD)/data/miniconda_v$(CUR_VERSION)

build:
	docker build -t comfyui-rocm:$(tag) -f docker/Dockerfile .

publish:
	docker image tag comfyui-rocm:$(tag) hardandheavy/comfyui-rocm:$(tag)
	docker push hardandheavy/comfyui-rocm:$(tag)
	docker image tag comfyui-rocm:$(tag) hardandheavy/comfyui-rocm:latest
	docker push hardandheavy/comfyui-rocm:latest

seed:
	if [ ! -f "$(CONDA_DIR)/conda-check-seed-file" ]; then \
		docker run -it --rm \
			-v $(CONDA_DIR):/opt/miniconda_seed \
			hardandheavy/comfyui-rocm:$(CUR_VERSION) sh -c \
				"cp -r /opt/miniconda/* /opt/miniconda_seed && \
				touch /opt/miniconda_seed/conda-check-seed-file"; fi

run: seed
	docker run -it --rm \
		-p 80:80 \
		--device=/dev/kfd \
		--device=/dev/dri \
		-e HSA_OVERRIDE_GFX_VERSION=$(HSA_OVERRIDE_GFX_VERSION) \
		-e HSA_ENABLE_SDMA=0 \
		-e COMFYUI_LAUNCH_ARGS="--listen 0.0.0.0 --port 80" \
		-v ./data/check:/check \
		-v ./data/home:/root \
		-v $(CONDA_DIR):/opt/miniconda \
		-v ./data/comfyui:/comfyui \
		hardandheavy/comfyui-rocm:$(CUR_VERSION)
