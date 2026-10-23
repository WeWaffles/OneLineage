#!/system/bin/sh
# m99_run81.sh — start the Phosh session detached so an adb drop during takeover can't kill it
S=/data/local/tmp/nura_stage
setsid nohup sh $S/m81_phosh_session.sh > $S/m81.log 2>&1 < /dev/null &
echo "started; read $S/m81.log (m90b_peek.sh)"
