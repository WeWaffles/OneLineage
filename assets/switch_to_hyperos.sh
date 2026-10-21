#!/system/bin/sh
# OneLineage Userspace Takeover Orchestrator
STAGE="/data/local/tmp/hyper_stage"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
RP=$(which resetprop 2>/dev/null || echo "/data/adb/ksu/bin/resetprop")
[ -x "$RP" ] || RP=$(find /data/adb /system -name resetprop 2>/dev/null | head -n 1)

export BB
export RP
export STAGE

set_prop() {
    if [ -n "$RP" ] && [ -x "$RP" ]; then
        "$RP" "$1" "$2" 2>/dev/null || true
    else
        setprop "$1" "$2" 2>/dev/null || true
    fi
}

BACKUP_DIR="/data/local/tmp/hyper_backups"

echo "=== HYPEROS 3 TAKEOVER STARTING ==="

# Put SELinux in permissive mode for the duration of the takeover. The guest
# userspace is a foreign, unlabelled-for-this-policy userspace: its
# system_server runs as u:r:system_server:s0 against Samsung's policy, and MAC
# denials there surface as confusing EACCES/ENOENT deep inside system_server
# (e.g. settings.db "doesn't exist", users/0.xml EACCES). master_prepare.sh
# relabels the staged /data properly, but permissive is the safety net that
# keeps the rest of the guest boot from tripping over labels we cannot predict.
# return_to_oneui.sh restores enforcing.
setenforce 0 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"

# --- CODEC-SPIN LOG MITIGATION (partial) ---------------------------------
# NOT a fix for the overheating, a damage-limiter for it. Root cause (profiled
# with simpleperf, 2026-10): the guest's MediaCodecList resolves the codec-list
# service through the SHARED servicemanager to one of Samsung's mediaserver
# binder nodes whose interface descriptor does not match ("enforceInterface()
# expected 'android.gui.IGraphicBufferProducer' but read
# 'android.media.IMediaCodecList'"). The reply parcels as garbage, the lookup
# never succeeds and never cleanly fails, so system_server + systemui retry it
# thousands of times a second. Measured split: ~1/3 of the CPU was just LOGGING
# that failure (logd pegged ~55%, kernel vsnprintf + Samsung sec_pmsg/pstore,
# liblog) - that part is the "GB of logcat" the README mentions, and it also
# wears the pstore. Silencing those tags before the guest boots cut
# system_server/systemui from ~114%/111% to ~81%/78% and dropped logd off the
# top entirely. The remaining ~75%-per-process spin is the binder retry itself
# and is NOT fixable here - see the "Codec overheating" note in the README for
# the architectural fix (give the guest its own media/codec service instead of
# binding Samsung's).
for t in MediaCodecList AString libbinder.Parcel Parcel ResourcesManager; do
    setprop log.tag.$t SILENT 2>/dev/null || true
done

# --- IMS / SMS REGISTRATION GATE -----------------------------------------
# The guest has no ImsService of its own, so the modem's IMS registration is
# owned by One UI's imsd and survives the takeover. That registration is what
# makes SMS behave: with it, T-Mobile delivers inbound SMS promptly (Samsung's
# RIL hands SMSoIP messages to the framework as normal SMS) and the modem
# accepts mobile-originated SMS. Without it, voice sits OUT_OF_SERVICE, sends
# fail with RESULT_ERROR_NO_SERVICE and inbound codes fall back to the SMSC
# retry schedule, arriving 20-40 minutes late - and every radio nudge then
# appears to "magically" deliver them.
# So: make sure imsd is up, and give the modem a moment to (re)register before
# the pivot. Never stop imsd afterwards; killing it was what degraded SMS.
if ! pidof imsd >/dev/null 2>&1; then
    setprop ctl.start imsd 2>/dev/null || true
fi
ims_i=0
ims_st=1
while [ "$ims_i" -lt 45 ]; do
    if dumpsys telephony.registry 2>/dev/null | grep -q 'mVoiceRegState=0'; then
        ims_st=0
        break
    fi
    ims_i=$((ims_i + 1))
    sleep 2
done
echo "IMS gate: voiceRegState=$ims_st after $((ims_i * 2))s, imsd=${ims_pid:-$(pidof imsd)}"

# --- ADB WATCHDOG ---------------------------------------------------------
# adb is the only way into the phone while Lineage is up (until wifi is
# configured), and the host adbd occasionally dies or loses the adb function
# when the container's system_server touches the USB configuration. init does
# not reliably restart it, which is the "adb randomly stopped working" symptom.
# Keep it supervised from the host namespace for the whole session; the watchdog
# is stopped again by return_to_oneui.sh.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "adb_watchdog.sh"; then
    cat > /data/local/tmp/adb_watchdog.sh <<'ADBW'
