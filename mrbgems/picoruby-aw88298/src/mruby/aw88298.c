#include "mruby.h"
#include "mruby/presym.h"
#include "mruby/string.h"

/* AW88298.ulaw_decode(ulaw) -> little-endian signed 16-bit PCM String */
static mrb_value
mrb_aw88298_s_ulaw_decode(mrb_state *mrb, mrb_value klass)
{
  mrb_value input;
  mrb_get_args(mrb, "S", &input);
  const uint8_t *in = (const uint8_t *)RSTRING_PTR(input);
  mrb_int len = RSTRING_LEN(input);

  mrb_value out = mrb_str_new(mrb, NULL, len * 2);
  uint8_t *pcm = (uint8_t *)RSTRING_PTR(out);
  for (mrb_int i = 0; i < len; i++) {
    uint16_t v = (uint16_t)ulaw_to_linear(in[i]);
    pcm[i * 2]     = v & 0xFF;
    pcm[i * 2 + 1] = (v >> 8) & 0xFF;
  }
  return out;
}

void
mrb_picoruby_aw88298_gem_init(mrb_state *mrb)
{
  struct RClass *class_AW88298 = mrb_define_class_id(mrb, MRB_SYM(AW88298), mrb->object_class);
  mrb_define_class_method_id(mrb, class_AW88298, MRB_SYM(ulaw_decode), mrb_aw88298_s_ulaw_decode, MRB_ARGS_REQ(1));
}

void
mrb_picoruby_aw88298_gem_final(mrb_state *mrb)
{
}
