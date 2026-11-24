#!/data/data/com.termux/files/usr/bin/sh
# Start the detection Alertmanager unless it runs (idempotent): Termux:Boot and a JobScheduler job every 15 min call
# this (infrastructure-live ansible role detection_alerting). Listens on 127.0.0.1 only; no clustering (Android
# forbids the netlink address lookup memberlist needs, and there is one instance).
cd "$(dirname "$0")" || exit 1
if [ -f alertmanager.pid ] && kill -0 "$(cat alertmanager.pid)" 2>/dev/null; then exit 0; fi
termux-wake-lock 2>/dev/null
GOMEMLIMIT=48MiB nohup ./alertmanager --config.file=alertmanager.yml --storage.path=data \
  --web.listen-address=127.0.0.1:${AM_PORT:-9093} --cluster.listen-address= --data.retention=720h \
  --log.level=warn >> alertmanager.log 2>&1 &
echo $! > alertmanager.pid
echo "$(date '+%F %T') started pid $!" >> starts.log
