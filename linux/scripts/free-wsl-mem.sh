#!/bin/bash
echo "Freeing WSL2 memory..."
echo 1 | tee /proc/sys/vm/drop_caches
echo 1 | tee /sys/kernel/mm/ksm/run
sleep 2
echo 0 | tee /sys/kernel/mm/ksm/run
echo "Done."
