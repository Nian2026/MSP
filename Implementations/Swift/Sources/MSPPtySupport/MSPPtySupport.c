#include "MSPPtySupport.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && (TARGET_OS_OSX || TARGET_OS_SIMULATOR)
#include <util.h>

static void msp_reset_child_signal_state(void) {
    const int signals[] = {
        SIGCHLD,
        SIGHUP,
        SIGINT,
        SIGQUIT,
        SIGTERM,
        SIGALRM
    };
    const size_t count = sizeof(signals) / sizeof(signals[0]);
    for (size_t index = 0; index < count; index++) {
        signal(signals[index], SIG_DFL);
    }

    sigset_t empty_set;
    sigemptyset(&empty_set);
    sigprocmask(SIG_SETMASK, &empty_set, NULL);
}

int msp_pty_enter_noncanonical_noecho_mode(
    int master_fd,
    MSPPtyTerminalModeSnapshot *snapshot
) {
    if (snapshot == NULL) {
        errno = EINVAL;
        return -1;
    }

    memset(snapshot, 0, sizeof(*snapshot));
    if (tcgetattr(master_fd, &snapshot->attributes) != 0) {
        return -1;
    }

    snapshot->valid = 1;
    snapshot->was_canonical = (snapshot->attributes.c_lflag & ICANON) != 0;
    snapshot->was_echoing = (snapshot->attributes.c_lflag & ECHO) != 0;

    struct termios raw = snapshot->attributes;
    raw.c_lflag &= ~(ICANON | ECHO | ECHOE | ECHOK | ECHONL);
#if defined(ECHOCTL)
    raw.c_lflag &= ~ECHOCTL;
#endif
#if defined(ECHOKE)
    raw.c_lflag &= ~ECHOKE;
#endif
#if defined(ECHOPRT)
    raw.c_lflag &= ~ECHOPRT;
#endif
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;

    if (tcsetattr(master_fd, TCSANOW, &raw) != 0) {
        snapshot->valid = 0;
        return -1;
    }
    return 0;
}

int msp_pty_restore_terminal_mode(
    int master_fd,
    const MSPPtyTerminalModeSnapshot *snapshot
) {
    if (snapshot == NULL || snapshot->valid == 0) {
        errno = EINVAL;
        return -1;
    }
    return tcsetattr(master_fd, TCSANOW, &snapshot->attributes);
}

int msp_spawn_pty_process(
    const char *program,
    char *const argv[],
    char *const envp[],
    const char *cwd,
    MSPPtySpawnResult *result
) {
    if (result == NULL || program == NULL || argv == NULL || envp == NULL) {
        errno = EINVAL;
        return -1;
    }

    result->master_fd = -1;
    result->process_id = -1;
    result->error_code = 0;

    int master_fd = -1;
    int slave_fd = -1;
    if (openpty(&master_fd, &slave_fd, NULL, NULL, NULL) != 0) {
        result->error_code = errno;
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        result->error_code = errno;
        close(master_fd);
        close(slave_fd);
        return -1;
    }

    if (pid == 0) {
        msp_reset_child_signal_state();

        if (setsid() == -1) {
            _exit(127);
        }
        if (ioctl(slave_fd, TIOCSCTTY, 0) == -1) {
            _exit(127);
        }
        if (dup2(slave_fd, STDIN_FILENO) == -1 ||
            dup2(slave_fd, STDOUT_FILENO) == -1 ||
            dup2(slave_fd, STDERR_FILENO) == -1) {
            _exit(127);
        }
        if (cwd != NULL && cwd[0] != '\0' && chdir(cwd) == -1) {
            _exit(127);
        }

        close(master_fd);
        if (slave_fd > STDERR_FILENO) {
            close(slave_fd);
        }

        execve(program, argv, envp);
        _exit(errno == ENOENT ? 127 : 126);
    }

    close(slave_fd);
    result->master_fd = master_fd;
    result->process_id = pid;
    return 0;
}

#else

int msp_pty_enter_noncanonical_noecho_mode(
    int master_fd,
    MSPPtyTerminalModeSnapshot *snapshot
) {
    (void)master_fd;
    if (snapshot != NULL) {
        memset(snapshot, 0, sizeof(*snapshot));
    }
    errno = ENOTSUP;
    return -1;
}

int msp_pty_restore_terminal_mode(
    int master_fd,
    const MSPPtyTerminalModeSnapshot *snapshot
) {
    (void)master_fd;
    (void)snapshot;
    errno = ENOTSUP;
    return -1;
}

int msp_spawn_pty_process(
    const char *program,
    char *const argv[],
    char *const envp[],
    const char *cwd,
    MSPPtySpawnResult *result
) {
    (void)program;
    (void)argv;
    (void)envp;
    (void)cwd;
    if (result != NULL) {
        result->master_fd = -1;
        result->process_id = -1;
        result->error_code = ENOTSUP;
    }
    errno = ENOTSUP;
    return -1;
}

#endif
