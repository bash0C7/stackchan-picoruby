#include <stdint.h>

/* ITU-T G.711 mu-law: one 8-bit code to a signed 16-bit linear sample. */
static int16_t
ulaw_to_linear(uint8_t byte)
{
  uint8_t u = ~byte;
  int16_t t = ((u & 0x0F) << 3) + 0x84;
  t <<= (u & 0x70) >> 4;
  return (u & 0x80) ? (0x84 - t) : (t - 0x84);
}

#if defined(PICORB_VM_MRUBY)

#include "mruby/aw88298.c"

#elif defined(PICORB_VM_MRUBYC)

#error "picoruby-aw88298: mrubyc is not supported"

#endif
