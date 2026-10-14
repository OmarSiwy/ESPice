/* The VPI application tests/fixtures/hdl/veriloga_vpi_app.sp loads (#197).
 * LRM 12.32: it registers the analog system function $espice_gain(g), whose
 * calltf puts its argument back on the call (12.30), so the call's value is
 * g. Stateless and with no derivtf: g is a constant, so every partial is 0. */
#include "vpi_user.h"

static PLI_INT32 gain_calltf(p_cb_data cb)
{
  vpiHandle call, arg;
  s_vpi_value v;
  (void)cb;
  call = vpi_handle(vpiSysTfCall, NULL);
  arg = vpi_handle_by_index(call, 1);
  v.format = vpiRealVal;
  vpi_get_value(arg, &v);
  vpi_put_value(call, &v, NULL, vpiNoDelay);
  return 0;
}

static void register_gain(void)
{
  static char name[] = "$espice_gain";
  s_vpi_analog_systf_data d = {0};
  d.type = vpiAnalogSysFunc;
  d.sysfunctype = vpiRealFunc;
  d.tfname = name;
  d.calltf = gain_calltf;
  vpi_register_analog_systf(&d);
}

void (*vlog_startup_routines[])(void) = { register_gain, 0 };
