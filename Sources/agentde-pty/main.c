// agentde-pty: holds one AgentDE tab's terminal, so the shell and everything in it outlive the app.
//
// Usage: agentde-pty <socket> <rows> <cols> <ring-bytes> <cwd> <executable> <argv0> [args...]
//
// It detaches from its parent (the first process exits once the socket is listening, so the caller can
// wait for it), starts <executable> on a new pseudo-terminal in <cwd> with this process's environment, and
// serves one client at a time on the Unix socket <socket>. It keeps the last <ring-bytes> of output and the
// terminal modes programs have switched on, so a client that connects later (AgentDE after a relaunch)
// sees the screen and gets the same keyboard and paste behavior. It exits when the shell exits.
//
// Frames in both directions: 1 byte type, 4 bytes big-endian length, payload.
//   to the client:   'h' hello (version, holder pid, shell pid: 3 x u32)   'r' replayed output
//                    'e' end of replay   'o' output   'x' shell exited (wait status, i32)
//   from the client: 'i' input   'w' window size (rows, cols, x pixels, y pixels: 4 x u16)
//                    'd' redraw (SIGWINCH to the foreground process group)

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#define PROTOCOL_VERSION 1
#define MAX_FRAME (1 << 20)

extern char **environ;

static int listen_fd = -1, client_fd = -1, master_fd = -1, sig_pipe[2] = {-1, -1};
static pid_t child = -1;
static const char *socket_path;

// MARK: Output ring

static unsigned char *ring;
static size_t ring_cap, ring_len, ring_head;
static int ring_wrapped;

static void ring_append(const unsigned char *p, size_t n) {
    if (ring_cap == 0) return;
    if (n >= ring_cap) {
        memcpy(ring, p + (n - ring_cap), ring_cap);
        ring_head = 0;
        ring_len = ring_cap;
        ring_wrapped = 1;
        return;
    }
    size_t tail = (ring_head + ring_len) % ring_cap;
    size_t first = n < ring_cap - tail ? n : ring_cap - tail;
    memcpy(ring + tail, p, first);
    memcpy(ring, p + first, n - first);
    if (ring_len + n > ring_cap) {
        ring_head = (ring_head + ring_len + n - ring_cap) % ring_cap;
        ring_len = ring_cap;
        ring_wrapped = 1;
    } else {
        ring_len += n;
    }
}

static unsigned char ring_at(size_t i) { return ring[(ring_head + i) % ring_cap]; }

// MARK: Terminal modes
// DEC private modes that change how keys, the mouse and pastes are encoded, or which screen is shown.
// Tracked over the whole session (not just what's in the ring) and re-sent after a replay.

static const int tracked_modes[] = {1047, 47, 1049, 1, 6, 7, 25, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 2004};
#define MODE_COUNT (int)(sizeof(tracked_modes) / sizeof(tracked_modes[0]))
static signed char mode_state[MODE_COUNT];  // -1 never set, 0 reset, 1 set
static int kitty_stack[16], kitty_depth;    // kitty keyboard protocol flags pushed with CSI > n u

static int esc_state;  // 0 text, 1 after ESC, 2 in CSI
static char csi_prefix;
static int csi_params[16], csi_count, csi_bad;

static void reset_modes(void) {
    memset(mode_state, -1, sizeof(mode_state));
    kitty_depth = 0;
}

static void csi_dispatch(unsigned char final) {
    int count = csi_count + 1;
    if (csi_prefix == '?' && (final == 'h' || final == 'l')) {
        for (int p = 0; p < count && p < 16; p++)
            for (int m = 0; m < MODE_COUNT; m++)
                if (tracked_modes[m] == csi_params[p]) mode_state[m] = final == 'h';
    } else if (csi_prefix == '>' && final == 'u') {
        if (kitty_depth < 16) kitty_stack[kitty_depth++] = csi_params[0];
    } else if (csi_prefix == '<' && final == 'u') {
        int n = csi_params[0] > 0 ? csi_params[0] : 1;
        kitty_depth = n >= kitty_depth ? 0 : kitty_depth - n;
    } else if (csi_prefix == '=' && final == 'u') {
        if (kitty_depth == 0) kitty_stack[kitty_depth++] = 0;
        int mode = count > 1 ? csi_params[1] : 1;
        int *top = &kitty_stack[kitty_depth - 1];
        if (mode == 1) *top = csi_params[0];
        else if (mode == 2) *top |= csi_params[0];
        else if (mode == 3) *top &= ~csi_params[0];
    }
}

