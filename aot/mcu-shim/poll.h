/* poll は ESP-IDF に無い (sp_io / sp_sched の socket park 用)。宣言だけ。 */
#ifndef MCU_SHIM_POLL_H
#define MCU_SHIM_POLL_H
struct pollfd { int fd; short events; short revents; };
typedef unsigned int nfds_t;
#define POLLIN 0x001
#define POLLPRI 0x002
#define POLLOUT 0x004
#define POLLERR 0x008
#define POLLHUP 0x010
#define POLLNVAL 0x020
int poll(struct pollfd *, nfds_t, int);
#endif
