#!/bin/sh
# s26_camfeed — Nura side of the camera; runs as "user" inside the chroot (installed to /usr/local/libexec by m81,
# started by m106). PipeWire + WirePlumber for video only (audio stays on PulseAudio), one s26-pwcam (s26_pwcam.c)
# per camera turning s26_camd's NV12 FIFO into a PipeWire camera node, and a watcher that switches the Android
# camera on only while an app is linked to that node.
D=/var/lib/s26cam
L=$HOME/.cache/s26
# sensor-side stream size, shared with m81's s26_camd ("W H" in $D/res; photos come out at this size, portrait)
read W H < $D/res 2>/dev/null || { W=1280; H=720; }

# a previous run's feeders outlive their parent shell: drop them (and their stale camera nodes)
pkill -u user -f "pipewiresink mode=provide"
pkill -u user -x s26-pwcam

# WirePlumber: cameras only -- PulseAudio owns audio, the /dev/video* nodes are Qualcomm codecs, not cameras
mkdir -p $HOME/.config/wireplumber/wireplumber.conf.d
cat > $HOME/.config/wireplumber/wireplumber.conf.d/50-s26.conf <<'EOF'
wireplumber.profiles = {
  main = {
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.bluez = disabled
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
  }
}
EOF
pgrep -u user -x pipewire >/dev/null || { setsid nohup pipewire >$L/pipewire.log 2>&1 & sleep 2; }
pgrep -u user -x wireplumber >/dev/null || { setsid nohup wireplumber >$L/wireplumber.log 2>&1 & sleep 2; }

# name rotation description  (sensors are mounted sideways: s26-pwcam rotates to portrait)
# (GStreamer's pipewiresink mode=provide stalled after ~30 frames under Snapshot -> frozen preview, dead shutter)
feed() {
	echo 0 > $D/$1.want
	while :; do
		/usr/local/bin/s26-pwcam s26-$1 "$3" $2 $D/$1.fifo $W $H >>$L/camfeed-$1.log 2>&1
		sleep 2
	done
}
# back first: apps tend to open the first camera they see
feed back cw "Back camera" &
sleep 1
feed front ccw "Front camera" &

# camera on only while something consumes the node (Snapshot, a browser...)
sleep 3
while :; do
	links=$(pw-link -l 2>/dev/null)
	for c in back front; do
		if echo "$links" | grep -A1 "^s26-$c:" | grep -q -e '|->' -e '->'; then w=1; else w=0; fi
		[ "$(cat $D/$c.want 2>/dev/null)" = $w ] || echo $w > $D/$c.want
	done
	sleep 1
done
