#!/data/data/com.termux/files/usr/bin/sh
# Start the watcher unless it runs (idempotent): Termux:Boot (~/.termux/boot/30-gitops-watch) and a JobScheduler job
# every 15 min call this — Android kills background processes; this brings it back.
cd "$(dirname "$0")" || exit 1
if [ -f watch.pid ] && kill -0 "$(cat watch.pid)" 2>/dev/null; then exit 0; fi
termux-wake-lock 2>/dev/null
nohup python -u watch.py config.json >> watch.log 2>&1 &
echo $! > watch.pid
echo "$(date '+%F %T') started pid $!" >> starts.log
