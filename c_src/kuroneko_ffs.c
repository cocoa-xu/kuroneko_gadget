// SPDX-License-Identifier: Apache-2.0
//
// kuroneko_ffs: the ep0 and the endpoints of a FunctionFS function, for
// Kuroneko.Gadget.FunctionFS.
//
//     kuroneko_ffs DIR
//
// DIR is where the function's FunctionFS is mounted. The program and the VM
// exchange packets on stdin and stdout, each a 4-byte big-endian length and
// a body whose first byte is its kind.
//
// From the VM:
//   'D' descriptors      written to ep0               -> 'r' 'D' status
//   'S' strings          written to ep0               -> 'r' 'S' status
//   'O' n dir[n]         opens ep1..epn, dir 1 for IN -> 'r' 'O' status
//   'W' ep data          written to an IN endpoint    -> 'w' ep result
//   'R' ep size[4]       read from an OUT endpoint    -> 'd' ep data, or 'e' ep status
//   'C' data             answers the pending control request: an IN one
//                        with data, an OUT one by reading its data stage
//                                                     -> 'c' data (OUT), 'r' 'C' status
//   'X'                  stalls the pending request   -> 'r' 'X' status
//   'Q'                  quits
// To the VM:
//   'E' event            an event of ep0, 12 bytes
//
// A status or result is 4-byte big-endian: 0 or a byte count, or -errno. A
// control request not answered within two seconds is stalled.

#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/usb/functionfs.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_ENDPOINTS 30
#define MAX_READ (1 << 20)
#define ANSWER_SECONDS 2

struct request {
    struct request *next;
    uint32_t size;
    unsigned char data[];
};

struct endpoint {
    int number;
    int fd;
    int in;
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    struct request *head;
    struct request *tail;
};

static const char *dir;
static int ep0 = -1;
static struct endpoint endpoints[MAX_ENDPOINTS];
static int endpoint_count;

static pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;

static pthread_mutex_t setup_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t setup_cond;
static int setup_pending;
static struct request *setup_answer;

static void put_be32(unsigned char *at, uint32_t value)
{
    at[0] = value >> 24;
    at[1] = value >> 16;
    at[2] = value >> 8;
    at[3] = value;
}

static uint32_t get_be32(const unsigned char *at)
{
    return (uint32_t)at[0] << 24 | (uint32_t)at[1] << 16 | (uint32_t)at[2] << 8 | at[3];
}

static int write_full(int fd, const void *data, size_t size)
{
    const unsigned char *at = data;

    while (size > 0) {
        ssize_t n = write(fd, at, size);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        at += n;
        size -= n;
    }
    return 0;
}

static int read_full(int fd, void *data, size_t size)
{
    unsigned char *at = data;

    while (size > 0) {
        ssize_t n = read(fd, at, size);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return -1;
        at += n;
        size -= n;
    }
    return 0;
}

// One packet to the VM: the kind, a byte, then the data. The VM gone, the
// program has nothing left to do.
static void send_packet(char kind, int byte, const void *data, size_t size)
{
    unsigned char header[6];
    size_t header_size = byte < 0 ? 5 : 6;

    put_be32(header, size + header_size - 4);
    header[4] = kind;
    header[5] = byte;

    pthread_mutex_lock(&out_lock);
    if (write_full(STDOUT_FILENO, header, header_size) < 0 || write_full(STDOUT_FILENO, data, size) < 0)
        exit(0);
    pthread_mutex_unlock(&out_lock);
}

static void send_status(char kind, int byte, int32_t status)
{
    unsigned char value[4];

    put_be32(value, (uint32_t)status);
    send_packet(kind, byte, value, sizeof(value));
}

static int32_t status_of(ssize_t result)
{
    return result < 0 ? -errno : (int32_t)result;
}

