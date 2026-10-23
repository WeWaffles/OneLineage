// S26RilData — rild's data client in place of com.android.phone, so Nura gets mobile data while the
// Android framework is stopped (camera/audio stand-ins keep working). Run with app_process (no zygote
// needed); it uses the device's own radio AIDL classes from the boot classpath.
//   CLASSPATH=s26_rildata.dex app_process / S26RilData up [apn...]  # keep these calls up, stay alive
//   ... S26RilData list                                              # print rild's current calls, exit
// Default APNs: fast.t-mobile.com (internet). "ims" gets the IMS profile (One UI's: profile 2, IPV6).
// rild drops every call when its client dies, so `up` must keep running for the whole session.
// Each call state is printed as one line and written to $STATE for the network script:
//   CALL apn=fast.t-mobile.com cid=1 active=2 ifname=rmnet_data0 addrs=a/64,b/27 gws=... dns=... pcscf=... mtu=1436
import android.hardware.radio.RadioResponseInfo;
import android.hardware.radio.data.*;
import android.os.IBinder;

import java.io.FileWriter;
import java.util.ArrayList;
import java.util.List;

public class S26RilData {
    static final String SERVICE = "android.hardware.radio.data.IRadioData/slot1";
    static final String STATE = "/data/local/tmp/nura_stage/rildata.state";
    // AOSP enum values (radio AIDL)
    static final int ACCESS_NETWORK_NGRAN = 6;
    static final int REASON_NORMAL = 1;
    static final int PDP_IPV6 = 1;
    static final int PDP_IPV4V6 = 2;
    static final int APN_DEFAULT_SUPL_MMS_XCAP = 1 | 2 | 4 | 2048;
    static final int APN_IMS = 64;
    static final int RESPONSE_SOLICITED_ACK_EXP = 2;
    static final int INDICATION_UNSOLICITED_ACK_EXP = 1;
    static final long RETRY_MS = 10000;

    // One call we want kept up. Right after rild restarts the modem's data side isn't ready and setup
    // fails (cause -7), and the network can drop a call later: the main loop (re)sends setupDataCall.
    static class Want {
        final String apn;
        final DataProfileInfo profile;
        volatile boolean needSetup = true;
        volatile long nextSetupAt;
        volatile int pendingSerial = -1;    // a setupDataCall is in flight: list updates don't retry
        volatile int cid = -1;              // rild's id for our call, once it's up
        Want(String apn) { this.apn = apn; profile = apn.equals("ims") ? imsProfile() : internetProfile(apn); }
        void retryLater(long ms) { cid = -1; nextSetupAt = System.currentTimeMillis() + ms; needSetup = true; }
    }

    static IRadioData data;
    static final Object lock = new Object();
    static boolean listOnly;
    static int serial = 10;
    static final List<Want> wants = new ArrayList<>();

    static void log(String s) { System.out.println(s); System.out.flush(); }

    static String join(String[] a) {
        if (a == null) return "";
        StringBuilder b = new StringBuilder();
        for (String s : a) { if (s == null || s.isEmpty() || s.startsWith("0.0.0.0")) continue; if (b.length() > 0) b.append(','); b.append(s.replace("/", "")); }
        return b.toString();
    }

    static Want byCid(int cid) {
        for (Want w : wants) if (w.cid == cid) return w;
        return null;
    }

    static String describe(SetupDataCallResult r) {
        StringBuilder a = new StringBuilder();
        if (r.addresses != null) for (LinkAddress l : r.addresses) { if (a.length() > 0) a.append(','); a.append(l.address); }
        Want w = byCid(r.cid);
        return "CALL apn=" + (w != null ? w.apn : "?") + " cid=" + r.cid + " active=" + r.active + " cause=" + r.cause
                + " ifname=" + r.ifname + " addrs=" + a + " gws=" + join(r.gateways) + " dns=" + join(r.dnses)
                + " pcscf=" + join(r.pcscf) + " mtu=" + r.mtuV6;
    }

    static boolean usable(SetupDataCallResult r) {
        return r != null && r.active == 2 && r.ifname != null && !r.ifname.isEmpty();
    }

