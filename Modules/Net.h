#ifndef OBC_NET_H_
#define OBC_NET_H_

/* Net — minimal TCP client sockets (C implementation, FFI-bound).
 *
 * Connections are identified by a small integer handle (the socket fd).
 * Input strings are NUL-terminated; no hidden length arg is passed.
 */

int  Net_Connect(char *host, int port);   /* handle >= 0, or -1 on failure */
int  Net_ReadByte(int h);                 /* 0..255; -1 = no data yet; -2 = closed */
int  Net_WriteByte(int h, int b);         /* 1 = ok, 0 = error */
int  Net_Wait(int h, int ms);             /* block until socket or stdin readable, or ms elapse;
                                             1 = something ready, 0 = timeout */
void Net_Close(int h);

#endif /* OBC_NET_H_ */
