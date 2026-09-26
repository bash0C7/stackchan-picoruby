/* arm-none-eabi の newlib は <dirent.h> を `#error "<dirent.h> not supported"` にする (sp_cold.c / sp_io.h が要る)。
 * ESP-IDF (xtensa) には本物があるので、arm のときだけ宣言を出し、それ以外は本物へ回す。
 * 実装は mcu_stubs.c の weak stub (arm のときだけ。常に失敗を返す)。Dir は Pico 2 W の展示で使わない。 */
#ifdef __arm__
#ifndef MCU_SHIM_DIRENT_H
#define MCU_SHIM_DIRENT_H
#include <sys/types.h>
typedef struct mcu_dir DIR;
struct dirent {
  ino_t d_ino;
  unsigned char d_type;
  char d_name[256];
};
#define DT_UNKNOWN 0
#define DT_FIFO 1
#define DT_CHR 2
#define DT_DIR 4
#define DT_BLK 6
#define DT_REG 8
#define DT_LNK 10
#define DT_SOCK 12
DIR *opendir(const char *);
DIR *fdopendir(int);
struct dirent *readdir(DIR *);
int closedir(DIR *);
void rewinddir(DIR *);
long telldir(DIR *);
void seekdir(DIR *, long);
int dirfd(DIR *);
#endif
#else
#include_next <dirent.h>
#endif
