import android.os.*;
import java.io.*;
import java.lang.reflect.Method;

/**
 * Stands in for One UI's "edmnativehelper" while the guest runs.
 *
 * One UI's cameraserver is shared with the guest (oneos_switch.sh leaves it
 * running) and asks Knox on every camera open:
 * EDMNativeHelper::isCameraEnabled() does getService("edmnativehelper").
 * That name is registered only by One UI's system_server, which the switch
 * stops, so the lookup blocks for libbinder's full 5 s ("Waiting for service
 * 'edmnativehelper'" then "didn't start") while CameraX gives up at 3 s: the
 * first camera open fails (Z Flip5 and S25 reports, both images; the HAL does
 * open afterwards, which is why a retry sometimes works).
 *
 * One UI's own wrapper returns "allowed" when the service is absent, so this is
 * latency, not policy. Registering any binder under the name makes the lookup
 * immediate. The wrapper uses the reply directly, though, so a wrong answer
 * would DISABLE the camera: One UI's onTransact writes a single plain int32 and
 * no exception header, so every code is answered with int32 1 ("enabled",
 * "allowed"). No transaction numbers are needed or assumed.
 *
 * Runs as uid system through app_process, like OneOSAngleRelay, and exits with
 * the guest. Off unless ONEOS_GUEST_EDM_STUB=1.
 */
public final class OneOSEdmStub {
 private static final String NAME = "edmnativehelper";
 private static final String DESCRIPTOR = "mdm.edmnativehelperservice";

 public static void main(String[] args) throws Exception {
  final int guest = Integer.parseInt(args[0]);
  // args[1] overrides the name, so the mechanism can be proved under a harmless
  // one instead of registering over One UI's live Knox service.
  final String name = args.length > 1 ? args[1] : NAME;
  Looper.prepareMainLooper();
  Binder b = new Binder() {
   @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
     throws RemoteException {
    if (code == INTERFACE_TRANSACTION) { if (reply != null) reply.writeString(DESCRIPTOR); return true; }
    // Every Knox query here is a boolean "is this allowed": answer yes, in the
    // shape One UI's own service replies in (one int32, no exception header).
    if (reply != null) reply.writeInt(1);
    return true;
   }
  };
  Class<?> sm = Class.forName("android.os.ServiceManager");
  Method add = sm.getMethod("addService", String.class, IBinder.class, boolean.class, int.class);
  // allowIsolated=false, dumpPriority NORMAL(1): the same call system_server makes.
  add.invoke(null, name, b, Boolean.FALSE, Integer.valueOf(1));
  Object got = sm.getMethod("checkService", String.class).invoke(null, name);
  if (got == null) throw new IllegalStateException("addService " + name + " did not take");
  System.out.println("READY " + name + " uid=" + android.os.Process.myUid() + " guest=" + guest);
  System.out.flush();
  final Handler h = new Handler(Looper.myLooper());
  h.postDelayed(new Runnable() { public void run() {
   if (!new File("/proc/" + guest).exists()) System.exit(0);
   h.postDelayed(this, 2000);
  } }, 2000);
  Looper.loop();
 }
}
