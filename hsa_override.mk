GPU_INFO := $(strip $(shell lspci -nnk | grep -i -E "VGA|3D|Display"))

ROCM_GPU := gfx900
HSA_OVERRIDE_GFX_VERSION := 9.0.0

ifneq (,$(or $(findstring 8060S,$(GPU_INFO)),$(findstring 8050S,$(GPU_INFO))))
  ROCM_GPU := gfx1151
  HSA_OVERRIDE_GFX_VERSION := 11.5.1
endif

ifneq (,$(or $(findstring RX 9070,$(GPU_INFO)),$(findstring R9700,$(GPU_INFO))))
  ROCM_GPU := gfx1201
  HSA_OVERRIDE_GFX_VERSION := 12.0.1
endif

ifneq (,$(findstring RX 9060,$(GPU_INFO)))
  ROCM_GPU := gfx1200
  HSA_OVERRIDE_GFX_VERSION := 12.0.0
endif

ifneq (,$(or $(findstring RX 7900,$(GPU_INFO)),$(findstring W7900,$(GPU_INFO)),$(findstring W7800,$(GPU_INFO))))
  ROCM_GPU := gfx1100
  HSA_OVERRIDE_GFX_VERSION := 11.0.0
endif

ifneq (,$(or $(findstring RX 7800,$(GPU_INFO)),$(findstring RX 7700,$(GPU_INFO)),$(findstring V710,$(GPU_INFO)),$(findstring W7700,$(GPU_INFO))))
  ROCM_GPU := gfx1101
  HSA_OVERRIDE_GFX_VERSION := 11.0.1
endif

ifneq (,$(or $(findstring W6800,$(GPU_INFO)),$(findstring V620,$(GPU_INFO)),$(findstring RX 6800,$(GPU_INFO)),$(findstring RX 6900,$(GPU_INFO))))
  ROCM_GPU := gfx1030
  HSA_OVERRIDE_GFX_VERSION := 10.3.0
endif

ifneq (,$(findstring MI3,$(GPU_INFO)))
  ROCM_GPU := gfx942
  HSA_OVERRIDE_GFX_VERSION := 9.4.2
endif

ifneq (,$(findstring MI2,$(GPU_INFO)))
  ROCM_GPU := gfx90a
  HSA_OVERRIDE_GFX_VERSION := 9.0.10
endif

ifneq (,$(or $(findstring Radeon VII,$(GPU_INFO)),$(findstring MI50,$(GPU_INFO))))
  ROCM_GPU := gfx906
  HSA_OVERRIDE_GFX_VERSION := 9.0.6
endif

$(info Detected: [$(GPU_INFO)])
$(info Result: ROCM_GPU=$(ROCM_GPU), HSA_OVERRIDE_GFX_VERSION=$(HSA_OVERRIDE_GFX_VERSION))
