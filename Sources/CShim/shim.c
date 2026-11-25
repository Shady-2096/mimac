#include "include/cshim.h"
#include <dlfcn.h>
#include <errno.h>
#include <string.h>

int cshim_rusage_max_flavor(void) {
#ifdef RUSAGE_INFO_V6
    return 6;
#elif defined(RUSAGE_INFO_V5)
    return 5;
#else
    return 4;
#endif
}

int cshim_get_rusage(int pid, cshim_rusage *out) {
    memset(out, 0, sizeof(*out));

#ifdef RUSAGE_INFO_V6
    {
        struct rusage_info_v6 ru;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru) == 0) {
            out->flavor            = 6;
            out->user_time_mach    = ru.ri_user_time;
            out->system_time_mach  = ru.ri_system_time;
            out->phys_footprint    = ru.ri_phys_footprint;
            out->resident_size     = ru.ri_resident_size;
            out->diskio_bytesread  = ru.ri_diskio_bytesread;
            out->diskio_byteswritten = ru.ri_diskio_byteswritten;
            out->logical_writes    = ru.ri_logical_writes;
            out->pkg_idle_wkups    = ru.ri_pkg_idle_wkups;
            out->interrupt_wkups   = ru.ri_interrupt_wkups;
            out->proc_start_abstime = ru.ri_proc_start_abstime;
            out->runnable_time     = ru.ri_runnable_time;
            out->billed_energy     = ru.ri_billed_energy;
            out->serviced_energy   = ru.ri_serviced_energy;
            out->energy_nj         = ru.ri_energy_nj;
            out->penergy_nj        = ru.ri_penergy_nj;
            out->user_ptime_mach   = ru.ri_user_ptime;
            out->system_ptime_mach = ru.ri_system_ptime;
            out->instructions      = ru.ri_instructions;
            out->cycles            = ru.ri_cycles;
            out->pinstructions     = ru.ri_pinstructions;
            out->pcycles           = ru.ri_pcycles;
            out->qos_default       = ru.ri_cpu_time_qos_default;
            out->qos_maintenance   = ru.ri_cpu_time_qos_maintenance;
            out->qos_background    = ru.ri_cpu_time_qos_background;
            out->qos_utility       = ru.ri_cpu_time_qos_utility;
            out->qos_legacy        = ru.ri_cpu_time_qos_legacy;
            out->qos_user_initiated   = ru.ri_cpu_time_qos_user_initiated;
            out->qos_user_interactive = ru.ri_cpu_time_qos_user_interactive;
            return 0;
        }
    }
#endif
    {
        struct rusage_info_v4 ru;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ru) == 0) {
            out->flavor            = 4;
            out->user_time_mach    = ru.ri_user_time;
            out->system_time_mach  = ru.ri_system_time;
            out->phys_footprint    = ru.ri_phys_footprint;
            out->resident_size     = ru.ri_resident_size;
            out->diskio_bytesread  = ru.ri_diskio_bytesread;
            out->diskio_byteswritten = ru.ri_diskio_byteswritten;
            out->logical_writes    = ru.ri_logical_writes;
            out->pkg_idle_wkups    = ru.ri_pkg_idle_wkups;
            out->interrupt_wkups   = ru.ri_interrupt_wkups;
            out->proc_start_abstime = ru.ri_proc_start_abstime;
            out->runnable_time     = ru.ri_runnable_time;
            out->billed_energy     = ru.ri_billed_energy;
            out->serviced_energy   = ru.ri_serviced_energy;
            out->qos_default       = ru.ri_cpu_time_qos_default;
            out->qos_maintenance   = ru.ri_cpu_time_qos_maintenance;
            out->qos_background    = ru.ri_cpu_time_qos_background;
            out->qos_utility       = ru.ri_cpu_time_qos_utility;
            out->qos_legacy        = ru.ri_cpu_time_qos_legacy;
            out->qos_user_initiated   = ru.ri_cpu_time_qos_user_initiated;
            out->qos_user_interactive = ru.ri_cpu_time_qos_user_interactive;
            out->instructions      = ru.ri_instructions;
            out->cycles            = ru.ri_cycles;
            return 0;
        }
    }
    return errno ? errno : -1;
}

/* ---- coalition_info (private) ---- */

typedef int (*coalition_info_fn)(uint32_t flavor, uint64_t *cid, void *buffer, size_t *bufsize);
#define COALITION_INFO_RESOURCE_USAGE 1

int cshim_coalition_resource_usage(uint64_t cid, cshim_coalition_usage *out) {
    static coalition_info_fn fn = NULL;
    static int resolved = 0;
    if (!resolved) {
        fn = (coalition_info_fn)dlsym(RTLD_DEFAULT, "coalition_info");
        resolved = 1;
    }
    if (!fn) return -1;
    memset(out, 0, sizeof(*out));
    size_t sz = sizeof(*out);
    int rc = fn(COALITION_INFO_RESOURCE_USAGE, &cid, out, &sz);
    return rc == 0 ? 0 : (errno ? errno : rc);
}

int cshim_pid_coalition_ids(int pid, uint64_t ids[CSHIM_COALITION_NUM_TYPES]) {
    ids[0] = ids[1] = 0;
#ifdef PROC_PIDCOALITIONINFO
    struct proc_pidcoalitioninfo ci;
    memset(&ci, 0, sizeof(ci));
    int n = proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 0, &ci, sizeof(ci));
    if (n <= 0) return errno ? errno : -1;
    ids[0] = ci.coalition_id[0];
    if (COALITION_NUM_TYPES > 1) ids[1] = ci.coalition_id[1];
    return 0;
#else
    return -2; /* SDK lacks PROC_PIDCOALITIONINFO */
#endif
}
