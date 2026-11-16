#include "relay-transport.h"
#include "rsc-bridge.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* how long connect() waits for the relay to open a session */
#define CONNECT_TIMEOUT_SECONDS 20

/* stop queueing sends if the app can't deliver them (connection stalled) */
#define MAX_PENDING_SEND (1 << 20)

typedef enum {
    RELAY_IDLE,
    RELAY_CONNECTING,
    RELAY_OPEN,
    RELAY_CLOSED
} RelayState;

static pthread_mutex_t relay_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t relay_changed = PTHREAD_COND_INITIALIZER;

static int relay_enabled = 0;
static RelayState relay_state = RELAY_IDLE;

/* bumped for every connection so late callbacks from an old one are
 * ignored */
static int relay_generation = 0;

static RelayCallbacks callbacks = {0};

/* why the latest connection failed, from the app, for the login screen */
#define FAILURE_LENGTH 96
static char failure_title[FAILURE_LENGTH];
static char failure_advice[FAILURE_LENGTH];
static int failure_generation = -1;

/* bytes from the server the game hasn't read yet */
static uint8_t *received = NULL;
static size_t received_length = 0;
static size_t received_capacity = 0;

/* bytes the game wrote that the app hasn't taken to send yet */
static uint8_t *pending = NULL;
static size_t pending_length = 0;
static size_t pending_capacity = 0;

static int append(uint8_t **buffer, size_t *length, size_t *capacity,
                  const void *data, size_t size) {
    if (*length + size > *capacity) {
        size_t new_capacity = *capacity ? *capacity : 4096;

        while (new_capacity < *length + size) {
            new_capacity *= 2;
        }

        uint8_t *grown = realloc(*buffer, new_capacity);

        if (grown == NULL) {
            return -1;
        }

        *buffer = grown;
        *capacity = new_capacity;
    }

    memcpy(*buffer + *length, data, size);
    *length += size;
    return 0;
}

/* must hold relay_lock */
static void reset_buffers(void) {
    received_length = 0;
    pending_length = 0;
}

/* --- app side (rsc-bridge.h) --- */

void rsc_relay_configure(int enabled, RelayCallbacks relay_callbacks) {
    pthread_mutex_lock(&relay_lock);
    relay_enabled = enabled;
    callbacks = relay_callbacks;
    pthread_mutex_unlock(&relay_lock);
}

void rsc_relay_opened(int generation, int success) {
    pthread_mutex_lock(&relay_lock);

    if (generation == relay_generation && relay_state == RELAY_CONNECTING) {
        relay_state = success ? RELAY_OPEN : RELAY_CLOSED;
        pthread_cond_broadcast(&relay_changed);
    }

    pthread_mutex_unlock(&relay_lock);
}

void rsc_relay_failed(int generation, const char *title, const char *advice) {
    pthread_mutex_lock(&relay_lock);

    snprintf(failure_title, sizeof(failure_title), "%s", title);
    snprintf(failure_advice, sizeof(failure_advice), "%s", advice);
    failure_generation = generation;

    pthread_mutex_unlock(&relay_lock);
}

void rsc_relay_received(int generation, const void *data, size_t length) {
    pthread_mutex_lock(&relay_lock);

    if (generation == relay_generation && relay_state == RELAY_OPEN &&
        append(&received, &received_length, &received_capacity, data,
               length) < 0) {
        relay_state = RELAY_CLOSED;
    }

    pthread_mutex_unlock(&relay_lock);
}

void rsc_relay_closed(int generation) {
    pthread_mutex_lock(&relay_lock);

    if (generation == relay_generation) {
        relay_state = RELAY_CLOSED;
        pthread_cond_broadcast(&relay_changed);
    }

    pthread_mutex_unlock(&relay_lock);
}

size_t rsc_relay_take_pending(int generation, void *buffer, size_t length) {
    pthread_mutex_lock(&relay_lock);

    size_t taken = 0;

    if (generation == relay_generation && pending_length > 0) {
        taken = pending_length < length ? pending_length : length;
        memcpy(buffer, pending, taken);
        memmove(pending, pending + taken, pending_length - taken);
        pending_length -= taken;
    }

    pthread_mutex_unlock(&relay_lock);
    return taken;
}

/* --- game side (packet-stream.c) --- */

int relay_transport_enabled(void) {
    pthread_mutex_lock(&relay_lock);
    int enabled = relay_enabled && callbacks.open != NULL;
    pthread_mutex_unlock(&relay_lock);
    return enabled;
}

int relay_transport_connect(const char *host, int port) {
    pthread_mutex_lock(&relay_lock);

    int generation = ++relay_generation;
    relay_state = RELAY_CONNECTING;
    reset_buffers();
    RelayCallbacks relay = callbacks;

    pthread_mutex_unlock(&relay_lock);

    relay.open(relay.context, generation, host, port);

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += CONNECT_TIMEOUT_SECONDS;

    pthread_mutex_lock(&relay_lock);

    while (relay_state == RELAY_CONNECTING && generation == relay_generation) {
        if (pthread_cond_timedwait(&relay_changed, &relay_lock, &deadline) != 0) {
            relay_state = RELAY_CLOSED;

            if (failure_generation != generation) {
                snprintf(failure_title, sizeof(failure_title),
                         "The relay didn't answer");
                snprintf(failure_advice, sizeof(failure_advice),
                         "Is the Mac awake, with Tailscale on?");
                failure_generation = generation;
            }
            break;
        }
    }

    int connected = relay_state == RELAY_OPEN && generation == relay_generation;
    pthread_mutex_unlock(&relay_lock);

    if (!connected) {
        relay.close(relay.context, generation);
    }

    return connected ? 0 : -1;
}

int relay_transport_recv(void *buffer, size_t length) {
    pthread_mutex_lock(&relay_lock);

    int result;

    if (received_length > 0) {
        size_t copied = received_length < length ? received_length : length;
        memcpy(buffer, received, copied);
        memmove(received, received + copied, received_length - copied);
        received_length -= copied;
        result = (int)copied;
    } else if (relay_state != RELAY_OPEN) {
        result = 0;
    } else {
        result = -1;
    }

    pthread_mutex_unlock(&relay_lock);
    return result;
}

int relay_transport_send(const void *buffer, size_t length) {
    pthread_mutex_lock(&relay_lock);

    int ok = relay_state == RELAY_OPEN &&
             pending_length + length <= MAX_PENDING_SEND &&
             append(&pending, &pending_length, &pending_capacity, buffer,
                    length) == 0;

    int generation = relay_generation;
    RelayCallbacks relay = callbacks;

    pthread_mutex_unlock(&relay_lock);

    if (!ok) {
        return -1;
    }

    relay.send(relay.context, generation);
    return (int)length;
}

int relay_transport_failure(char *title, char *advice, size_t length) {
    pthread_mutex_lock(&relay_lock);

    int has_failure = relay_enabled && failure_generation == relay_generation;

    if (has_failure) {
        snprintf(title, length, "%s", failure_title);
        snprintf(advice, length, "%s", failure_advice);
    }

    pthread_mutex_unlock(&relay_lock);
    return has_failure;
}

void relay_transport_close(void) {
    pthread_mutex_lock(&relay_lock);

    int generation = relay_generation;
    int was_open = relay_state == RELAY_OPEN || relay_state == RELAY_CONNECTING;
    relay_state = RELAY_CLOSED;
    reset_buffers();
    RelayCallbacks relay = callbacks;

    pthread_mutex_unlock(&relay_lock);

    if (was_open && relay.close != NULL) {
        relay.close(relay.context, generation);
    }
}
