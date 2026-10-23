// S26RilSim — one-shot SIM tool over rild's IRadioSim (no com.android.phone needed). For the IMS client:
//   CLASSPATH=s26_rildata.dex app_process / S26RilSim card              # SIM applications (type, state, AID)
//   CLASSPATH=s26_rildata.dex app_process / S26RilSim aka <RAND> <AUTN> # 3G AKA on the USIM (hex in)
// aka prints one line:  AKA sw=9000 res=<hex> ck=<hex> ik=<hex>   (success, tag DB)
//                       AKA sw=9000 auts=<hex>                     (sync failure, tag DC)
//                       AKA sw=9862 ...                            (MAC failure: AUTN not from our network)
// The answer carries live keys: callers must not log it.
import android.hardware.radio.RadioResponseInfo;
import android.hardware.radio.sim.*;
import android.os.IBinder;

import java.util.Base64;

class S26RilSim {
    static final String SERVICE = "android.hardware.radio.sim.IRadioSim/slot1";
    static final int APPTYPE_USIM = 2;
    static final int AUTH_CONTEXT_EAP_AKA = 129;   // 3G security context (TS 31.102 AUTHENTICATE P2=0x81)

    static IRadioSim sim;
    static final Object lock = new Object();
    static CardStatus card;
    static IccIoResult authResult;
    static int authError = -1;

    static String hex(byte[] b, int off, int len) {
        StringBuilder s = new StringBuilder();
        for (int i = off; i < off + len; i++) s.append(String.format("%02x", b[i] & 0xff));
        return s.toString();
    }

    static byte[] unhex(String h) {
        byte[] b = new byte[h.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    // rild hands simResponse back as base64 (AOSP) or hex (some vendors): accept both
    static byte[] decode(String s) {
        if (s == null || s.isEmpty()) return new byte[0];
        if (s.matches("[0-9a-fA-F]+") && s.length() % 2 == 0) return unhex(s);
        return Base64.getDecoder().decode(s);
    }

    static void await(long ms) throws InterruptedException {
        synchronized (lock) { lock.wait(ms); }
    }

    static String usimAid() throws Exception {
        sim.getIccCardStatus(1);
        await(5000);
        if (card == null || card.applications == null) return null;
        for (AppStatus a : card.applications) if (a.appType == APPTYPE_USIM) return a.aidPtr;
        return null;
    }

    public static void main(String[] args) throws Exception {
        S26Ril.verbose = false;
        IBinder b = S26Ril.service(SERVICE);
        if (b == null) { System.out.println("no " + SERVICE); System.exit(1); }
        sim = IRadioSim.Stub.asInterface(b);
        S26Ril.acks.put("IRadioSim", () -> { try { sim.responseAcknowledgement(); } catch (Exception e) {} });
        S26Ril.handlers.put("IRadioSim", (name, info, a) -> {
            if (name.equals("getIccCardStatusResponse")) card = (CardStatus) a[0];
            if (name.equals("requestIccSimAuthenticationResponse")) { authError = info.error; authResult = (IccIoResult) a[0]; }
            synchronized (lock) { lock.notifyAll(); }
        });
        sim.setResponseFunctions(new IRadioSimCallbacks.Response(), new IRadioSimCallbacks.Indication());

        String cmd = args.length > 0 ? args[0] : "card";
        if (cmd.equals("card")) {
            usimAid();
            if (card == null) { System.out.println("no card status"); System.exit(1); }
            System.out.println("cardState=" + card.cardState + " gsmUmtsApp=" + card.gsmUmtsSubscriptionAppIndex + " imsApp=" + card.imsSubscriptionAppIndex);
            if (card.applications != null) for (AppStatus a : card.applications)
                System.out.println("app type=" + a.appType + " state=" + a.appState + " aid=" + a.aidPtr + " label=" + a.appLabelPtr);
        } else if (cmd.equals("aka") && args.length == 3) {
            String aid = usimAid();
            if (aid == null) { System.out.println("AKA error=no-usim"); System.exit(1); }
            byte[] rand = unhex(args[1]), autn = unhex(args[2]);
            byte[] req = new byte[2 + rand.length + autn.length];
            req[0] = (byte) rand.length; System.arraycopy(rand, 0, req, 1, rand.length);
            req[1 + rand.length] = (byte) autn.length; System.arraycopy(autn, 0, req, 2 + rand.length, autn.length);
            sim.requestIccSimAuthentication(2, AUTH_CONTEXT_EAP_AKA, Base64.getEncoder().encodeToString(req), aid);
            await(10000);
            if (authResult == null) { System.out.println("AKA error=" + (authError >= 0 ? authError : "timeout")); System.exit(1); }
            String sw = String.format("%02x%02x", authResult.sw1, authResult.sw2);
            byte[] r = decode(authResult.simResponse);
            if (authError != 0 || r.length == 0) {
                System.out.println("AKA sw=" + sw + " error=" + authError);
            } else if ((r[0] & 0xff) == 0xdb) {          // RES, CK, IK as length-prefixed fields
                int p = 1;
                int lr = r[p++] & 0xff; String res = hex(r, p, lr); p += lr;
                int lc = r[p++] & 0xff; String ck = hex(r, p, lc); p += lc;
                int li = r[p++] & 0xff; String ik = hex(r, p, li);
                System.out.println("AKA sw=" + sw + " res=" + res + " ck=" + ck + " ik=" + ik);
            } else if ((r[0] & 0xff) == 0xdc) {          // sync failure: AUTS for resync
                System.out.println("AKA sw=" + sw + " auts=" + hex(r, 2, r[1] & 0xff));
            } else {
                System.out.println("AKA sw=" + sw + " raw=" + hex(r, 0, r.length));
            }
        } else {
            System.out.println("usage: S26RilSim card | aka <RAND hex> <AUTN hex>");
            System.exit(2);
        }
        System.exit(0);
    }
}
