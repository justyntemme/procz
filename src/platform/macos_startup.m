#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <stdlib.h>
#include <string.h>
#include "macos_startup.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void collect_domain(CFStringRef domain, int is_user_agent,
                           StartupItemC **items, int *count, int *capacity) {
    CFArrayRef jobs = SMCopyAllJobDictionaries(domain);
    if (!jobs) return;

    CFIndex n = CFArrayGetCount(jobs);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef job = CFArrayGetValueAtIndex(jobs, i);
        if (!job) continue;

        // Label (required)
        CFStringRef cf_label = CFDictionaryGetValue(job, CFSTR("Label"));
        if (!cf_label) continue;

        // Grow array if needed
        if (*count >= *capacity) {
            *capacity = (*capacity == 0) ? 256 : *capacity * 2;
            *items = realloc(*items, sizeof(StartupItemC) * *capacity);
        }

        StartupItemC *item = &(*items)[*count];

        // Label
        const char *label_c = CFStringGetCStringPtr(cf_label, kCFStringEncodingUTF8);
        item->label = label_c ? strdup(label_c) : strdup("(unknown)");

        // Program or ProgramArguments[0]
        item->program = NULL;
        CFStringRef cf_program = CFDictionaryGetValue(job, CFSTR("Program"));
        if (cf_program) {
            const char *prog_c = CFStringGetCStringPtr(cf_program, kCFStringEncodingUTF8);
            if (prog_c) {
                item->program = strdup(prog_c);
            } else {
                char buf[1024];
                if (CFStringGetCString(cf_program, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    item->program = strdup(buf);
                }
            }
        }
        if (!item->program) {
            CFArrayRef cf_args = CFDictionaryGetValue(job, CFSTR("ProgramArguments"));
            if (cf_args && CFArrayGetCount(cf_args) > 0) {
                CFStringRef cf_arg0 = CFArrayGetValueAtIndex(cf_args, 0);
                if (cf_arg0) {
                    const char *arg0_c = CFStringGetCStringPtr(cf_arg0, kCFStringEncodingUTF8);
                    if (arg0_c) {
                        item->program = strdup(arg0_c);
                    } else {
                        char buf[1024];
                        if (CFStringGetCString(cf_arg0, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                            item->program = strdup(buf);
                        }
                    }
                }
            }
        }
        if (!item->program) {
            item->program = strdup("");
        }

        // PID
        CFNumberRef cf_pid = CFDictionaryGetValue(job, CFSTR("PID"));
        if (cf_pid) {
            int pid_val = -1;
            CFNumberGetValue(cf_pid, kCFNumberIntType, &pid_val);
            item->pid = pid_val;
        } else {
            item->pid = -1;
        }

        // RunAtLoad
        CFBooleanRef cf_ral = CFDictionaryGetValue(job, CFSTR("RunAtLoad"));
        item->run_at_load = (cf_ral && CFBooleanGetValue(cf_ral)) ? 1 : 0;

        // KeepAlive / OnDemand (OnDemand is the older name, inverted logic)
        CFBooleanRef cf_ka = CFDictionaryGetValue(job, CFSTR("KeepAlive"));
        if (cf_ka) {
            item->keep_alive = CFBooleanGetValue(cf_ka) ? 1 : 0;
        } else {
            CFBooleanRef cf_od = CFDictionaryGetValue(job, CFSTR("OnDemand"));
            // OnDemand=true means NOT keep-alive; OnDemand=false means keep-alive
            item->keep_alive = (cf_od && !CFBooleanGetValue(cf_od)) ? 1 : 0;
        }

        item->is_user_agent = is_user_agent;
        (*count)++;
    }

    CFRelease(jobs);
}

#pragma clang diagnostic pop

StartupItemList get_startup_items(void) {
    StartupItemC *items = NULL;
    int count = 0;
    int capacity = 0;

    collect_domain(kSMDomainUserLaunchd, 1, &items, &count, &capacity);
    collect_domain(kSMDomainSystemLaunchd, 0, &items, &count, &capacity);

    return (StartupItemList){ .items = items, .count = count };
}

void free_startup_items(StartupItemList list) {
    for (int i = 0; i < list.count; i++) {
        free((void *)list.items[i].label);
        free((void *)list.items[i].program);
    }
    free(list.items);
}
