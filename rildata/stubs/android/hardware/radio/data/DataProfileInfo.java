package android.hardware.radio.data;
// compile-only stub (AOSP radio data AIDL, current)
public class DataProfileInfo {
    public int profileId;
    public String apn;
    public int protocol;
    public int roamingProtocol;
    public int authType;
    public String user;
    public String password;
    public int type;
    public int maxConnsTime;
    public int maxConns;
    public int waitTime;
    public boolean enabled;
    public int supportedApnTypesBitmap;
    public int bearerBitmap;
    public int mtuV4;
    public int mtuV6;
    public boolean preferred;
    public boolean persistent;
    public boolean alwaysOn;
    public TrafficDescriptor trafficDescriptor;
    public int infrastructureBitmap;
}
