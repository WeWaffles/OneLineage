// S26Ril — shared helpers + the IRadioNetwork client half of s26_rildata.
// rild only trusts its packet-registration state once a client has asked for it: without an
// IRadioNetwork client (com.android.phone normally) it rejects the IMS data call with
// "DCM-Reject IMS data call, as PS not regi". So: register for network callbacks, query the data/voice
// registration state, and re-query whenever rild says the network state changed, like the phone app.
// The generated I*Callbacks (gen_stubs.ps1) forward every callback here, tagged with their interface;
// tools register a ResponseHandler to receive the responses they wait for (see S26RilSim).
import android.hardware.radio.RadioResponseInfo;
import android.hardware.radio.network.IRadioNetwork;
import android.os.IBinder;

import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;

class S26Ril {
    static final String NETWORK_SERVICE = "android.hardware.radio.network.IRadioNetwork/slot1";
    static final int RESPONSE_SOLICITED_ACK_EXP = 2;
    static final int INDICATION_UNSOLICITED_ACK_EXP = 1;
    // indications that arrive constantly and need no action
    static final String QUIET = "currentSignalStrength currentPhysicalChannelConfigs cellInfoList barringInfoChanged nitzTimeReceived";

    interface ResponseHandler { void handle(String name, RadioResponseInfo info, Object[] args); }

    // per interface: how to acknowledge rild, and who wants its responses
    static final Map<String, Runnable> acks = new HashMap<>();
    static final Map<String, ResponseHandler> handlers = new HashMap<>();
    static boolean verbose = true;

    static IRadioNetwork net;
    static int serial = 5000;

    static int field(Class<?> c, String name, int dflt) {
        try { return c.getField(name).getInt(null); } catch (Exception e) { return dflt; }
    }

    static String hash(Class<?> c) {
        try { return (String) c.getField("HASH").get(null); } catch (Exception e) { return "notfrozen"; }
    }

    static IBinder service(String name) throws Exception {
        return (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("waitForDeclaredService", String.class).invoke(null, name);
    }

    static void startNetwork() throws Exception {
        IBinder b = service(NETWORK_SERVICE);
        if (b == null) { S26RilData.log("no " + NETWORK_SERVICE); return; }
        net = IRadioNetwork.Stub.asInterface(b);
        acks.put("IRadioNetwork", () -> { try { net.responseAcknowledgement(); } catch (Exception e) { S26RilData.log("network ack: " + e); } });
        net.setResponseFunctions(new IRadioNetworkCallbacks.Response(), new IRadioNetworkCallbacks.Indication());
        queryRegistration();
    }

    static void queryRegistration() {
        try {
            net.getDataRegistrationState(serial++);
            net.getVoiceRegistrationState(serial++);
        } catch (Exception e) { S26RilData.log("network query: " + e); }
    }

    static void ack(String iface) {
        Runnable a = acks.get(iface);
        if (a != null) a.run();
    }

    static String brief(Object[] args) {
        String s = Arrays.deepToString(args);
        return s.length() > 300 ? s.substring(0, 300) + "..." : s;
    }

    static void onResponse(String iface, String name, RadioResponseInfo info, Object[] args) {
        if (verbose) S26RilData.log(iface + " " + name + " error=" + info.error + " " + brief(args));
        if (info.type == RESPONSE_SOLICITED_ACK_EXP) ack(iface);
        ResponseHandler h = handlers.get(iface);
        if (h != null) h.handle(name, info, args);
    }

    static void onAck(String iface, String name) {}

    static void onIndication(String iface, String name, int type, Object[] args) {
        if (verbose && !QUIET.contains(name)) S26RilData.log(iface + " ind " + name);
        if (type == INDICATION_UNSOLICITED_ACK_EXP) ack(iface);
        if (name.equals("networkStateChanged") && iface.equals("IRadioNetwork")) queryRegistration();
    }
}
