.control
foreach r_val 500 1000 2000
  alter r1 resistance={r_val}
  tran 1n 200n
  meas tran rise_time TRIG v(out) val=0.1 rise=1 TARG v(out) val=0.9 rise=1
  echo R={r_val} rise_time={rise_time}
  wrdata /tmp/pisim_ctrl_test_{r_val}.csv v(out)
.endc