// FunctionFS stalls a request on an ep0 access in the other direction:
// EL2HLT says it did.
static int32_t stall(int in)
{
    ssize_t result = in ? read(ep0, NULL, 0) : write(ep0, NULL, 0);

    if (result < 0 && errno == EL2HLT)
        return 0;
    return result < 0 ? -errno : -EPROTO;
}

static void answer_setup(const struct usb_ctrlrequest *setup)
{
    int in = setup->bRequestType & USB_DIR_IN;
    uint16_t length = le16toh(setup->wLength);
    struct timespec deadline;
    struct request *answer;

    clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_sec += ANSWER_SECONDS;

    pthread_mutex_lock(&setup_lock);
    setup_pending = 1;
    while (!setup_answer && pthread_cond_timedwait(&setup_cond, &setup_lock, &deadline) != ETIMEDOUT)
        ;
    answer = setup_answer;
    setup_answer = NULL;
    setup_pending = 0;
    pthread_mutex_unlock(&setup_lock);

    if (!answer) {
        stall(in);
        return;
    }

    if (answer->data[0] == 'X') {
        send_status('r', 'X', stall(in));
    } else if (in) {
        send_status('r', 'C', status_of(write(ep0, answer->data + 1, answer->size - 1)));
    } else {
        unsigned char *data = malloc(length ? length : 1);
        ssize_t n = data ? read(ep0, data, length) : -1;

        if (n >= 0)
            send_packet('c', -1, data, n);
        send_status('r', 'C', status_of(n));
        free(data);
    }
    free(answer);
}

static void *ep0_loop(void *unused)
{
    struct usb_functionfs_event event;

    (void)unused;
    for (;;) {
        ssize_t n = read(ep0, &event, sizeof(event));

        // EIDRM: the host gave up a request before it was answered.
        if (n < 0 && (errno == EINTR || errno == EIDRM))
            continue;
        if (n < 0) {
            send_status('r', 'E', -errno);
            exit(1);
        }
        if (n != sizeof(event))
            continue;

        send_packet('E', -1, &event, sizeof(event));
        if (event.type == FUNCTIONFS_SETUP)
            answer_setup(&event.u.setup);
    }
    return NULL;
}

static struct request *next_request(struct endpoint *ep)
{
    struct request *request;

    pthread_mutex_lock(&ep->lock);
    while (!ep->head)
        pthread_cond_wait(&ep->cond, &ep->lock);
    request = ep->head;
    ep->head = request->next;
    if (!ep->head)
        ep->tail = NULL;
    pthread_mutex_unlock(&ep->lock);
    return request;
}

// An IN endpoint writes what it is given, an empty write being a packet of
// zero length; an OUT endpoint reads as much as it is asked for.
static void *endpoint_loop(void *arg)
{
    struct endpoint *ep = arg;

    for (;;) {
        struct request *request = next_request(ep);

        if (ep->in) {
            ssize_t n;

            do {
                n = write(ep->fd, request->data, request->size);
            } while (n < 0 && errno == EINTR);
            send_status('w', ep->number, status_of(n));
        } else {
            unsigned char *data = malloc(request->size ? request->size : 1);
            ssize_t n;

            do {
                n = data ? read(ep->fd, data, request->size) : -1;
            } while (n < 0 && errno == EINTR);

            if (n >= 0)
                send_packet('d', ep->number, data, n);
            else
                send_status('e', ep->number, -errno);
            free(data);
        }
        free(request);
    }
    return NULL;
}

static void enqueue(struct endpoint *ep, struct request *request)
{
    pthread_mutex_lock(&ep->lock);
    if (ep->tail)
        ep->tail->next = request;
    else
        ep->head = request;
    ep->tail = request;
    pthread_cond_signal(&ep->cond);
    pthread_mutex_unlock(&ep->lock);
}