static void track_modes(const unsigned char *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char c = p[i];
        switch (esc_state) {
        case 0:
            if (c == 0x1b) esc_state = 1;
            break;
        case 1:
            if (c == '[') {
                esc_state = 2;
                csi_prefix = 0;
                csi_count = 0;
                csi_bad = 0;
                memset(csi_params, 0, sizeof(csi_params));
            } else {
                if (c == 'c') reset_modes();  // RIS
                esc_state = c == 0x1b ? 1 : 0;
            }
            break;
        case 2:
            if (c >= '0' && c <= '9') {
                if (csi_count < 16 && csi_params[csi_count] < 100000) csi_params[csi_count] = csi_params[csi_count] * 10 + (c - '0');
            } else if (c == ';') {
                csi_count++;
            } else if ((c == '?' || c == '>' || c == '<' || c == '=') && csi_prefix == 0 && csi_count == 0 && csi_params[0] == 0) {
                csi_prefix = (char)c;
            } else if (c >= 0x40 && c <= 0x7e) {
                if (!csi_bad) csi_dispatch(c);
                esc_state = 0;
            } else if (c == 0x1b) {
                esc_state = 1;
            } else if (c < 0x20) {
                // C0 controls inside a sequence are executed and the sequence goes on
            } else {
                csi_bad = 1;  // intermediates: not a sequence we track
            }
            break;
        }
    }
}

// MARK: I/O

static int write_all(int fd, const void *buf, size_t n) {
    const unsigned char *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static void drop_client(void) {
    if (client_fd >= 0) close(client_fd);
    client_fd = -1;
}

static void send_frame(char type, const void *payload, size_t n) {
    if (client_fd < 0) return;
    unsigned char header[5] = {(unsigned char)type, (unsigned char)(n >> 24), (unsigned char)(n >> 16),
                               (unsigned char)(n >> 8), (unsigned char)n};
    if (write_all(client_fd, header, 5) < 0 || (n > 0 && write_all(client_fd, payload, n) < 0)) drop_client();
}

static void put_u32(unsigned char *p, uint32_t v) {
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static void send_replay(void) {
    unsigned char hello[12];
    put_u32(hello, PROTOCOL_VERSION);
    put_u32(hello + 4, (uint32_t)getpid());
    put_u32(hello + 8, (uint32_t)child);
    send_frame('h', hello, sizeof hello);
    // After the ring wrapped, start at a line boundary rather than mid-line or mid-sequence.
    size_t start = 0;
    if (ring_wrapped) {
        size_t limit = ring_len < 65536 ? ring_len : 65536;
        for (size_t i = 0; i < limit; i++)
            if (ring_at(i) == '\n') { start = i + 1; break; }
    }
    unsigned char chunk[65536];
    size_t used = 0;
    for (size_t i = start; i < ring_len && client_fd >= 0; i++) {
        chunk[used++] = ring_at(i);
        if (used == sizeof chunk) { send_frame('r', chunk, used); used = 0; }
    }
    if (used > 0) send_frame('r', chunk, used);
    // The modes in effect now, then the kitty keyboard stack.
    char modes[1024];
    int len = 0;
    for (int m = 0; m < MODE_COUNT; m++)
        if (mode_state[m] >= 0)
            len += snprintf(modes + len, sizeof modes - (size_t)len, "\033[?%d%c", tracked_modes[m], mode_state[m] ? 'h' : 'l');
    len += snprintf(modes + len, sizeof modes - (size_t)len, "\033[<99u");
    for (int k = 0; k < kitty_depth; k++)
        len += snprintf(modes + len, sizeof modes - (size_t)len, "\033[>%du", kitty_stack[k]);
    send_frame('r', modes, (size_t)len);
    send_frame('e', NULL, 0);
}

static unsigned char inbuf[MAX_FRAME + 5];
static size_t inlen;

// Keystrokes and pastes waiting for the program to read them. The terminal is non-blocking, so a program
// that isn't reading its input can't stop the holder from reading its output.
static unsigned char *pending_input;
static size_t pending_len, pending_cap;

static void queue_input(const unsigned char *p, size_t n) {
    if (pending_len + n > pending_cap) {
        size_t cap = pending_cap ? pending_cap : 4096;
        while (cap < pending_len + n) cap *= 2;
        unsigned char *grown = realloc(pending_input, cap);
        if (!grown) return;
        pending_input = grown;
        pending_cap = cap;
    }
    memcpy(pending_input + pending_len, p, n);
    pending_len += n;
}

static void flush_input(void) {
    while (pending_len > 0) {
        ssize_t w = write(master_fd, pending_input, pending_len);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN) pending_len = 0;
            return;
        }
        memmove(pending_input, pending_input + w, pending_len - (size_t)w);
        pending_len -= (size_t)w;
    }
}

