COMFYUI_CHECK_SEED_FILE = /check/comfyui-check-seed-file
MANAGER_CHECK_SEED_FILE = /check/manager-check-seed-file

init:
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
	if [ -z "$$COMFYUI_LAUNCH_ARGS" ]; then \
		python main.py --listen 0.0.0.0 --port 80; \
	else \
		python main.py $$COMFYUI_LAUNCH_ARGS; \
	fi
