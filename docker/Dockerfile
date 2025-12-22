FROM hardandheavy/transformers-rocm:2.10.0

EXPOSE 80

RUN apt-get update && apt-get install -y \
    libgl1 \
    libglib2.0-0

ENV LLAMA_CPP_PYTHON_VERSION=0.3.16
ENV DAMDGPU_TARGETS=gfx900;gfx906;gfx908;gfx90a;gfx1030;gfx1100;gfx1101;gfx940;gfx941;gfx942
RUN CMAKE_ARGS="-DGGML_HIP=on -DCMAKE_C_COMPILER=/opt/rocm/llvm/bin/clang -DCMAKE_CXX_COMPILER=/opt/rocm/llvm/bin/clang++ -DAMDGPU_TARGETS=${DAMDGPU_TARGETS}" pip install llama-cpp-python==${LLAMA_CPP_PYTHON_VERSION}

WORKDIR /app
COPY ./docker/Makefile ./Makefile

CMD make run
