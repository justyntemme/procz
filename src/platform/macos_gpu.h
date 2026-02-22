#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    int32_t pid;
    uint64_t gpu_time_ns;
} GpuProcEntry;

size_t collect_gpu_usage(GpuProcEntry* out, size_t max_entries);