static int32_t open_endpoints(const unsigned char *dirs, size_t count)
{
    pthread_t thread;
    char path[4096];

    if (endpoint_count > 0 || count > MAX_ENDPOINTS)
        return -EINVAL;

    for (size_t i = 0; i < count; i++) {
        struct endpoint *ep = &endpoints[i];

        snprintf(path, sizeof(path), "%s/ep%zu", dir, i + 1);
        ep->number = i + 1;
        ep->in = dirs[i] != 0;
        ep->fd = open(path, O_RDWR | O_CLOEXEC);
        if (ep->fd < 0)
            return -errno;
        pthread_mutex_init(&ep->lock, NULL);
        pthread_cond_init(&ep->cond, NULL);
        if (pthread_create(&ep->thread, NULL, endpoint_loop, ep) != 0)
            return -EAGAIN;
        endpoint_count = i + 1;
    }

    if (pthread_create(&thread, NULL, ep0_loop, NULL) != 0)
        return -EAGAIN;
    return 0;
}

static struct request *new_request(uint32_t size, const void *data, size_t data_size)
{
    struct request *request = malloc(sizeof(*request) + data_size);

    if (!request)
        exit(1);
    request->next = NULL;
    request->size = size;
    memcpy(request->data, data, data_size);
    return request;
}

static struct endpoint *endpoint_of(int number, int in)
{
    if (number < 1 || number > endpoint_count || endpoints[number - 1].in != in)
        return NULL;
    return &endpoints[number - 1];
}

static void answer(const unsigned char *body, size_t size)
{
    pthread_mutex_lock(&setup_lock);
    if (setup_pending && !setup_answer) {
        setup_answer = new_request(size, body, size);
        pthread_cond_signal(&setup_cond);
        pthread_mutex_unlock(&setup_lock);
    } else {
        pthread_mutex_unlock(&setup_lock);
        send_status('r', body[0], -ENOENT);
    }
}

static void handle(const unsigned char *body, size_t size)
{
    struct endpoint *ep;

    switch (body[0]) {
    case 'D':
    case 'S': {
        ssize_t n = write(ep0, body + 1, size - 1);

        send_status('r', body[0], n < 0 ? -errno : 0);
        break;
    }

    case 'O':
        if (size < 2 || size - 2 != body[1])
            send_status('r', 'O', -EINVAL);
        else
            send_status('r', 'O', open_endpoints(body + 2, body[1]));
        break;

    case 'W':
        if (size < 2 || !(ep = endpoint_of(body[1], 1)))
            send_status('w', size < 2 ? 0 : body[1], -EINVAL);
        else
            enqueue(ep, new_request(size - 2, body + 2, size - 2));
        break;

    case 'R':
        if (size != 6 || !(ep = endpoint_of(body[1], 0)) || get_be32(body + 2) > MAX_READ)
            send_status('e', size < 2 ? 0 : body[1], -EINVAL);
        else
            enqueue(ep, new_request(get_be32(body + 2), NULL, 0));
        break;

    case 'C':
    case 'X':
        answer(body, size);
        break;

    case 'Q':
        exit(0);

    default:
        send_status('r', body[0], -EINVAL);
    }
}

int main(int argc, char *argv[])
{
    char path[4096];
    pthread_condattr_t attr;

    if (argc != 2) {
        fprintf(stderr, "usage: kuroneko_ffs DIR\n");
        return 2;
    }

    signal(SIGPIPE, SIG_IGN);
    dir = argv[1];
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    pthread_cond_init(&setup_cond, &attr);

    snprintf(path, sizeof(path), "%s/ep0", dir);
    ep0 = open(path, O_RDWR | O_CLOEXEC);
    if (ep0 < 0) {
        send_status('r', 'E', -errno);
        return 1;
    }

    for (;;) {
        unsigned char header[4];
        unsigned char *body;
        uint32_t size;

        if (read_full(STDIN_FILENO, header, sizeof(header)) < 0)
            return 0;
        size = get_be32(header);
        if (size == 0 || size > MAX_READ + 16 || !(body = malloc(size)))
            return 1;
        if (read_full(STDIN_FILENO, body, size) < 0)
            return 0;
        handle(body, size);
        free(body);
    }
}
