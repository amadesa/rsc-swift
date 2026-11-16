#ifndef _H_RELAY_TRANSPORT
#define _H_RELAY_TRANSPORT

#include <stddef.h>
#include <stdint.h>

/*
 * Lets packet-stream.c reach the game server through rsc-relay (HTTPS)
 * instead of a TCP socket, for platforms such as watchOS that don't allow
 * raw connections. The game thread uses these like a non-blocking socket;
 * the HTTP side lives in the app (RelayTransport.swift) and talks to this
 * file through the rsc_relay_* functions in rsc-bridge.h.
 */

/* whether new connections should go through the relay */
int relay_transport_enabled(void);

/* blocks until connected (0) or failed (-1) */
int relay_transport_connect(const char *host, int port);

/* like recv() on a non-blocking socket: bytes read, 0 once the connection
 * has closed, or -1 when nothing has arrived yet */
int relay_transport_recv(void *buffer, size_t length);

/* queues bytes to send; returns length, or -1 once closed */
int relay_transport_send(const void *buffer, size_t length);

void relay_transport_close(void);

/* why the latest connection couldn't be opened, as two short lines for the
 * login screen, if the app said (rsc_relay_failed); returns 0 otherwise */
int relay_transport_failure(char *title, char *advice, size_t length);

#endif
