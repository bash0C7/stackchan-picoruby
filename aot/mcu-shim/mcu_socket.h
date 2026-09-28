/* sys/socket.h, netinet/in.h, netinet/tcp.h, sys/un.h の共通の中身。newlib (ESP-IDF の libc) は lwIP を別に持つが、
 * libmruby の rake の compile には ESP-IDF の include path が無いので、sp_io.c / sp_cold.c が読める最小の宣言だけをここに置く。
 * 定数の値は Linux のもの (実行時に socket は使わない: sp_net.c は除外され、到達しなければ --gc-sections で消える)。 */
#ifndef MCU_SOCKET_H
#define MCU_SOCKET_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef unsigned int socklen_t;
typedef unsigned short sa_family_t;
struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
struct in_addr { uint32_t s_addr; };
struct sockaddr_in { sa_family_t sin_family; uint16_t sin_port; struct in_addr sin_addr; unsigned char sin_zero[8]; };
struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; };
struct linger { int l_onoff; int l_linger; };

#define AF_UNSPEC 0
#define AF_UNIX 1
#define AF_INET 2
#define AF_INET6 10
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_RAW 3
#define SOCK_SEQPACKET 5
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define SO_TYPE 3
#define SO_ERROR 4
#define SO_DONTROUTE 5
#define SO_BROADCAST 6
#define SO_SNDBUF 7
#define SO_RCVBUF 8
#define SO_KEEPALIVE 9
#define SO_OOBINLINE 10
#define SO_LINGER 13
#define SO_REUSEPORT 15
#define SO_RCVLOWAT 18
#define SO_SNDLOWAT 19
#define SO_RCVTIMEO 20
#define SO_SNDTIMEO 21
#define SO_ACCEPTCONN 30
#define MSG_OOB 1
#define MSG_PEEK 2
#define MSG_DONTROUTE 4
#define MSG_WAITALL 0x100
#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2
#define IPPROTO_IP 0
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17
#define IPPROTO_IPV6 41
#define TCP_NODELAY 1
#define TCP_MAXSEG 2
#define TCP_KEEPIDLE 4
#define TCP_KEEPINTVL 5
#define TCP_KEEPCNT 6
#define TCP_KEEPALIVE TCP_KEEPIDLE

int socket(int, int, int);
int connect(int, const struct sockaddr *, socklen_t);
int bind(int, const struct sockaddr *, socklen_t);
int listen(int, int);
int accept(int, struct sockaddr *, socklen_t *);
int shutdown(int, int);
int getsockopt(int, int, int, void *, socklen_t *);
int setsockopt(int, int, int, const void *, socklen_t);
int getsockname(int, struct sockaddr *, socklen_t *);
int getpeername(int, struct sockaddr *, socklen_t *);
ssize_t send(int, const void *, size_t, int);
ssize_t recv(int, void *, size_t, int);
ssize_t sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
ssize_t recvfrom(int, void *, size_t, int, struct sockaddr *, socklen_t *);
#endif
