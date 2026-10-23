package android.hardware.radio.data;
// compile-only stub (AOSP radio data AIDL, current)
public interface IRadioDataIndication extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioDataIndication {
        public android.os.IBinder asBinder() { return this; }
    }
    void dataCallListChanged(int type, SetupDataCallResult[] dcList) throws android.os.RemoteException;
    void keepaliveStatus(int type, KeepaliveStatus status) throws android.os.RemoteException;
    void pcoData(int type, PcoDataInfo pco) throws android.os.RemoteException;
    void unthrottleApn(int type, DataProfileInfo dataProfileInfo) throws android.os.RemoteException;
    void slicingConfigChanged(int type, SlicingConfig slicingConfig) throws android.os.RemoteException;
    int getInterfaceVersion() throws android.os.RemoteException;
    String getInterfaceHash() throws android.os.RemoteException;
}
