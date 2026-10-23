package android.hardware.radio.network;
// generated compile-only stub (gen_stubs.ps1)
public interface IRadioNetworkIndication extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioNetworkIndication {
        public android.os.IBinder asBinder() { return this; }
    }
    void barringInfoChanged(int type, android.hardware.radio.network.CellIdentity cellIdentity, android.hardware.radio.network.BarringInfo[] barringInfos) throws android.os.RemoteException;
    void cdmaPrlChanged(int type, int version) throws android.os.RemoteException;
    void cellInfoList(int type, android.hardware.radio.network.CellInfo[] records) throws android.os.RemoteException;
    void currentLinkCapacityEstimate(int type, android.hardware.radio.network.LinkCapacityEstimate lce) throws android.os.RemoteException;
    void currentPhysicalChannelConfigs(int type, android.hardware.radio.network.PhysicalChannelConfig[] configs) throws android.os.RemoteException;
    void currentSignalStrength(int type, android.hardware.radio.network.SignalStrength signalStrength) throws android.os.RemoteException;
    void imsNetworkStateChanged(int type) throws android.os.RemoteException;
    void networkScanResult(int type, android.hardware.radio.network.NetworkScanResult result) throws android.os.RemoteException;
    void networkStateChanged(int type) throws android.os.RemoteException;
    void nitzTimeReceived(int type, String nitzTime, long receivedTimeMs, long ageMs) throws android.os.RemoteException;
    void registrationFailed(int type, android.hardware.radio.network.CellIdentity cellIdentity, String chosenPlmn, int domain, int causeCode, int additionalCauseCode) throws android.os.RemoteException;
    void restrictedStateChanged(int type, int state) throws android.os.RemoteException;
    void suppSvcNotify(int type, android.hardware.radio.network.SuppSvcNotification suppSvc) throws android.os.RemoteException;
    void voiceRadioTechChanged(int type, int rat) throws android.os.RemoteException;
    void emergencyNetworkScanResult(int type, android.hardware.radio.network.EmergencyRegResult result) throws android.os.RemoteException;
    void cellularIdentifierDisclosed(int type, android.hardware.radio.network.CellularIdentifierDisclosure disclosure) throws android.os.RemoteException;
    void securityAlgorithmsUpdated(int type, android.hardware.radio.network.SecurityAlgorithmUpdate securityAlgorithmUpdate) throws android.os.RemoteException;
    int getInterfaceVersion() throws android.os.RemoteException;
    String getInterfaceHash() throws android.os.RemoteException;
}
