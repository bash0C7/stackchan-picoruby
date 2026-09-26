/* -include で全 TU に入れる。xtensa (32bit) に __int128 は無い。
 * 使うのは sp_time.c の Time + Float / Time.at(Rational) の経路だけ (sp_bigint.c は __SIZEOF_INT128__ で分岐済み)。
 * long long (64bit) で置き換えるので、その経路は範囲が狭くなる。入口から到達しない前提 (--gc-sections で実体は消える)。 */
#ifndef MCU_COMPAT_H
#define MCU_COMPAT_H
#ifndef __SIZEOF_INT128__
#define __int128 long long
#endif
/* sp_alloc.c の allocation report が sigaction(SA_RESTART) を使う。newlib の <signal.h> は SA_RESTART を持たない。
 * SPINEL_ALLOC_REPORT を有効にしない限り実行されない。 */
#include <stdio.h>
#include <sys/stat.h>
/* sp_cold.c / sp_io.c が呼ぶが newlib が宣言しない関数 (gcc 14 は暗黙宣言を error にする)。
 * 定義は無い: File / Process / IO の該当メソッドが入口から到達しなければ --gc-sections で消え、link に影響しない。 */
int lstat(const char *, struct stat *);
int getpriority(int, int);
size_t __freadahead(FILE *);
#define PF_UNSPEC 0
#define PF_UNIX 1
#define PF_INET 2
#define PF_INET6 10
#include <signal.h>
#ifndef SA_RESTART
#define SA_RESTART 0x10000000
#endif
/* arm-none-eabi の newlib は clock_gettime / clock_getres / nanosleep を宣言しない (_POSIX_TIMERS が無い)。
 * sp_time.c / sp_sched.c / sp_alloc.c / spinel_rt.h / sp_cold.c が使う。ESP-IDF には宣言があるので arm のときだけ。
 * 実装は mcu_stubs.c の weak stub (arm のときだけ。失敗を返す)。 */
#ifdef __arm__
#include <time.h>
#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
#endif
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif
int clock_gettime(clockid_t, struct timespec *);
int clock_getres(clockid_t, struct timespec *);
int nanosleep(const struct timespec *, struct timespec *);
#endif
#endif
