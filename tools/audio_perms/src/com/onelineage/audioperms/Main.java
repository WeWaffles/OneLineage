package com.onelineage.audioperms;

import android.content.pm.ApplicationInfo;
import android.os.IBinder;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Gives the host audioserver Lineage's app list and audio permission holders.
 *
 * Since Android 16, audioserver checks app ops and permissions against lists
 * that system_server pushes to it (INativePermissionController). The host
 * audioserver was started by One UI and kept One UI's lists for the whole
 * session, so an app's uid mapped to whatever One UI app had that uid. Discord's
 * uid was Samsung Keyboard's in One UI: the mic app-op check ran for the wrong
 * package, failed, and audioserver silenced Discord's microphone.
 *
 * Lineage's AudioService does push its lists, but audioserver only accepts
 * getPermissionController() from system_server's uid, and through ol_bridge
 * every guest call arrives as root, so it is refused. Hence two steps:
 *
 *   dump <file>  inside the guest (as root): read Lineage's package manager.
 *   push <file>  on the host as uid 1000 (system): send the lists.
 *
 * Run with app_process. Hidden framework classes are used through reflection.
 */
public final class Main {
    // com.android.media.permission.PermissionEnum order (Android 16).
    private static final String[] PERMS = {
        "android.permission.RECORD_AUDIO",
        "android.permission.MODIFY_AUDIO_ROUTING",
        "android.permission.MODIFY_AUDIO_SETTINGS",
        "android.permission.MODIFY_PHONE_STATE",
        "android.permission.MODIFY_DEFAULT_AUDIO_EFFECTS",
        "android.permission.WRITE_SECURE_SETTINGS",
        "android.permission.CALL_AUDIO_INTERCEPTION",
        "android.permission.ACCESS_ULTRASOUND",
        "android.permission.CAPTURE_AUDIO_OUTPUT",
        "android.permission.CAPTURE_MEDIA_OUTPUT",
        "android.permission.CAPTURE_AUDIO_HOTWORD",
        "android.permission.CAPTURE_TUNER_AUDIO_INPUT",
        "android.permission.CAPTURE_VOICE_COMMUNICATION_OUTPUT",
        "android.permission.BLUETOOTH_CONNECT",
        "android.permission.BYPASS_CONCURRENT_RECORD_AUDIO_RESTRICTION",
        "android.permission.MODIFY_AUDIO_SETTINGS_PRIVILEGED",
    };

    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("dump")) {
            dump(new File(args[1]));
        } else if (args.length == 2 && args[0].equals("push")) {
            push(new File(args[1]));
        } else {
            System.err.println("usage: dump <file> | push <file>");
            System.exit(2);
        }
    }

    private static Object service(String name, String stub) throws Exception {
        IBinder b = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, name);
        if (b == null) throw new IllegalStateException(name + " not found");
        return Class.forName(stub).getMethod("asInterface", IBinder.class).invoke(null, b);
    }

    /** Lines: "P appId targetSdk captureAllowed package" and "G permIndex appId". */
    private static void dump(File out) throws Exception {
        Object pm = service("package", "android.content.pm.IPackageManager$Stub");
        Object slice = pm.getClass().getMethod("getInstalledApplications", long.class, int.class)
                .invoke(pm, 0x00402000L /* MATCH_UNINSTALLED_PACKAGES | MATCH_DISABLED */, 0);
        @SuppressWarnings("unchecked")
        List<ApplicationInfo> apps = (List<ApplicationInfo>) slice.getClass()
                .getMethod("getList").invoke(slice);
        Method captureAllowed = ApplicationInfo.class.getMethod("isAudioPlaybackCaptureAllowed");
        Method check = pm.getClass().getMethod("checkUidPermission", String.class, int.class);

        TreeMap<Integer, Boolean> appIds = new TreeMap<>();
        File tmp = new File(out.getPath() + ".tmp");
        try (PrintWriter w = new PrintWriter(new FileWriter(tmp))) {
            for (ApplicationInfo ai : apps) {
                int appId = ai.uid % 100000;
                appIds.put(appId, true);
                w.println("P " + appId + " " + ai.targetSdkVersion + " "
                        + ((boolean) captureAllowed.invoke(ai) ? 1 : 0) + " " + ai.packageName);
            }
            for (int i = 0; i < PERMS.length; i++) {
                for (int appId : appIds.keySet()) {
                    if ((int) check.invoke(pm, PERMS[i], appId) == 0) w.println("G " + i + " " + appId);
                }
            }
        }
        if (!tmp.renameTo(out)) throw new IllegalStateException("rename failed");
        System.out.println("audio_perms: dumped " + apps.size() + " packages");
    }

    private static void push(File in) throws Exception {
        Class<?> upsCls = Class.forName("com.android.media.permission.UidPackageState");
        Class<?> psCls = Class.forName("com.android.media.permission.UidPackageState$PackageState");
        Field upsUid = upsCls.getField("uid");
        Field upsStates = upsCls.getField("packageStates");
        Field psName = psCls.getField("packageName");
        Field psSdk = psCls.getField("targetSdk");
        Field psCapture = psCls.getField("isPlaybackCaptureAllowed");

        Map<Integer, List<Object>> byAppId = new TreeMap<>();
        List<List<Integer>> grants = new ArrayList<>();
        for (int i = 0; i < PERMS.length; i++) grants.add(new ArrayList<Integer>());
        try (BufferedReader r = new BufferedReader(new FileReader(in))) {
            String line;
            while ((line = r.readLine()) != null) {
                String[] f = line.split(" ");
                if (f.length == 5 && f[0].equals("P")) {
                    int appId = Integer.parseInt(f[1]);
                    Object ps = psCls.newInstance();
                    psSdk.setInt(ps, Integer.parseInt(f[2]));
                    psCapture.setBoolean(ps, f[3].equals("1"));
                    psName.set(ps, f[4]);
                    List<Object> l = byAppId.get(appId);
                    if (l == null) byAppId.put(appId, l = new ArrayList<>());
                    l.add(ps);
                } else if (f.length == 3 && f[0].equals("G")) {
                    int perm = Integer.parseInt(f[1]);
                    if (perm >= 0 && perm < PERMS.length) grants.get(perm).add(Integer.parseInt(f[2]));
                }
            }
        }
        if (byAppId.isEmpty()) throw new IllegalStateException("no packages in " + in);

        List<Object> states = new ArrayList<>();
        for (Map.Entry<Integer, List<Object>> e : byAppId.entrySet()) {
            Object ups = upsCls.newInstance();
            upsUid.setInt(ups, e.getKey());
            upsStates.set(ups, e.getValue());
            states.add(ups);
        }

        Object ap = service("media.audio_policy", "android.media.IAudioPolicyService$Stub");
        Object pc = ap.getClass().getMethod("getPermissionController").invoke(ap);
        if (pc == null) throw new IllegalStateException("no permission controller");
        pc.getClass().getMethod("populatePackagesForUids", List.class).invoke(pc, states);
        Method populatePerm = pc.getClass()
                .getMethod("populatePermissionState", byte.class, int[].class);
        int held = 0;
        for (int i = 0; i < PERMS.length; i++) {
            List<Integer> g = grants.get(i);
            int[] arr = new int[g.size()];
            for (int j = 0; j < arr.length; j++) arr[j] = g.get(j);
            java.util.Arrays.sort(arr);
            populatePerm.invoke(pc, (byte) i, arr);
            held += arr.length;
        }
        System.out.println("audio_perms: sent " + states.size() + " app ids, " + held + " grants");
    }
}