#!/system/bin/sh
# Watchdog for the host adbd, which is the only way into the phone while Lineage
# is up. Two failure modes are handled:
#   1. adbd simply died -> ask init to start it again.
#   2. adbd is alive but the USB gadget lost the adb function. The guest's own
#      UsbService rewrites sys.usb.config during boot, and a plain setprop is a
#      no-op in that state, so the gadget has to be re-applied by toggling it.
LOG=/data/local/tmp/adb_watchdog.log
last_toggle=0
while true; do
    sleep 10
    st=$(getprop init.svc.adbd)
    usb=$(getprop sys.usb.state)
    cfg=$(getprop sys.usb.config)
    if [ "$st" != "running" ]; then
        setprop ctl.start adbd 2>/dev/null
        echo "$(date) restarted adbd (was: $st, usb.state=$usb, usb.config=$cfg)" >> "$LOG"
    fi
    case "$cfg" in
        *adb*) ;;
        *)
            setprop sys.usb.config "$cfg,adb" 2>/dev/null
            echo "$(date) added adb to usb.config (was: $cfg)" >> "$LOG"
            ;;
    esac
    case "$usb" in
        *adb*) ;;
        "")
            ;;
        *)
            now=$(date +%s 2>/dev/null || echo 0)
            if [ $((now - last_toggle)) -gt 300 ]; then
                last_toggle=$now
                echo "$(date) gadget lost adb, toggling (state: $usb, config: $cfg)" >> "$LOG"
                setprop sys.usb.config none 2>/dev/null
                sleep 1
                setprop sys.usb.config rndis,adb 2>/dev/null
                sleep 2
                setprop ctl.start adbd 2>/dev/null
            fi
            ;;
    esac
done
ADBW
    chmod 755 /data/local/tmp/adb_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "adbd watchdog started (log: /data/local/tmp/adb_watchdog.log)"
fi

# --- IMS KEEPALIVE --------------------------------------------------------
# imsd is the daemon holding the modem's IMS registration (see the IMS gate
# above). init does not always bring it back if it dies, and a dead imsd means
# SMS quietly degrades to "arrives whenever the SMSC next retries", so keep it
# supervised for the whole Lineage session.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "ims_watchdog.sh"; then
    cat > /data/local/tmp/ims_watchdog.sh <<'IMSW'
#!/system/bin/sh
LOG=/data/local/tmp/ims_watchdog.log
# Only ever (re)start imsd - never poke the radio/APN here. A dead imsd is the
# one failure that silently degrades SMS to "arrives on the SMSC retry", so we
# just make sure the daemon exists. A 20 s poll catches a crash well before the
# next SMSC retry window; init.svc covers the brief window where the process is
# respawning and pidof would miss it.
while true; do
    sleep 20
    if ! pidof imsd >/dev/null 2>&1 && [ "$(getprop init.svc.imsd)" != "running" ]; then
        setprop ctl.start imsd 2>/dev/null
        echo "$(date) restarted imsd (was missing)" >> "$LOG"
    fi
done
IMSW
    chmod 755 /data/local/tmp/ims_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "imsd keepalive started (log: /data/local/tmp/ims_watchdog.log)"
fi

# Set permissive privapp permissions to avoid Signature|privileged fatal exceptions
set_prop ro.control_privapp_permissions log

