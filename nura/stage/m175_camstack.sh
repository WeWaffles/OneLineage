#!/system/bin/sh
# m175_camstack.sh — camera while Nura runs: graphics allocator + stand-ins for system_server's "activity" and
# "media.camera.proxy" (s26_fakeam) + cameraserver. Called by m81; m77 stops the stand-ins before Android returns.
S=/data/local/tmp/nura_stage
kill $(pidof s26_fakeam) 2>/dev/null; sleep 1
setprop ctl.start vendor.qti.hardware.display.allocator
cd $S
setsid nohup ./s26_fakeam > fakeam.log 2>&1 < /dev/null &
setsid nohup ./s26_fakeam media.camera.proxy android.hardware.ICameraServiceProxy zero > fakeproxy.log 2>&1 < /dev/null &
# Samsung's cameraserver also asks system_server's camera worker on every connect
setsid nohup ./s26_fakeam media.camera.worker com.samsung.android.camera.ICameraServiceWorker zero > fakeworker.log 2>&1 < /dev/null &
# permission checks (camera access) go to system_server's "permission" service: grant everything to native callers
setsid nohup ./s26_fakeam permission android.os.IPermissionController perm > fakeperm.log 2>&1 < /dev/null &
# ...and CameraService's own checks use permission_checker, where 0 = PERMISSION_GRANTED
setsid nohup ./s26_fakeam permission_checker android.permission.IPermissionChecker zero > fakepchk.log 2>&1 < /dev/null &
# camera privacy toggle: every query answers "off"
setsid nohup ./s26_fakeam sensor_privacy android.hardware.ISensorPrivacyManager zero > fakesp.log 2>&1 < /dev/null &
# process priorities for CameraService's client eviction
setsid nohup ./s26_fakeam processinfo android.os.IProcessInfoService procinfo > fakepi.log 2>&1 < /dev/null &
# camera output streams ask surfaceflinger for display timing (preview vsync spacing): refuse, they fall back
setsid nohup ./s26_fakeam SurfaceFlingerAIDL android.gui.ISurfaceComposer fail > fakesf.log 2>&1 < /dev/null &
# Samsung's camera HAL wants system_server's sensor service (gyro for stabilisation): empty sensor list
setsid nohup ./s26_fakeam android.frameworks.sensorservice.ISensorManager/default android.frameworks.sensorservice.ISensorManager zero > fakesm.log 2>&1 < /dev/null &
sleep 1
cat fakeam.log fakeproxy.log fakeworker.log fakeperm.log
setprop ctl.restart cameraserver
