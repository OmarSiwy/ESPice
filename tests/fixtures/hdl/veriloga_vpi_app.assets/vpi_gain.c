/* The VPI application the `* VPI FIXTURE` decks load (#197, #198).
 * LRM 12.32: it registers the analog system function $espice_gain(g), whose
 * calltf puts its argument back on the call (12.30), so the call's value is
 * g. Stateless and with no derivtf: g is a constant, so every partial is 0.
 *
 * $espice_scaled(g) is g * scale, and the 12.31.3 analog callbacks move
 * scale (veriloga_vpi_callbacks.sp): 0 until acbInitialStep, 1 after it;
 * the first acbConvergenceTest rejects its solution; the acbAbsTime at
 * T_SWITCH sets 2, or 3 when no rejection was asked. */
#include <stddef.h>
#include "vpi_user.h"

/* VerA's numbers for the 12.31.3 reasons, which vpi_user.h leaves out. */
#define acbInitialStep 701
#define acbAbsTime 703
#define acbConvergenceTest 705
#define T_SWITCH 0.37e-3

static double scale = 0;
static int rejected = 0;

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

static PLI_INT32 scaled_calltf(p_cb_data cb)
{
  vpiHandle call;
  s_vpi_value v;
  (void)cb;
  call = vpi_handle(vpiSysTfCall, NULL);
  v.format = vpiRealVal;
  vpi_get_value(vpi_handle_by_index(call, 1), &v);
  v.value.real *= scale;
  vpi_put_value(call, &v, NULL, vpiNoDelay);
  return 0;
}

static PLI_INT32 on_initial(p_cb_data cb)
{
  (void)cb;
  scale = 1;
  return 0;
}

static PLI_INT32 on_converge(p_cb_data cb)
{
  (void)cb;
  if (rejected) return 0;
  rejected = 1;
  return 1;
}

static PLI_INT32 on_switch(p_cb_data cb)
{
  (void)cb;
  scale = rejected ? 2 : 3;
  return 0;
}

static PLI_INT32 on_compile(p_cb_data cb)
{
  s_cb_data d = {0};
  s_vpi_time t = {0};
  (void)cb;
  d.reason = acbInitialStep;
  d.cb_rtn = on_initial;
  vpi_register_cb(&d);
  d.reason = acbConvergenceTest;
  d.cb_rtn = on_converge;
  vpi_register_cb(&d);
  t.type = vpiScaledRealTime;
  t.real = T_SWITCH;
  d.reason = acbAbsTime;
  d.cb_rtn = on_switch;
  d.time = &t;
  vpi_register_cb(&d);
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

static void register_scaled(void)
{
  static char name[] = "$espice_scaled";
  s_vpi_analog_systf_data d = {0};
  s_cb_data cb = {0};
  d.type = vpiAnalogSysFunc;
  d.sysfunctype = vpiRealFunc;
  d.tfname = name;
  d.calltf = scaled_calltf;
  vpi_register_analog_systf(&d);
  cb.reason = cbEndOfCompile;
  cb.cb_rtn = on_compile;
  vpi_register_cb(&cb);
}

void (*vlog_startup_routines[])(void) = { register_gain, register_scaled, 0 };
