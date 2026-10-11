/*
 * universe_run: launch one worker command and own its whole process group.
 *
 *   universe_run [--fsize BYTES] [--grace MS] -- cmd [args...]
 *
 * The child runs in a new session (its pid is the process group id), with
 * stdin from /dev/null. Talks to the BEAM over stdio with {packet, 4} framing.
 *
 * To the BEAM:   'P' pid:32      started
 *                'O' bytes       stdout chunk
 *                'E' bytes       stderr chunk
 *                'X' code:32 signal:32   main process exited, group reaped
 * From the BEAM: 'K'             SIGTERM the group, SIGKILL after the grace
 *                EOF             SIGKILL the group now and exit
 *
 * When the main process exits, anything left in its group is killed, so
 * backgrounded leftovers never outlive a worker. A process that deliberately
 * leaves the group (setsid, daemonising) escapes this; catching that safely
 * needs OS-level process tracking and is a known gap (see docs/PLAN.md).
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static pid_t child = -1;

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void write_all(const void *buf, size_t len)
{
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(STDOUT_FILENO, p, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            /* BEAM is gone: take the group down with us. */
            if (child > 0) {
                killpg(child, SIGKILL);
                kill(child, SIGKILL);
            }
            _exit(1);
        }
        p += n;
        len -= (size_t) n;
    }
}

static void send_packet(char tag, const void *data, size_t len)
{
    uint32_t size = htonl((uint32_t) (len + 1));
    write_all(&size, 4);
    write_all(&tag, 1);
    if (len > 0)
        write_all(data, len);
}

static void signal_group(int sig)
{
    /* killpg covers the group; kill() covers the instant before setsid(). */
    killpg(child, sig);
    kill(child, sig);
}

int main(int argc, char *argv[])
{
    long long fsize = 0;
    long long grace_ms = 2000;
    int i = 1;

    for (; i < argc; i++) {
        if (strcmp(argv[i], "--fsize") == 0 && i + 1 < argc)
            fsize = atoll(argv[++i]);
        else if (strcmp(argv[i], "--grace") == 0 && i + 1 < argc)
            grace_ms = atoll(argv[++i]);
        else if (strcmp(argv[i], "--") == 0) {
            i++;
            break;
        } else
            break;
    }
    if (i >= argc) {
        fprintf(stderr, "usage: universe_run [--fsize BYTES] [--grace MS] -- cmd [args...]\n");
        return 2;
    }

    signal(SIGPIPE, SIG_IGN);

    int out[2], err[2];
    if (pipe(out) < 0 || pipe(err) < 0) {
        perror("universe_run: pipe");
        return 1;
    }

    child = fork();
    if (child < 0) {
        perror("universe_run: fork");
        return 1;
    }

    if (child == 0) {
        setsid();
        int devnull = open("/dev/null", O_RDONLY);
        dup2(devnull, STDIN_FILENO);
        dup2(out[1], STDOUT_FILENO);
        dup2(err[1], STDERR_FILENO);
        close(devnull);
        close(out[0]);
        close(out[1]);
        close(err[0]);
        close(err[1]);
        if (fsize > 0) {
            struct rlimit rl = {(rlim_t) fsize, (rlim_t) fsize};
            setrlimit(RLIMIT_FSIZE, &rl);
        }
        signal(SIGPIPE, SIG_DFL);
        execvp(argv[i], &argv[i]);
        fprintf(stderr, "universe_run: exec %s: %s\n", argv[i], strerror(errno));
        _exit(127);
    }

    close(out[1]);
    close(err[1]);

    uint32_t pid_be = htonl((uint32_t) child);
    send_packet('P', &pid_be, 4);

    struct pollfd fds[3] = {
        {STDIN_FILENO, POLLIN, 0},
        {out[0], POLLIN, 0},
        {err[0], POLLIN, 0},
    };

    char buf[65536];
    unsigned char inbuf[64];
    size_t inlen = 0;
    int alive = 1, status = 0;
    long long kill_at = -1, drain_until = -1;

    for (;;) {
        int open_pipes = (fds[1].fd >= 0) + (fds[2].fd >= 0);
        if (!alive && (open_pipes == 0 || now_ms() > drain_until))
            break;

        int rc = poll(fds, 3, 50);
        if (rc < 0 && errno != EINTR) {
            /* Can't watch the child any more: kill the group and report the
               real end, never a made-up exit 0. */
            perror("universe_run: poll");
            if (alive) {
                signal_group(SIGKILL);
                waitpid(child, &status, 0);
                alive = 0;
            }
            break;
        }

        if (fds[0].fd >= 0 && (fds[0].revents & (POLLIN | POLLHUP))) {
            ssize_t n = read(STDIN_FILENO, inbuf + inlen, sizeof(inbuf) - inlen);
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
                n = 0; /* interrupted: try again next round */
            } else if (n <= 0) {
                signal_group(SIGKILL);
                waitpid(child, NULL, 0);
                return 0;
            }
            inlen += (size_t) n;
            while (inlen >= 4) {
                uint32_t size;
                memcpy(&size, inbuf, 4);
                size = ntohl(size);
                if (size == 0 || size > sizeof(inbuf) - 4) {
                    inlen = 0; /* malformed: drop */
                    break;
                }
                if (inlen < 4 + size)
                    break;
                if (inbuf[4] == 'K' && alive && kill_at < 0) {
                    signal_group(SIGTERM);
                    kill_at = now_ms() + grace_ms;
                }
                memmove(inbuf, inbuf + 4 + size, inlen - 4 - size);
                inlen -= 4 + size;
            }
        }

        for (int k = 1; k <= 2; k++) {
            if (fds[k].fd >= 0 && (fds[k].revents & (POLLIN | POLLHUP))) {
                ssize_t n = read(fds[k].fd, buf, sizeof(buf));
                if (n > 0)
                    send_packet(k == 1 ? 'O' : 'E', buf, (size_t) n);
                else if (n == 0 || errno != EINTR) {
                    close(fds[k].fd);
                    fds[k].fd = -1;
                }
            }
        }

        if (alive && kill_at >= 0 && now_ms() >= kill_at)
            signal_group(SIGKILL);

        if (alive) {
            /* Peek without reaping: while the exited leader is a zombie its
               pid (the group id) can't be reused, so killing the leftovers
               can't hit an unrelated new group. Then reap it. */
            siginfo_t si;
            memset(&si, 0, sizeof si);
            if (waitid(P_PID, (id_t) child, &si, WEXITED | WNOHANG | WNOWAIT) == 0 &&
                si.si_pid == child) {
                killpg(child, SIGKILL);
                waitpid(child, &status, 0);
                alive = 0;
                drain_until = now_ms() + 1000;
            }
        }
    }

    uint32_t code = 0, sig = 0;
    if (WIFEXITED(status))
        code = (uint32_t) WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) {
        sig = (uint32_t) WTERMSIG(status);
        code = 128 + sig;
    }
    uint32_t payload[2] = {htonl(code), htonl(sig)};
    send_packet('X', payload, sizeof(payload));
    return 0;
}
