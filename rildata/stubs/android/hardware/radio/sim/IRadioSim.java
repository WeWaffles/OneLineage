package android.hardware.radio.sim;
// generated compile-only stub (gen_stubs.ps1)
public interface IRadioSim extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioSim {
        public static IRadioSim asInterface(android.os.IBinder b) { return null; }
    }
    void areUiccApplicationsEnabled(int serial) throws android.os.RemoteException;
    void changeIccPin2ForApp(int serial, String oldPin2, String newPin2, String aid) throws android.os.RemoteException;
    void changeIccPinForApp(int serial, String oldPin, String newPin, String aid) throws android.os.RemoteException;
    void enableUiccApplications(int serial, boolean enable) throws android.os.RemoteException;
    void getAllowedCarriers(int serial) throws android.os.RemoteException;
    void getCdmaSubscription(int serial) throws android.os.RemoteException;
    void getCdmaSubscriptionSource(int serial) throws android.os.RemoteException;
    void getFacilityLockForApp(int serial, String facility, String password, int serviceClass, String appId) throws android.os.RemoteException;
    void getIccCardStatus(int serial) throws android.os.RemoteException;
    void getImsiForApp(int serial, String aid) throws android.os.RemoteException;
    void getSimPhonebookCapacity(int serial) throws android.os.RemoteException;
    void getSimPhonebookRecords(int serial) throws android.os.RemoteException;
    void iccCloseLogicalChannel(int serial, int channelId) throws android.os.RemoteException;
    void iccIoForApp(int serial, android.hardware.radio.sim.IccIo iccIo) throws android.os.RemoteException;
    void iccOpenLogicalChannel(int serial, String aid, int p2) throws android.os.RemoteException;
    void iccTransmitApduBasicChannel(int serial, android.hardware.radio.sim.SimApdu message) throws android.os.RemoteException;
    void iccTransmitApduLogicalChannel(int serial, android.hardware.radio.sim.SimApdu message) throws android.os.RemoteException;
    void reportStkServiceIsRunning(int serial) throws android.os.RemoteException;
    void requestIccSimAuthentication(int serial, int authContext, String authData, String aid) throws android.os.RemoteException;
    void responseAcknowledgement() throws android.os.RemoteException;
    void sendEnvelope(int serial, String contents) throws android.os.RemoteException;
    void sendEnvelopeWithStatus(int serial, String contents) throws android.os.RemoteException;
    void sendTerminalResponseToSim(int serial, String contents) throws android.os.RemoteException;
    void setAllowedCarriers(int serial, android.hardware.radio.sim.CarrierRestrictions carriers, int multiSimPolicy) throws android.os.RemoteException;
    void setCarrierInfoForImsiEncryption(int serial, android.hardware.radio.sim.ImsiEncryptionInfo imsiEncryptionInfo) throws android.os.RemoteException;
    void setCdmaSubscriptionSource(int serial, int cdmaSub) throws android.os.RemoteException;
    void setFacilityLockForApp(int serial, String facility, boolean lockState, String password, int serviceClass, String appId) throws android.os.RemoteException;
    void setResponseFunctions(android.hardware.radio.sim.IRadioSimResponse radioSimResponse, android.hardware.radio.sim.IRadioSimIndication radioSimIndication) throws android.os.RemoteException;
    void setSimCardPower(int serial, int powerUp) throws android.os.RemoteException;
    void setUiccSubscription(int serial, android.hardware.radio.sim.SelectUiccSub uiccSub) throws android.os.RemoteException;
    void supplyIccPin2ForApp(int serial, String pin2, String aid) throws android.os.RemoteException;
    void supplyIccPinForApp(int serial, String pin, String aid) throws android.os.RemoteException;
    void supplyIccPuk2ForApp(int serial, String puk2, String pin2, String aid) throws android.os.RemoteException;
    void supplyIccPukForApp(int serial, String puk, String pin, String aid) throws android.os.RemoteException;
    void supplySimDepersonalization(int serial, int persoType, String controlKey) throws android.os.RemoteException;
    void updateSimPhonebookRecords(int serial, android.hardware.radio.sim.PhonebookRecordInfo recordInfo) throws android.os.RemoteException;
    void iccCloseLogicalChannelWithSessionInfo(int serial, android.hardware.radio.sim.SessionInfo sessionInfo) throws android.os.RemoteException;
}