# --- ONEUI PROTECTION & RESCUEPARTY DISABLE ---
echo "=== [1/6] Protecting OneUI Home Screen and Disabling RescueParty ==="
set_prop persist.sys.disable_rescue true
set_prop sys.rescue_boot_count 0
mkdir -p "$BACKUP_DIR"
if [ -d "/data/user/0/com.sec.android.app.launcher/databases" ]; then
    cp -a /data/user/0/com.sec.android.app.launcher/databases/* "$BACKUP_DIR/" 2>/dev/null || true
    echo "One UI Home databases snapshotted to $BACKUP_DIR"
fi

# --- AUDIO LOW LATENCY TUNING ---
# Deep buffer must stay OFF. Tested live: with audio.deep_buffer.media=true the
# deep-buffer output opens but never consumes, and an AudioTrack write blocks
# forever (app_process hung in futex_wait). The 20 ms normal path is the one
# that actually works; a streamed tone on it is clean (0 underruns, 0 late
# writes). Offload stays off: no working vendor DSP session in the container.
echo "=== [2/6] Configuring Low-Latency Audio ==="
set_prop audio.offload.disable 1
set_prop audio.deep_buffer.media false
set_prop audio.offload.video false
set_prop vendor.audio.offload.track.enable false

# --- NETWORK BPF FIREWALL & DNS BYPASS ---
echo "=== [3/6] Configuring Network BPF Filters ==="
bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_configuration_map key hex 00 00 00 00 value hex 00 00 00 00 2>/dev/null || true
chmod 666 /dev/socket/dnsproxyd 2>/dev/null || true

# --- VERIFY STAGING ENVIRONMENT ---
echo "=== [4/6] Verifying Staging Environment ==="
if [ ! -f "$STAGE/system.raw" ]; then
    echo "ERROR: HyperOS system image ($STAGE/system.raw) not found!"
    echo "Please tap 'Download & Install' in the app first."
    exit 1
fi

# Ensure all scripts and engine binaries exist in $STAGE
mkdir -p "$STAGE/data"
APP_FILES="/data/user/0/com.wewaffles.onehyper/files"
if [ -d "$APP_FILES" ]; then
    cp -f "$APP_FILES"/* "$STAGE/" 2>/dev/null || true
fi
chmod 755 "$STAGE"/*.sh "$STAGE/zygote_exec" 2>/dev/null || true

# --- MOUNT PREPARATION ---
echo "=== [5/6] Executing Mount Hierarchy Preparation ==="
/system/bin/sh "$STAGE/master_prepare.sh"
PREP_RET=$?
if [ $PREP_RET -ne 0 ]; then
    echo "ERROR: master_prepare.sh failed (code $PREP_RET)!"
    exit 1
fi

# --- STOP HOST DAEMONS & LAUNCH CONTAINER ---
echo "=== [6/6] Launching HyperOS Takeover Daemon ==="
pkill -f "while true; do [ \"\$(getprop init.svc.zygote)\"" 2>/dev/null || true
pkill -f "while true; do for p in \\\$(pidof audioserver cameraserver)" 2>/dev/null || true
setprop ctl.stop zygote
setprop ctl.stop surfaceflinger
# audioserver/cameraserver are deliberately left running. The guest shares this
# binder namespace, and its AudioService.<init> -> AudioDeviceBroker.init ->
# AudioSystem::addAudioPortCallback waits on media.audiopolicy with no timeout:
# with no audio policy service registered, system_server's main thread hangs
# (~2 min watchdog stall, boot stuck on the animation). Freezing them with
# kill -STOP is the worst of both worlds - the binder registration survives
# while the process can never answer.
kill -9 $(pidof surfaceflinger) 2>/dev/null || true
kill -9 $(pidof bootanimation) 2>/dev/null || true
kill -9 $(pidof app_process64) 2>/dev/null || true
kill -9 $(pidof zygote_exec) 2>/dev/null || true
kill -9 $(pidof zygote64) 2>/dev/null || true
kill -9 $(pidof system_server) 2>/dev/null || true
sleep 1

# Stop the HOST media codec stack. The guest's libmedia binds `media.codec` from
# the shared servicemanager, i.e. Samsung's mediaserver - whose IMediaCodecList
# AIDL hash differs from the GSI's. The reply parcel is then parsed as garbage
# ("enforceInterface() expected 'android.gui.IGraphicBufferProducer' but read
# 'android.media.IMediaCodecList'", "AString: ctor got NULL"), which yields a
# codec list with a bogus length, so findCodecForFormat -> codecHandlesFormat
# spins ~2M times inside both system_server and SystemUI, round-tripping to
# mediaserver each iteration. That is the 125% CPU / constant overheating / GB
# of logcat. With no media.codec registered the lookup fails fast and the list
# is empty. Audio is unaffected (audioserver is its own process and is kept).
# mediaserver must stay UP even though the codec list is unusable: apps play
# short sounds with MediaPlayer, and MediaPlayer.setDataSource blocks in
# IMediaDeathNotifier::getMediaPlayerService when "media.player" is missing.
# That is a 5 s main-thread stall -> ANR -> force-close: Messaging died on every
# send because of its "sent" sound (playSentSound), and any app doing the same
# would die too. Keep only the codec processes down, which is what causes the
# spin described above.
setprop ctl.start media 2>/dev/null || true
for svc in media.codec media.metrics; do
    setprop ctl.stop $svc 2>/dev/null || true
done
kill -9 $(pidof media.codec) $(pidof media.metrics) 2>/dev/null || true

# Same handover for wifi. The guest's WifiService binds IWificond (service
# "wifinl80211") and drives the vendor HAL through it. Samsung's wificond is
# still holding the client interface that One UI's (now dead) WifiService
# created, so every startScan() comes back "status: -1" and the framework sees
# "No scan results" - wifi looks broken but only the scanner is wedged. The
# GSI's own wificond starts in master_inner.sh and scans fine against the same
# vendor HAL.
setprop ctl.stop wificond 2>/dev/null || true
kill -9 $(pidof wificond) 2>/dev/null || true
sleep 1

# Suppress the host zygote only, so Samsung init does not resurrect it
nohup $BB sh -c "while true; do [ \"\$(getprop init.svc.zygote)\" = \"running\" ] && setprop ctl.stop zygote; sleep 1; done" </dev/null >/dev/null 2>&1 &

# Copy inner script and zygote_exec into container data partition
cp -f "$STAGE/master_inner.sh" "$STAGE/data/master_inner.sh"
chmod 755 "$STAGE/data/master_inner.sh"
cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
chmod 755 "$STAGE/data/zygote_exec"

# Launch takeover inside isolated mount namespace
$BB unshare -m $BB sh "$STAGE/data/master_inner.sh" </dev/null >"$STAGE/data/takeover.log" 2>&1 &
TAKEOVER_PID=$!
echo "Takeover daemon PID: $TAKEOVER_PID"

# Start UI Activator daemon
$BB sh -c "
BB=\"$BB\"
[ -n \"\$BB\" ] || BB=\$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
while true; do
    sleep 2
    PID=\$(pidof system_server | awk '{print \$1}')
    if [ -n \"\$PID\" ]; then
        if $BB nsenter -t \$PID -m /system/bin/dumpsys window 2>/dev/null | grep -q 'mStatusBar'; then
            echo '[UI Activator] WindowManager is ready! Dismissing bootanim and unlocking...'
            setprop service.bootanim.exit 1
            kill -9 \$(pidof bootanimation) 2>/dev/null
            sleep 1
            $BB nsenter -t \$PID -m /system/bin/svc power stayon true
            $BB nsenter -t \$PID -m /system/bin/settings put global stay_on_while_plugged_in 7
            $BB nsenter -t \$PID -m /system/bin/settings put system screen_off_timeout 2147483647
            $BB nsenter -t \$PID -m /system/bin/settings put system haptic_feedback_enabled 1
            $BB nsenter -t \$PID -m /system/bin/settings put system peak_refresh_rate 120.0
            $BB nsenter -t \$PID -m /system/bin/settings put system min_refresh_rate 120.0
            # Gesture navigation. The GSI boots with the three-button overlay, and
            # this line used to force it back on every takeover.
            $BB nsenter -t \$PID -m /system/bin/cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/settings put secure navigation_mode 2 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/pm disable android.ext.services/android.ext.services.notification.Assistant 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/input keyevent 224
            $BB nsenter -t \$PID -m /system/bin/input keyevent 82
            $BB nsenter -t \$PID -m /system/bin/am unlock-user 0
            $BB nsenter -t \$PID -m /system/bin/am start -a android.intent.action.MAIN -c android.intent.category.HOME
            echo '[UI Activator] Home activated!'
            echo '[UI Activator] Creating missing app data dirs...'
            $BB nsenter -t \$PID -m /system/bin/sh /data/local/tmp/fix_app_dirs.sh 2>/dev/null || true

            # Install microG if requested
            if [ -f \"\$STAGE/install_microg.flag\" ]; then
                echo '[UI Activator] Installing microG components...'
                for apk in \"\$STAGE/GmsCore.apk\" \"\$STAGE/FakeStore.apk\" /data/local/tmp/GmsCore.apk /data/local/tmp/FakeStore.apk; do
                    if [ -f \"\$apk\" ]; then
                        echo \"[UI Activator] Installing \$apk...\"
                        \$BB nsenter -t \$PID -m /system/bin/pm install -r -g \"\$apk\" 2>/dev/null || true
                    fi
                done
                rm -f \"\$STAGE/install_microg.flag\" 2>/dev/null || true
            fi

            # Populate network permissions for all installed packages
            for uid in \$($BB nsenter -t \$PID -m /system/bin/pm list packages -U 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | sort -u); do
                [ -n \"\$uid\" ] || continue
                b0=\$(printf \"%02x\" \$((uid & 0xff)))
                b1=\$(printf \"%02x\" \$(((uid >> 8) & 0xff)))
                b2=\$(printf \"%02x\" \$(((uid >> 16) & 0xff)))
                b3=\$(printf \"%02x\" \$(((uid >> 24) & 0xff)))
                bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_uid_permission_map key hex \$b0 \$b1 \$b2 \$b3 value hex 0c 2>/dev/null || true
            done

            # Ensure default routing
            DEF_IF=\$(ip route | grep -o 'dev [^ ]*' | head -n 1 | awk '{print \$2}')
            [ -n \"\$DEF_IF\" ] && ip route add default dev \"\$DEF_IF\" 2>/dev/null || true

            # Mount emulated primary storage
            $BB nsenter -t \$PID -m /system/bin/sm mount \"emulated;0\" 2>/dev/null || true
            break
        fi
    fi
done
" </dev/null >/data/local/tmp/ui_activator.log 2>&1 &

echo "=== TAKEOVER LAUNCHED SUCCESSFULLY ==="
