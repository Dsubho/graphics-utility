cp /sys/kernel/debug/dri/0/gt0/uc/guc_log_dump /data/drivers.gpu.tools.sriov-toolkit/tools/guc-debug/$1
sleep 3
/data/johnharr.iLab/Scripts/./decodeGuCLog.pl --py /data/drivers.gpu.tools.sriov-toolkit/tools/guc-debug/$1 --schema=/data/schema__70_53_0.xsd