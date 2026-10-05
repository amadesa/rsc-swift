#ifndef WORLDLIST_H
#define WORLDLIST_H

#include "../mudclient.h"

void worldlist_new(mudclient *mud);
void worldlist_handle_mouse(mudclient *mud);
void worldlist_add(mudclient *mud, const char *name, const char *host,
                   int port, const char *rsa_exponent,
                   const char *rsa_modulus, const char *register_url);
void worldlist_remove(mudclient *mud, int index);
#ifdef IOS
void worldlist_register(mudclient *mud);
#endif
#endif
