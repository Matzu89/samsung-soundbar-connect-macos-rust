#pragma once

#include <stddef.h>

/* Opaque session. All calls happen on the GTK main thread. */
typedef struct SoundbarConnection SoundbarConnection;

SoundbarConnection *soundbar_connection_start(void);

/* Pumps Bluetooth events and advances the connection.
   *finished is 1 when the attempt is over. *ok is 1 on success.
   status is a UTF-8 sentence for the window. */
void soundbar_connection_poll(
    SoundbarConnection *connection,
    char *status,
    size_t status_len,
    int *finished,
    int *ok
);

void soundbar_connection_free(SoundbarConnection *connection);
