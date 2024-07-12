CONDA_DIR = /opt/miniconda_comfyui
CONDA_CHECK_SEED_FILE = $(CONDA_DIR)/conda-check-seed-file
COMFYUI_CHECK_SEED_FILE = /check/comfyui-check-seed-file
MANAGER_CHECK_SEED_FILE = /check/manager-check-seed-file

init:
	if [ ! -f $(CONDA_CHECK_SEED_FILE) ]; then \
		cp -r /opt/miniconda/* $(CONDA_DIR) && \
		touch $(CONDA_CHECK_SEED_FILE); fi
	if [ ! -f $(COMFYUI_CHECK_SEED_FILE) ]; then \
		git clone https://github.com/comfyanonymous/ComfyUI /comfyui && \
		cd /comfyui && \
		pip install -r requirements.txt && \
		touch $(COMFYUI_CHECK_SEED_FILE); fi
	if [ ! -f $(MANAGER_CHECK_SEED_FILE) ]; then \
		git clone https://github.com/ltdrdata/ComfyUI-Manager /comfyui/custom_nodes/ComfyUI-Manager && \
		touch $(MANAGER_CHECK_SEED_FILE); fi

run: init
	cd /comfyui && \
	python main.py --listen 0.0.0.0 --port 80
