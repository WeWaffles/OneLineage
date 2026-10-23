package android.hardware.radio.data;
// compile-only stub (AOSP radio data AIDL, current)
public class SetupDataCallResult {
    public int cause;
    public long suggestedRetryTime;
    public int cid;
    public int active;
    public int type;
    public String ifname;
    public LinkAddress[] addresses;
    public String[] dnses;
    public String[] gateways;
    public String[] pcscf;
    public int mtuV4;
    public int mtuV6;
}
