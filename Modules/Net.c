#include "Net.h"
#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

/* One receive buffer per process is enough for the single-connection
 * clients this module serves; it is keyed by handle so a stale buffer
 * never leaks into a new connection. */
static unsigned char rbuf[4096];
static int rlen = 0, rpos = 0, rfd = -1;

int Net_Connect(char *host, int port)
{
    struct addrinfo hints, *res, *ai;
    char portstr[16];
    int fd = -1;

    signal(SIGPIPE, SIG_IGN);
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(portstr, sizeof(portstr), "%d", port);
    if (getaddrinfo(host, portstr, &hints, &res) != 0) return -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) { rfd = fd; rlen = rpos = 0; }
    return fd;
}

int Net_ReadByte(int h)
{
    struct pollfd p;
    ssize_t n;

    if (h < 0) return -2;
    if (h == rfd && rpos < rlen) return rbuf[rpos++];
    p.fd = h; p.events = POLLIN; p.revents = 0;
    if (poll(&p, 1, 0) <= 0) return -1;
    n = recv(h, rbuf, sizeof(rbuf), 0);
    if (n == 0) return -2;
    if (n < 0) return (errno == EAGAIN || errno == EINTR) ? -1 : -2;
    rfd = h; rlen = (int)n; rpos = 1;
    return rbuf[0];
}

int Net_WriteByte(int h, int b)
{
    unsigned char c = (unsigned char)b;
    return send(h, &c, 1, 0) == 1;
}

int Net_Wait(int h, int ms)
{
    struct pollfd p[2];

    if (h == rfd && rpos < rlen) return 1;
    p[0].fd = h;            p[0].events = POLLIN; p[0].revents = 0;
    p[1].fd = STDIN_FILENO; p[1].events = POLLIN; p[1].revents = 0;
    return poll(p, 2, ms) > 0;
}

void Net_Close(int h)
{
    if (h >= 0) close(h);
    if (h == rfd) { rfd = -1; rlen = rpos = 0; }
}
