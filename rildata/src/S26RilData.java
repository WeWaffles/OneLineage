// S26RilData — rild's data client in place of com.android.phone, so Nura gets mobile data while the
// Android framework is stopped (camera/audio stand-ins keep working). Run with app_process (no zygote
// needed); it uses the device's own radio AIDL classes from the boot classpath.
//   CLASSPATH=s26_rildata.dex app_process / S26RilData up [apn]   # set up the internet call, stay alive
//   ... S26RilData list                                             # print rild's current calls, exit
// rild drops every call when its client dies, so `up` must keep running for the whole session.
// Each call state is printed as one line and written to $STATE for the network script:
//   CALL cid=1 active=2 ifname=rmnet_data0 addrs=a/64,b/27 gws=fe80::2,192.0.0.1 dns=... mtu=1436
import android.hardware.radio.RadioResponseInfo;
import android.hardware.radio.data.*;
import android.os.IBinder;

import java.io.FileWriter;

public class S26RilData {
    static final String SERVICE = "android.hardware.radio.data.IRadioData/slot1";
    static final String STATE = "/data/local/tmp/nura_stage/rildata.state";
    // AOSP enum values (radio AIDL)
    static final int ACCESS_NETWORK_NGRAN = 6;
    static final int REASON_NORMAL = 1;
    static final int PDP_IPV4V6 = 2;
    static final int APN_DEFAULT_SUPL_MMS_XCAP = 1 | 2 | 4 | 2048;
    static final int RESPONSE_SOLICITED_ACK_EXP = 2;
    static final int INDICATION_UNSOLICITED_ACK_EXP = 1;

    static IRadioData data;
    static final Object lock = new Object();
    static boolean listOnly;
    static String apn;
    static int serial = 10;
    // set when no active internet call: the main loop (re)sends setupDataCall. Right after rild restarts
    // the modem's data side isn't ready and setup fails (cause -7), and the network can drop a call later.
    static volatile boolean needSetup = true;
    static volatile long nextSetupAt;
    static final long RETRY_MS = 10000;
    static volatile boolean setupPending;   // a setupDataCall is in flight: list updates don't retry

    static void log(String s) { System.out.println(s); System.out.flush(); }

    static String join(String[] a) {
        if (a == null) return "";
        StringBuilder b = new StringBuilder();
        for (String s : a) { if (s == null || s.isEmpty() || s.startsWith("0.0.0.0")) continue; if (b.length() > 0) b.append(','); b.append(s.replace("/", "")); }
        return b.toString();
    }

    static String describe(SetupDataCallResult r) {
        StringBuilder a = new StringBuilder();
        if (r.addresses != null) for (LinkAddress l : r.addresses) { if (a.length() > 0) a.append(','); a.append(l.address); }
        return "CALL cid=" + r.cid + " active=" + r.active + " cause=" + r.cause + " ifname=" + r.ifname
                + " addrs=" + a + " gws=" + join(r.gateways) + " dns=" + join(r.dnses) + " mtu=" + r.mtuV6;
    }

    static boolean usable(SetupDataCallResult r) {
        return r != null && r.active == 2 && r.ifname != null && !r.ifname.isEmpty();
    }

    static void report(SetupDataCallResult[] calls) {
        StringBuilder all = new StringBuilder();
        boolean up = false;
        if (calls != null) for (SetupDataCallResult r : calls) {
            String d = describe(r); log(d); all.append(d).append('\n');
            up |= usable(r);
        }
        try (FileWriter w = new FileWriter(STATE)) { w.write(all.toString()); } catch (Exception e) { log("state write: " + e); }
        if (!up && !needSetup && !setupPending) { log("no active call -> setting up again"); retryLater(RETRY_MS); }
    }

    static void retryLater(long ms) {
        nextSetupAt = System.currentTimeMillis() + ms;
        needSetup = true;
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
            setupPending = false;
            if (dc != null) log(describe(dc));
            if (info.error != 0 || !usable(dc)) {
                long wait = dc != null && dc.suggestedRetryTime > 0 ? dc.suggestedRetryTime : RETRY_MS;
                log("setup failed -> retry in " + wait + " ms");
                retryLater(wait);
                return;
            }
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

    static DataProfileInfo internetProfile(String apn) {
        DataProfileInfo p = new DataProfileInfo();
        p.profileId = 0;                    // ID_DEFAULT
        p.apn = apn;
        p.protocol = PDP_IPV4V6;
        p.roamingProtocol = PDP_IPV4V6;
        p.authType = 0;                     // NO_PAP_NO_CHAP
        p.user = "";
        p.password = "";
        p.type = 1;                         // TYPE_3GPP
        p.maxConnsTime = 300;
        p.maxConns = 20;
        p.waitTime = 0;
        p.enabled = true;
        p.supportedApnTypesBitmap = APN_DEFAULT_SUPL_MMS_XCAP;
        p.bearerBitmap = 0;
        p.mtuV4 = 0;
        p.mtuV6 = 0;
        p.preferred = true;
        p.persistent = true;
        p.alwaysOn = false;
        p.trafficDescriptor = new TrafficDescriptor();
        p.trafficDescriptor.dnn = apn;
        p.infrastructureBitmap = 1;         // INFRASTRUCTURE_CELLULAR
        return p;
    }

    public static void main(String[] args) throws Exception {
        String cmd = args.length > 0 ? args[0] : "up";
        apn = args.length > 1 ? args[1] : "fast.t-mobile.com";
        listOnly = cmd.equals("list");

        IBinder b = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("waitForDeclaredService", String.class).invoke(null, SERVICE);
        if (b == null) { log("no " + SERVICE); System.exit(1); }
        data = IRadioData.Stub.asInterface(b);
        log("rild IRadioData: client version " + field(IRadioData.class, "VERSION", -1));
        // rild restarting means our calls are gone: exit so the session script can restart us
        b.linkToDeath(() -> { log("rild died"); System.exit(3); }, 0);

        data.setResponseFunctions(new Response(), new Indication());
        data.getDataCallList(1);
        if (listOnly) {
            synchronized (lock) { lock.wait(10000); }
            System.exit(0);
        }
        data.setDataAllowed(2, true);
        while (true) {
            if (needSetup && System.currentTimeMillis() >= nextSetupAt) {
                needSetup = false;
                setupPending = true;
                data.setupDataCall(serial++, ACCESS_NETWORK_NGRAN, internetProfile(apn), true, REASON_NORMAL,
                        new LinkAddress[0], new String[0], 0, null, true);
                log("setupDataCall sent for " + apn);
            }
            Thread.sleep(1000);
        }
    }
}
