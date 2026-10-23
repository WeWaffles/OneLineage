package android.hardware.radio.data;
// compile-only stub (AOSP radio data AIDL, current)
public interface IRadioData extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioData {
        public static IRadioData asInterface(android.os.IBinder b) { return null; }
    }
    void deactivateDataCall(int serial, int cid, int reason) throws android.os.RemoteException;
    void getDataCallList(int serial) throws android.os.RemoteException;
    void responseAcknowledgement() throws android.os.RemoteException;
    void setDataAllowed(int serial, boolean allow) throws android.os.RemoteException;
    void setResponseFunctions(IRadioDataResponse r, IRadioDataIndication i) throws android.os.RemoteException;
    void setupDataCall(int serial, int accessNetwork, DataProfileInfo dataProfileInfo, boolean roamingAllowed,
            int reason, LinkAddress[] addresses, String[] dnses, int pduSessionId, SliceInfo sliceInfo,
            boolean matchAllRuleAllowed) throws android.os.RemoteException;
}
