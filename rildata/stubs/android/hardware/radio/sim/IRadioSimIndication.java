package android.hardware.radio.sim;
// generated compile-only stub (gen_stubs.ps1)
public interface IRadioSimIndication extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioSimIndication {
        public android.os.IBinder asBinder() { return this; }
    }
    void carrierInfoForImsiEncryption(int info) throws android.os.RemoteException;
    void cdmaSubscriptionSourceChanged(int type, int cdmaSource) throws android.os.RemoteException;
    void simPhonebookChanged(int type) throws android.os.RemoteException;
    void simPhonebookRecordsReceived(int type, byte status, android.hardware.radio.sim.PhonebookRecordInfo[] records) throws android.os.RemoteException;
    void simRefresh(int type, android.hardware.radio.sim.SimRefreshResult refreshResult) throws android.os.RemoteException;
    void simStatusChanged(int type) throws android.os.RemoteException;
    void stkEventNotify(int type, String cmd) throws android.os.RemoteException;
    void stkProactiveCommand(int type, String cmd) throws android.os.RemoteException;
    void stkSessionEnd(int type) throws android.os.RemoteException;
    void subscriptionStatusChanged(int type, boolean activate) throws android.os.RemoteException;
    void uiccApplicationsEnablementChanged(int type, boolean enabled) throws android.os.RemoteException;
    int getInterfaceVersion() throws android.os.RemoteException;
    String getInterfaceHash() throws android.os.RemoteException;
}