    static void report(SetupDataCallResult[] calls) {
        StringBuilder all = new StringBuilder();
        if (calls != null) for (SetupDataCallResult r : calls) { String d = describe(r); log(d); all.append(d).append('\n'); }
        try (FileWriter w = new FileWriter(STATE)) { w.write(all.toString()); } catch (Exception e) { log("state write: " + e); }
        // any of our calls missing from the list (dropped by the network) -> set it up again
        for (Want w : wants) {
            if (w.needSetup || w.pendingSerial >= 0 || w.cid < 0) continue;
            boolean up = false;
            if (calls != null) for (SetupDataCallResult r : calls) up |= r.cid == w.cid && usable(r);
            if (!up) { log(w.apn + ": call gone -> setting up again"); w.retryLater(RETRY_MS); }
        }
    }

    static int field(Class<?> c, String name, int dflt) {
        try { return c.getField(name).getInt(null); } catch (Exception e) { return dflt; }
    }

    static String hash(Class<?> c) {
        try { return (String) c.getField("HASH").get(null); } catch (Exception e) { return "notfrozen"; }
    }

    static void ackIfNeeded(int type, int expected) {
        if (type == expected) try { data.responseAcknowledgement(); } catch (Exception e) { log("ack: " + e); }
    }

    static class Response extends IRadioDataResponse.Stub {
        void done(String what, RadioResponseInfo info) {
            log(what + " serial=" + info.serial + " error=" + info.error);
            ackIfNeeded(info.type, RESPONSE_SOLICITED_ACK_EXP);
        }
        public void acknowledgeRequest(int serial) {}
        public void allocatePduSessionIdResponse(RadioResponseInfo info, int id) { done("allocatePduSessionId", info); }
        public void cancelHandoverResponse(RadioResponseInfo info) { done("cancelHandover", info); }
        public void deactivateDataCallResponse(RadioResponseInfo info) { done("deactivateDataCall", info); }
        public void getDataCallListResponse(RadioResponseInfo info, SetupDataCallResult[] dc) {
            done("getDataCallList", info);
            report(dc);
            if (listOnly) synchronized (lock) { lock.notifyAll(); }
        }
        public void getSlicingConfigResponse(RadioResponseInfo info, SlicingConfig c) { done("getSlicingConfig", info); }
        public void releasePduSessionIdResponse(RadioResponseInfo info) { done("releasePduSessionId", info); }
        public void setDataAllowedResponse(RadioResponseInfo info) { done("setDataAllowed", info); }
        public void setDataProfileResponse(RadioResponseInfo info) { done("setDataProfile", info); }
        public void setDataThrottlingResponse(RadioResponseInfo info) { done("setDataThrottling", info); }
        public void setInitialAttachApnResponse(RadioResponseInfo info) { done("setInitialAttachApn", info); }
        public void setupDataCallResponse(RadioResponseInfo info, SetupDataCallResult dc) {
            done("setupDataCall", info);
            Want w = null;
            for (Want x : wants) if (x.pendingSerial == info.serial) w = x;
            if (w == null) { log("setupDataCall response for unknown serial " + info.serial); return; }
            w.pendingSerial = -1;
            if (info.error != 0 || !usable(dc)) {
                long wait = dc != null && dc.suggestedRetryTime > 0 ? dc.suggestedRetryTime : RETRY_MS;
                log(w.apn + ": setup failed (cause " + (dc != null ? dc.cause : -1) + ") -> retry in " + wait + " ms");
                w.retryLater(wait);
                return;
            }
            w.cid = dc.cid;
            log(describe(dc));
            // re-read the full list so the state file holds every call rild has
            try { data.getDataCallList(100); } catch (Exception e) { log("getDataCallList: " + e); }
        }
        public void startHandoverResponse(RadioResponseInfo info) { done("startHandover", info); }
        public void startKeepaliveResponse(RadioResponseInfo info, KeepaliveStatus s) { done("startKeepalive", info); }
        public void stopKeepaliveResponse(RadioResponseInfo info) { done("stopKeepalive", info); }
        public int getInterfaceVersion() { return field(IRadioDataResponse.class, "VERSION", 1); }
        public String getInterfaceHash() { return hash(IRadioDataResponse.class); }
    }

