* Current-controlled switch: W device with ramping control current.
Vin in 0 DC 10
Vctl ctrl 0 PWL(0 0 10m 10 20m 0)
Rctl ctrl sense 1k
Vam sense 0 DC 0
W1 in out Vam csw1
RL out 0 1k
.model csw1 CSW(IT=5m IH=1m RON=1 ROFF=1meg)
.tran 0.1m 20m
.end
