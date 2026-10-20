#!/bin/sh
# gpu_matrix.sh ESPICE PM: the E1 device-kernel rows that were measured.
cd "$(dirname "$0")"
for c in "1024 lane coherent" "1024 lane mixed" "1024 lane distinct" "1024 point mixed" "1024 shuffle mixed" \
         "4096 lane coherent" "4096 lane mixed" "4096 shuffle mixed"; do
  ./run.sh "$1" "$2" $c "100p uic" cuda
done
for B in 32 128 256; do ESPICE_GPU_BLOCK=$B ./run.sh "$1" "$2" 1024 lane coherent "100p uic" cuda; done