    static class Indication extends IRadioDataIndication.Stub {
        public void dataCallListChanged(int type, SetupDataCallResult[] dc) {
            log("dataCallListChanged");
            ackIfNeeded(type, INDICATION_UNSOLICITED_ACK_EXP);
            report(dc);
        }
        public void keepaliveStatus(int type, KeepaliveStatus s) { ackIfNeeded(type, INDICATION_UNSOLICITED_ACK_EXP); }
        public void pcoData(int type, PcoDataInfo p) { ackIfNeeded(type, INDICATION_UNSOLICITED_ACK_EXP); }
        public void unthrottleApn(int type, DataProfileInfo p) { log("unthrottleApn"); ackIfNeeded(type, INDICATION_UNSOLICITED_ACK_EXP); }
        public void slicingConfigChanged(int type, SlicingConfig c) { ackIfNeeded(type, INDICATION_UNSOLICITED_ACK_EXP); }
        public int getInterfaceVersion() { return field(IRadioDataIndication.class, "VERSION", 1); }
        public String getInterfaceHash() { return hash(IRadioDataIndication.class); }
    }

    static DataProfileInfo baseProfile(String apn) {
        DataProfileInfo p = new DataProfileInfo();
        p.apn = apn;
        p.authType = 0;                     // NO_PAP_NO_CHAP
        p.user = "";
        p.password = "";
        p.type = 1;                         // TYPE_3GPP
        p.maxConnsTime = 300;
        p.maxConns = 20;
        p.waitTime = 0;
        p.enabled = true;
        p.bearerBitmap = 0;
        p.mtuV4 = 0;
        p.mtuV6 = 0;
        p.persistent = true;
        p.alwaysOn = false;
        p.trafficDescriptor = new TrafficDescriptor();
        p.trafficDescriptor.dnn = apn;
        p.infrastructureBitmap = 1;         // INFRASTRUCTURE_CELLULAR
        return p;
    }

    static DataProfileInfo internetProfile(String apn) {
        DataProfileInfo p = baseProfile(apn);
        p.profileId = 0;                    // ID_DEFAULT
        p.protocol = PDP_IPV4V6;
        p.roamingProtocol = PDP_IPV4V6;
        p.supportedApnTypesBitmap = APN_DEFAULT_SUPL_MMS_XCAP;
        p.preferred = true;
        return p;
    }

    // as One UI sends it (RILJ log): T-Mobile IMS, ims, IPV6 / roaming IPV4V6, profileId=2
    static DataProfileInfo imsProfile() {
        DataProfileInfo p = baseProfile("ims");
        p.profileId = 2;                    // ID_IMS
        p.protocol = PDP_IPV6;
        p.roamingProtocol = PDP_IPV4V6;
        p.supportedApnTypesBitmap = APN_IMS;
        p.preferred = false;
        return p;
    }

    public static void main(String[] args) throws Exception {
        String cmd = args.length > 0 ? args[0] : "up";
        listOnly = cmd.equals("list");
        for (int i = 1; i < args.length; i++) wants.add(new Want(args[i]));
        if (wants.isEmpty()) wants.add(new Want("fast.t-mobile.com"));

        IBinder b = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("waitForDeclaredService", String.class).invoke(null, SERVICE);
        if (b == null) { log("no " + SERVICE); System.exit(1); }
        data = IRadioData.Stub.asInterface(b);
        log("rild IRadioData: client version " + field(IRadioData.class, "VERSION", -1));
        // rild restarting means our calls are gone: exit so the session script can restart us
        b.linkToDeath(() -> { log("rild died"); System.exit(3); }, 0);

        data.setResponseFunctions(new Response(), new Indication());
        data.getDataCallList(1);
        // network client too: rild rejects the IMS call until someone has asked for registration state
        if (!listOnly) S26Ril.startNetwork();
        if (listOnly) {
            synchronized (lock) { lock.wait(10000); }
            System.exit(0);
        }
        data.setDataAllowed(2, true);
        while (true) {
            for (Want w : wants) {
                if (!w.needSetup || System.currentTimeMillis() < w.nextSetupAt) continue;
                w.needSetup = false;
                w.pendingSerial = serial++;
                data.setupDataCall(w.pendingSerial, ACCESS_NETWORK_NGRAN, w.profile, true, REASON_NORMAL,
                        new LinkAddress[0], new String[0], 0, null, true);
                log("setupDataCall sent for " + w.apn + " (serial " + w.pendingSerial + ")");
            }
            Thread.sleep(1000);
        }
    }
}