static void handle_frame(unsigned char type, const unsigned char *p, size_t n) {
    if (type == 'i' && master_fd >= 0) {
        queue_input(p, n);
        flush_input();
    } else if (type == 'w' && n == 8 && master_fd >= 0) {
        struct winsize ws = {
            .ws_row = (unsigned short)(p[0] << 8 | p[1]), .ws_col = (unsigned short)(p[2] << 8 | p[3]),
            .ws_xpixel = (unsigned short)(p[4] << 8 | p[5]), .ws_ypixel = (unsigned short)(p[6] << 8 | p[7]),
        };
        if (ws.ws_row > 0 && ws.ws_col > 0) ioctl(master_fd, TIOCSWINSZ, &ws);
    } else if (type == 'd' && master_fd >= 0) {
        pid_t group = tcgetpgrp(master_fd);
        if (group > 0) kill(-group, SIGWINCH);
    }
}

static void read_client(void) {
    ssize_t n = read(client_fd, inbuf + inlen, sizeof inbuf - inlen);
    if (n <= 0) {
        if (n < 0 && errno == EINTR) return;
        drop_client();
        inlen = 0;
        return;
    }
    inlen += (size_t)n;
    size_t off = 0;
    while (inlen - off >= 5) {
        size_t len = (size_t)inbuf[off + 1] << 24 | (size_t)inbuf[off + 2] << 16 | (size_t)inbuf[off + 3] << 8 | inbuf[off + 4];
        if (len > MAX_FRAME) { drop_client(); inlen = 0; return; }
        if (inlen - off - 5 < len) break;
        handle_frame(inbuf[off], inbuf + off + 5, len);
        off += 5 + len;
    }
    memmove(inbuf, inbuf + off, inlen - off);
    inlen -= off;
}

static int read_master(void) {
    unsigned char buf[65536];
    ssize_t n = read(master_fd, buf, sizeof buf);
    if (n < 0 && (errno == EINTR || errno == EAGAIN)) return 1;
    if (n <= 0) return 0;  // EIO: every process closed the terminal
    ring_append(buf, (size_t)n);
    track_modes(buf, (size_t)n);
    send_frame('o', buf, (size_t)n);
    return 1;
}

static volatile sig_atomic_t stop_requested;

// SIGTERM or SIGINT: hang up the shell and leave, removing the socket (handled in the main loop).
static void on_stop(int sig) {
    (void)sig;
    int saved = errno;
    stop_requested = 1;
    char c = 1;
    (void)!write(sig_pipe[1], &c, 1);
    errno = saved;
}

static void on_sigchld(int sig) {
    (void)sig;
    int saved = errno;
    char c = 1;
    (void)!write(sig_pipe[1], &c, 1);
    errno = saved;
}

static void finish(int status) {
    // Whatever the shell printed last, then the exit status.
    if (master_fd >= 0) {
        for (int i = 0; i < 64 && read_master(); i++) {}
    }
    unsigned char st[4];
    put_u32(st, (uint32_t)status);
    send_frame('x', st, 4);
    unlink(socket_path);
    _exit(0);
}

static void cloexec(int fd) { fcntl(fd, F_SETFD, FD_CLOEXEC); }

