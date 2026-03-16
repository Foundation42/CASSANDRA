// PTY helpers for spawning host processes from the CASSANDRA terminal
#ifndef PTY_HELPERS_H
#define PTY_HELPERS_H

#include <pty.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <termios.h>
#include <fcntl.h>

// Spawn a process with a PTY. Returns the master fd, sets *child_pid.
// Returns -1 on failure.
static inline int pty_spawn(const char *cmd, pid_t *child_pid) {
    int master_fd;
    pid_t pid = forkpty(&master_fd, NULL, NULL, NULL);
    if (pid < 0) return -1;

    if (pid == 0) {
        // Child process
        // Set TERM so programs know we handle ANSI
        setenv("TERM", "xterm-256color", 1);
        // Set reasonable size
        struct winsize ws = { .ws_row = 30, .ws_col = 100 };
        ioctl(0, TIOCSWINSZ, &ws);
        // Execute via shell
        execlp("/bin/sh", "sh", "-c", cmd, NULL);
        _exit(127);
    }

    // Parent
    *child_pid = pid;
    // Set master to non-blocking
    int flags = fcntl(master_fd, F_GETFL);
    fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);
    return master_fd;
}

// Read from master fd (non-blocking). Returns bytes read, 0 if nothing, -1 if closed.
static inline int pty_read(int master_fd, char *buf, int bufsize) {
    int n = read(master_fd, buf, bufsize);
    if (n > 0) return n;
    if (n == 0) return -1; // EOF
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    return -1; // error
}

// Write to master fd.
static inline int pty_write(int master_fd, const char *buf, int len) {
    return write(master_fd, buf, len);
}

// Check if child is still running. Returns 1 if alive, 0 if exited.
static inline int pty_alive(pid_t pid) {
    int status;
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0) return 1; // still running
    return 0; // exited
}

// Close master fd and wait for child.
static inline void pty_close(int master_fd, pid_t pid) {
    close(master_fd);
    int status;
    waitpid(pid, &status, 0);
}

// Resize the PTY
static inline void pty_resize(int master_fd, int rows, int cols) {
    struct winsize ws;
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ioctl(master_fd, TIOCSWINSZ, &ws);
}

#endif
