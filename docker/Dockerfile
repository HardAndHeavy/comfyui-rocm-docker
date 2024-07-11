FROM hardandheavy/transformers-rocm:2.1.0

EXPOSE 80

# To upgrade to the higher version, you need to wait for the problem to be resolved
# https://github.com/abetlen/llama-cpp-python/issues/1481
ENV LLAMA_CPP_PYTHON_VERSION=0.2.56
ENV DAMDGPU_TARGETS=gfx900;gfx906;gfx908;gfx90a;gfx1030;gfx1100;gfx1101;gfx940;gfx941;gfx942
RUN CMAKE_ARGS="-DLLAMA_HIPBLAS=ON -DCMAKE_C_COMPILER=/opt/rocm/llvm/bin/clang -DCMAKE_CXX_COMPILER=/opt/rocm/llvm/bin/clang++ -DAMDGPU_TARGETS=${DAMDGPU_TARGETS}" pip install llama-cpp-python==${LLAMA_CPP_PYTHON_VERSION}

WORKDIR /app

COPY ./docker/Makefile ./Makefile

CMD make run
