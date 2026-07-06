#ifndef MSP_PTY_SUPPORT_H
#define MSP_PTY_SUPPORT_H

#include <sys/types.h>
#include <termios.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MSPPtySpawnResult {
    int master_fd;
    pid_t process_id;
    int error_code;
} MSPPtySpawnResult;

typedef struct MSPPtyTerminalModeSnapshot {
    struct termios attributes;
    int valid;
    int was_canonical;
    int was_echoing;
} MSPPtyTerminalModeSnapshot;

int msp_spawn_pty_process(
    const char *program,
    char *const argv[],
    char *const envp[],
    const char *cwd,
    MSPPtySpawnResult *result
);

int msp_pty_enter_noncanonical_noecho_mode(
    int master_fd,
    MSPPtyTerminalModeSnapshot *snapshot
);

int msp_pty_restore_terminal_mode(
    int master_fd,
    const MSPPtyTerminalModeSnapshot *snapshot
);

#ifdef __cplusplus
}
#endif

#endif
