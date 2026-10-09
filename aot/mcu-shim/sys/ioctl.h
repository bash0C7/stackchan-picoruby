/* sp_io.c の #winsize 用。宣言だけ。 */
#ifndef MCU_SHIM_SYS_IOCTL_H
#define MCU_SHIM_SYS_IOCTL_H
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
#define TIOCGWINSZ 0x5413
int ioctl(int, unsigned long, ...);
#endif
