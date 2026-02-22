#include "macos_gpu.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

size_t collect_gpu_usage(GpuProcEntry* out, size_t max_entries) {
    if (!out || max_entries == 0) return 0;

    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AGXDeviceUserClient"),
        &iter
    );
    if (kr != KERN_SUCCESS || iter == 0) return 0;

    size_t count = 0;
    io_service_t service;

    while ((service = IOIteratorNext(iter)) != 0) {
        // Get PID from IOUserClientCreator string: "pid NNN, ProcessName"
        CFStringRef creator = IORegistryEntryCreateCFProperty(
            service, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0
        );
        if (!creator) {
            IOObjectRelease(service);
            continue;
        }

        char creator_buf[256];
        int32_t pid = -1;
        if (CFStringGetCString(creator, creator_buf, sizeof(creator_buf), kCFStringEncodingUTF8)) {
            sscanf(creator_buf, "pid %d", &pid);
        }
        CFRelease(creator);

        if (pid <= 0) {
            IOObjectRelease(service);
            continue;
        }

        // Get AppUsage array — each entry has "accumulatedGPUTime" (u64 ns, cumulative)
        CFArrayRef app_usage = IORegistryEntryCreateCFProperty(
            service, CFSTR("AppUsage"), kCFAllocatorDefault, 0
        );

        uint64_t total_gpu_ns = 0;
        if (app_usage && CFGetTypeID(app_usage) == CFArrayGetTypeID()) {
            CFIndex arr_count = CFArrayGetCount(app_usage);
            for (CFIndex i = 0; i < arr_count; i++) {
                CFDictionaryRef dict = CFArrayGetValueAtIndex(app_usage, i);
                if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) continue;

                CFNumberRef gpu_time = CFDictionaryGetValue(dict, CFSTR("accumulatedGPUTime"));
                if (gpu_time && CFGetTypeID(gpu_time) == CFNumberGetTypeID()) {
                    int64_t val = 0;
                    CFNumberGetValue(gpu_time, kCFNumberSInt64Type, &val);
                    if (val > 0) total_gpu_ns += (uint64_t)val;
                }
            }
        }
        if (app_usage) CFRelease(app_usage);

        if (total_gpu_ns > 0) {
            // Aggregate by PID — check if we already have an entry for this PID
            int found = 0;
            for (size_t i = 0; i < count; i++) {
                if (out[i].pid == pid) {
                    out[i].gpu_time_ns += total_gpu_ns;
                    found = 1;
                    break;
                }
            }
            if (!found && count < max_entries) {
                out[count].pid = pid;
                out[count].gpu_time_ns = total_gpu_ns;
                count++;
            }
        }

        IOObjectRelease(service);
    }

    IOObjectRelease(iter);
    return count;
}