int main(int argc, char **argv) {
    if (argc < 8) {
        fprintf(stderr, "usage: agentde-pty <socket> <rows> <cols> <ring-bytes> <cwd> <executable> <argv0> [args...]\n");
        return 2;
    }
    socket_path = argv[1];
    struct winsize ws = {.ws_row = (unsigned short)atoi(argv[2]), .ws_col = (unsigned short)atoi(argv[3])};
    if (ws.ws_row == 0) ws.ws_row = 24;
    if (ws.ws_col == 0) ws.ws_col = 80;
    ring_cap = (size_t)strtoul(argv[4], NULL, 10);
    const char *cwd = argv[5], *executable = argv[6];
    char **child_argv = argv + 7;
    if (strlen(socket_path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return 3;

    int ready[2];
    if (pipe(ready) < 0) return 4;
    pid_t first = fork();
    if (first < 0) return 4;
    if (first > 0) {
        // The caller waits for this process: it exits 0 once the socket accepts connections.
        close(ready[1]);
        char ok = 0;
        while (read(ready[0], &ok, 1) < 0 && errno == EINTR) {}
        _exit(ok == '1' ? 0 : 1);
    }
    close(ready[0]);
    cloexec(ready[1]);
    setsid();
    // Dispositions and the signal mask are inherited from whoever started the holder; start from known ones.
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    umask(077);
    reset_modes();
    ring = ring_cap ? malloc(ring_cap) : NULL;
    if (ring_cap && !ring) ring_cap = 0;

    listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strncpy(addr.sun_path, socket_path, sizeof addr.sun_path - 1);
    unlink(socket_path);
    if (listen_fd < 0 || bind(listen_fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(listen_fd, 4) < 0) {
        (void)!write(ready[1], "0", 1);
        _exit(5);
    }
    cloexec(listen_fd);
    if (pipe(sig_pipe) < 0) _exit(6);
    cloexec(sig_pipe[0]);
    cloexec(sig_pipe[1]);
    fcntl(sig_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(sig_pipe[1], F_SETFL, O_NONBLOCK);
    signal(SIGCHLD, on_sigchld);
    signal(SIGTERM, on_stop);
    signal(SIGINT, on_stop);

    child = forkpty(&master_fd, NULL, NULL, &ws);
    if (child < 0) {
        (void)!write(ready[1], "0", 1);
        unlink(socket_path);
        _exit(7);
    }
    if (child == 0) {
        // The shell gets ordinary signal handling back, and starts in the tab's folder.
        signal(SIGHUP, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        if (chdir(cwd) < 0) {
            // Never run the startup command or agent somewhere else: a plain login shell in ~, and say why.
            int err = errno;
            const char *home = getenv("HOME");
            if (home) (void)!chdir(home);
            fprintf(stderr, "\033[33magentde: can't open folder %s: %s; started a plain shell in your home folder.\033[0m\r\n",
                    cwd, strerror(err));
            unsetenv("AGENTDE_RUN");
            char *plain[] = {child_argv[0], "-l", NULL};
            execve(executable, plain, environ);
        } else {
            execve(executable, child_argv, environ);
        }
        fprintf(stderr, "agentde-pty: couldn't start %s: %s\n", executable, strerror(errno));
        _exit(127);
    }
    cloexec(master_fd);
    fcntl(master_fd, F_SETFL, fcntl(master_fd, F_GETFL) | O_NONBLOCK);
    (void)!write(ready[1], "1", 1);
    close(ready[1]);

    int master_open = 1;
    for (;;) {
        struct pollfd fds[4];
        int count = 0, li = -1, ci = -1, mi = -1, si;
        fds[count] = (struct pollfd){.fd = sig_pipe[0], .events = POLLIN}; si = count++;
        fds[count] = (struct pollfd){.fd = listen_fd, .events = POLLIN}; li = count++;
        if (client_fd >= 0) { fds[count] = (struct pollfd){.fd = client_fd, .events = POLLIN}; ci = count++; }
        if (master_open) {
            fds[count] = (struct pollfd){.fd = master_fd, .events = POLLIN | (pending_len ? POLLOUT : 0)};
            mi = count++;
        }
        if (poll(fds, (nfds_t)count, master_open ? -1 : 1000) < 0) {
            if (errno == EINTR) continue;
            _exit(8);
        }
        if (fds[si].revents) {
            char drain[64];
            while (read(sig_pipe[0], drain, sizeof drain) > 0) {}
        }
        if (stop_requested) {
            kill(child, SIGHUP);
            unlink(socket_path);
            _exit(0);
        }
        int status;
        if (waitpid(child, &status, WNOHANG) == child) finish(status);
        if (mi >= 0 && (fds[mi].revents & POLLOUT)) flush_input();
        if (mi >= 0 && (fds[mi].revents & (POLLIN | POLLHUP | POLLERR))) master_open = read_master();
        if (li >= 0 && (fds[li].revents & POLLIN)) {
            int fd = accept(listen_fd, NULL, NULL);
            if (fd >= 0) {
                // A newer client (AgentDE relaunched) replaces the old one.
                drop_client();
                inlen = 0;
                cloexec(fd);
                client_fd = fd;
                send_replay();
            }
        }
        if (ci >= 0 && client_fd >= 0 && fds[ci].revents) read_client();
    }
}
