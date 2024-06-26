CONDA_DIR = /opt/miniconda_comfyui_v1.0.0
CONDA_CHECK_SEED_FILE = $(CONDA_DIR)/conda-check-seed-file
MODELS_CHECK_SEED_FILE = /app/models/models-check-seed-file
CUSTOM_NODES_CHECK_SEED_FILE = /app/custom_nodes/custom_nodes-check-seed-file

init:
	if [ ! -f $(CONDA_CHECK_SEED_FILE) ]; then \
		cp -r /opt/miniconda/* $(CONDA_DIR) && \
		touch $(CONDA_CHECK_SEED_FILE); fi
	if [ ! -f $(MODELS_CHECK_SEED_FILE) ]; then \
		cp -r /app/models-seed/* /app/models && \
		touch $(MODELS_CHECK_SEED_FILE); fi
	if [ ! -f $(CUSTOM_NODES_CHECK_SEED_FILE) ]; then \
		cp -r /app/custom_nodes-seed/* /app/custom_nodes && \
		git clone https://github.com/ltdrdata/ComfyUI-Manager /app/custom_nodes/ComfyUI-Manager && \
		touch $(CUSTOM_NODES_CHECK_SEED_FILE); fi

run: init
	python main.py --listen 0.0.0.0 --port 80
