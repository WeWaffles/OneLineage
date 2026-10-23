#!/bin/sh
# m106_user_session.sh — user half of the Phosh session; runs INSIDE the chroot as "user"
# (installed to /usr/local/libexec/s26-user-session by m81, started with su from the root half)
export HOME=/home/user USER=user LOGNAME=user
export XDG_RUNTIME_DIR=/run/user/1000
export XDG_CURRENT_DESKTOP=Phosh:GNOME XDG_SESSION_DESKTOP=phosh XDG_SESSION_TYPE=wayland GDK_BACKEND=wayland
# no user namespaces in the Android kernel -> WebKit (Epiphany) bwrap sandbox can't start
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
# GPU: Adreno 840 sits behind Android's kgsl, not DRM -> lfdevs Mesa (m109_mesa.sh) with the kgsl gallium driver.
# /etc/s26-gpu: "gpu" (default, apps on GL), "vulkan" (apps on turnip Vulkan), "compositor" (phoc on GPU,
# apps draw on CPU), or "cpu" (pixman + cairo). GL apps flicker (no implicit sync on kgsl buffers?) — testing.
case "$(cat /etc/s26-gpu 2>/dev/null)" in
  vulkan)     export WLR_RENDERER=gles2 MESA_LOADER_DRIVER_OVERRIDE=kgsl GSK_RENDERER=vulkan ;;
  cpu)        export WLR_RENDERER=pixman GSK_RENDERER=cairo ;;
  compositor) export WLR_RENDERER=gles2 MESA_LOADER_DRIVER_OVERRIDE=kgsl GSK_RENDERER=cairo ;;
  *)          export WLR_RENDERER=gles2 MESA_LOADER_DRIVER_OVERRIDE=kgsl GSK_RENDERER=gl ;;
esac
# kgsl buffers have no implicit-sync fences -> KMS showed half-drawn frames (flickering chunks).
# s26_glfinish.so makes glFlush wait for the GPU (m136_build_glfinish.sh). Inherited by phosh + its apps.
[ "$WLR_RENDERER" = gles2 ] && [ -f /usr/local/lib/s26_glfinish.so ] && export LD_PRELOAD=/usr/local/lib/s26_glfinish.so
# Flathub apps (m142..m150): their .desktop files/icons live under the flatpak exports
export XDG_DATA_DIRS=$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share
# ...and draw on the Adreno: GL.kgsl extension = lfdevs' glibc Mesa (m157/m159), overrides in m160
[ "$WLR_RENDERER" = gles2 ] && export FLATPAK_GL_DRIVERS=kgsl
L=$HOME/.cache/s26; mkdir -p $L
cd $HOME

dbus-daemon --session --fork --address=unix:path=$XDG_RUNTIME_DIR/bus
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
gsettings set sm.puri.phosh.lockscreen require-unlock false 2>/dev/null
# Flathub apps rarely carry Phosh's "mobile" hints -> the adaptive filter hid them from the app grid
gsettings set sm.puri.phosh app-filter-mode "[]" 2>/dev/null
PHOSH=$(ls /usr/libexec/phosh /usr/bin/phosh 2>/dev/null | head -n 1)
# phoc does not hand WAYLAND_DISPLAY to phosh here -> apps launched by phosh had no display; pin it
# (wayland-* sockets were wiped by the root half, so phoc gets wayland-0)
setsid nohup phoc -C /etc/phosh/phoc.ini -E "env WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland $PHOSH" >$L/phoc.log 2>&1 &
sleep 8
export WAYLAND_DISPLAY=wayland-0
# DBusActivatable apps are spawned by dbus-daemon, which needs the display too
dbus-update-activation-environment WAYLAND_DISPLAY GDK_BACKEND XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS GSK_RENDERER MESA_LOADER_DRIVER_OVERRIDE XDG_DATA_DIRS FLATPAK_GL_DRIVERS
setsid nohup squeekboard >$L/squeek.log 2>&1 &
# audio: the ALSA card here is the AGM/DSP front end (silent without Android's routing) -> play through Android
# instead: pipe sink into the FIFO that m81's s26_audiobridge feeds to AAudio. Volume keys drive this sink via Phosh.
pulseaudio --check || pulseaudio --start
pactl load-module module-pipe-sink file=/var/lib/s26audio/fifo format=s16le rate=48000 channels=2 sink_name=s26 sink_properties=device.description=Speaker >/dev/null
pactl set-default-sink s26
# volume keys: Phosh hands XF86AudioRaise/LowerVolume to gsd-media-keys, which gnome-session would normally start
setsid nohup /usr/libexec/gsd-media-keys >$L/gsd-media-keys.log 2>&1 &
# PipeWire's RT module (in every client: Snapshot, browsers...) gets no limits from rtkit (not running) and leaves
# RLIMIT_RTTIME at 0 -> the kernel SIGKILLs the app as soon as any of its threads runs real-time (Snapshot died on
# taking a photo). No RT needed here: turn the module off for clients and the daemon.
for c in client client-rt pipewire; do
	mkdir -p $HOME/.config/pipewire/$c.conf.d
	printf 'context.properties = {\n  module.rt = false\n}\n' > $HOME/.config/pipewire/$c.conf.d/50-s26-no-rt.conf
done
# camera: PipeWire camera nodes fed from Android's camera (m81 runs s26_camd for each)
[ -x /usr/local/libexec/s26-camfeed ] && setsid nohup /usr/local/libexec/s26-camfeed >$L/camfeed.log 2>&1 < /dev/null &
# first login only: Initial Setup + Phosh tour (m138_onboard_install.sh)
[ -x /usr/local/libexec/s26-firstrun ] && setsid nohup /usr/local/libexec/s26-firstrun >/dev/null 2>&1 &
sleep 6
for p in phoc phosh squeekboard; do echo "$p: $(pgrep -u user -l $p | head -n 1)"; done
tail -n 8 $L/phoc.log
