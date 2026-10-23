package android.hardware.radio.sim;
// generated compile-only stub (gen_stubs.ps1)
public interface IRadioSimResponse extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioSimResponse {
        public android.os.IBinder asBinder() { return this; }
    }
    void acknowledgeRequest(int serial) throws android.os.RemoteException;
    void areUiccApplicationsEnabledResponse(android.hardware.radio.RadioResponseInfo info, boolean enabled) throws android.os.RemoteException;
    void changeIccPin2ForAppResponse(android.hardware.radio.RadioResponseInfo info, int remainingRetries) throws android.os.RemoteException;
    void changeIccPinForAppResponse(android.hardware.radio.RadioResponseInfo info, int remainingRetries) throws android.os.RemoteException;
    void enableUiccApplicationsResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void getAllowedCarriersResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.sim.CarrierRestrictions carriers, int multiSimPolicy) throws android.os.RemoteException;
    void getCdmaSubscriptionResponse(android.hardware.radio.RadioResponseInfo info, String mdn, String hSid, String hNid, String min, String prl) throws android.os.RemoteException;
    void getCdmaSubscriptionSourceResponse(android.hardware.radio.RadioResponseInfo info, int source) throws android.os.RemoteException;
    void getFacilityLockForAppResponse(android.hardware.radio.RadioResponseInfo info, int response) throws android.os.RemoteException;
    void getIccCardStatusResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.sim.CardStatus cardStatus) throws android.os.RemoteException;
    void getImsiForAppResponse(android.hardware.radio.RadioResponseInfo info, String imsi) throws android.os.RemoteException;
    void getSimPhonebookCapacityResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.sim.PhonebookCapacity capacity) throws android.os.RemoteException;
    void getSimPhonebookRecordsResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void iccCloseLogicalChannelResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void iccIoForAppResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.sim.IccIoResult iccIo) throws android.os.RemoteException;
    void iccOpenLogicalChannelResponse(android.hardware.radio.RadioResponseInfo info, int channelId, byte[] selectResponse) throws android.os.RemoteException;
    void iccTransmitApduBasicChannelResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.sim.IccIoResult result) throws android.os.RemoteException;
    void iccTransmitApduLogicalChannelResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.sim.IccIoResult result) throws android.os.RemoteException;
    void reportStkServiceIsRunningResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void requestIccSimAuthenticationResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.sim.IccIoResult result) throws android.os.RemoteException;
    void sendEnvelopeResponse(android.hardware.radio.RadioResponseInfo info, String commandResponse) throws android.os.RemoteException;
    void sendEnvelopeWithStatusResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.sim.IccIoResult iccIo) throws android.os.RemoteException;
    void sendTerminalResponseToSimResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setAllowedCarriersResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setCarrierInfoForImsiEncryptionResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setCdmaSubscriptionSourceResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setFacilityLockForAppResponse(android.hardware.radio.RadioResponseInfo info, int retry) throws android.os.RemoteException;
    void setSimCardPowerResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setUiccSubscriptionResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void supplyIccPin2ForAppResponse(android.hardware.radio.RadioResponseInfo info, int remainingRetries) throws android.os.RemoteException;
    void supplyIccPinForAppResponse(android.hardware.radio.RadioResponseInfo info, int remainingRetries) throws android.os.RemoteException;
    void supplyIccPuk2ForAppResponse(android.hardware.radio.RadioResponseInfo info, int remainingRetries) throws android.os.RemoteException;
    void supplyIccPukForAppResponse(android.hardware.radio.RadioResponseInfo info, int remainingRetries) throws android.os.RemoteException;
    void supplySimDepersonalizationResponse(android.hardware.radio.RadioResponseInfo info, int persoType, int remainingRetries) throws android.os.RemoteException;
    void updateSimPhonebookRecordsResponse(android.hardware.radio.RadioResponseInfo info, int updatedRecordIndex) throws android.os.RemoteException;
    void iccCloseLogicalChannelWithSessionInfoResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    int getInterfaceVersion() throws android.os.RemoteException;
    String getInterfaceHash() throws android.os.RemoteException;
}
