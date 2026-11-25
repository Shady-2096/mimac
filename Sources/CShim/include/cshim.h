#ifndef CSHIM_H
#define CSHIM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <sys/resource.h>

/* ---------------------------------------------------------------- */
/* Stable per-process rusage snapshot (extracted in C so Swift code */
/* never depends on which rusage_info flavor the SDK defines).       */
/* ---------------------------------------------------------------- */

typedef struct {
    int      flavor;              /* rusage flavor actually used (6, 4) or 0 on failure */
    uint64_t user_time_mach;      /* mach ticks */
    uint64_t system_time_mach;
    uint64_t phys_footprint;      /* bytes */
    uint64_t resident_size;
    uint64_t diskio_bytesread;
    uint64_t diskio_byteswritten;
    uint64_t logical_writes;
    uint64_t pkg_idle_wkups;
    uint64_t interrupt_wkups;
    uint64_t proc_start_abstime;
    uint64_t runnable_time;
    /* energy (nanojoules) */
    uint64_t billed_energy;       /* v4 ri_billed_energy */
    uint64_t serviced_energy;     /* v4 ri_serviced_energy */
    uint64_t energy_nj;           /* v6 ri_energy_nj (total CPU energy) */
    uint64_t penergy_nj;          /* v6 ri_penergy_nj (P-core energy) */
    /* perf-level split (v6), mach ticks / counts */
    uint64_t user_ptime_mach;
    uint64_t system_ptime_mach;
    uint64_t instructions;
    uint64_t cycles;
    uint64_t pinstructions;
    uint64_t pcycles;
    /* QoS CPU time buckets (v4+), mach ticks */
    uint64_t qos_default;
    uint64_t qos_maintenance;
    uint64_t qos_background;
    uint64_t qos_utility;
    uint64_t qos_legacy;
    uint64_t qos_user_initiated;
    uint64_t qos_user_interactive;
} cshim_rusage;

int cshim_get_rusage(int pid, cshim_rusage *out);
int cshim_rusage_max_flavor(void);

/* ---------------------------------------------------------------- */
/* Coalitions (private API — feasibility probe only).                */
/* Struct layout copied from XNU osfmk/mach/coalition.h; the kernel  */
/* copies out min(kernel_size, user_size) so older/newer kernels are */
/* tolerated. Resolved via dlsym so we never hard-link the symbol.   */
/* ---------------------------------------------------------------- */

#define CSHIM_COALITION_NUM_TYPES 2

typedef struct {
    uint64_t tasks_started;
    uint64_t tasks_exited;
    uint64_t time_nonempty;
    uint64_t cpu_time;
    uint64_t interrupt_wakeups;
    uint64_t platform_idle_wakeups;
    uint64_t bytesread;
    uint64_t byteswritten;
    uint64_t gpu_time;
    uint64_t cpu_time_billed_to_me;
    uint64_t cpu_time_billed_to_others;
    uint64_t energy;                       /* nJ */
    uint64_t logical_immediate_writes;
    uint64_t logical_deferred_writes;
    uint64_t logical_invalidated_writes;
    uint64_t logical_metadata_writes;
    uint64_t energy_billed_to_me;          /* nJ */
    uint64_t energy_billed_to_others;      /* nJ */
    uint64_t cpu_ptime;
    uint64_t cpu_time_eqos_len;
    uint64_t cpu_time_eqos[7];
    uint64_t cpu_instructions;
    uint64_t cpu_cycles;
    uint64_t fs_metadata_writes;
    uint64_t pm_writes;
    uint64_t cpu_pinstructions;
    uint64_t cpu_pcycles;
    uint64_t reserved[16];                 /* headroom for newer kernels */
} cshim_coalition_usage;

/* Returns 0 on success, errno-style code otherwise. -1 = symbol unavailable. */
int cshim_coalition_resource_usage(uint64_t cid, cshim_coalition_usage *out);

/* Coalition ids for a pid: ids[0] = resource coalition, ids[1] = jetsam. */
int cshim_pid_coalition_ids(int pid, uint64_t ids[CSHIM_COALITION_NUM_TYPES]);

/* ---------------------------------------------------------------- */
/* SMC user-client structs (layout as used by SMCKit/iStat-class     */
/* tools). Read-only key access.                                     */
/* ---------------------------------------------------------------- */

typedef struct {
    unsigned char  major;
    unsigned char  minor;
    unsigned char  build;
    unsigned char  reserved;
    unsigned short release;
} cshim_smc_vers;

typedef struct {
    unsigned short version;
    unsigned short length;
    unsigned int   cpuPLimit;
    unsigned int   gpuPLimit;
    unsigned int   memPLimit;
} cshim_smc_plimit;

typedef struct {
    unsigned int  dataSize;
    unsigned int  dataType;
    unsigned char dataAttributes;
} cshim_smc_keyinfo;

typedef struct {
    unsigned int      key;
    cshim_smc_vers    vers;
    cshim_smc_plimit  pLimitData;
    cshim_smc_keyinfo keyInfo;
    unsigned char     result;
    unsigned char     status;
    unsigned char     data8;
    unsigned int      data32;
    unsigned char     bytes[32];
} cshim_smc_keydata;

#define CSHIM_SMC_CMD_READ_BYTES   5
#define CSHIM_SMC_CMD_READ_INDEX   8
#define CSHIM_SMC_CMD_READ_KEYINFO 9

#endif /* CSHIM_H */
