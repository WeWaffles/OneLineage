package android.hardware.radio.network;
// generated compile-only stub (gen_stubs.ps1)
public interface IRadioNetworkResponse extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioNetworkResponse {
        public android.os.IBinder asBinder() { return this; }
    }
    void acknowledgeRequest(int serial) throws android.os.RemoteException;
    void getAllowedNetworkTypesBitmapResponse(android.hardware.radio.RadioResponseInfo info, int networkTypeBitmap) throws android.os.RemoteException;
    void getAvailableBandModesResponse(android.hardware.radio.RadioResponseInfo info, int[] bandModes) throws android.os.RemoteException;
    void getAvailableNetworksResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.network.OperatorInfo[] networkInfos) throws android.os.RemoteException;
    void getBarringInfoResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.network.CellIdentity cellIdentity, android.hardware.radio.network.BarringInfo[] barringInfos) throws android.os.RemoteException;
    void getCdmaRoamingPreferenceResponse(android.hardware.radio.RadioResponseInfo info, int type) throws android.os.RemoteException;
    void getCellInfoListResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.network.CellInfo[] cellInfo) throws android.os.RemoteException;
    void getDataRegistrationStateResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.network.RegStateResult dataRegResponse) throws android.os.RemoteException;
    void getImsRegistrationStateResponse(android.hardware.radio.RadioResponseInfo info, boolean isRegistered, int ratFamily) throws android.os.RemoteException;
    void getNetworkSelectionModeResponse(android.hardware.radio.RadioResponseInfo info, boolean manual) throws android.os.RemoteException;
    void getOperatorResponse(android.hardware.radio.RadioResponseInfo info, String longName, String shortName, String numeric) throws android.os.RemoteException;
    void getSignalStrengthResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.network.SignalStrength signalStrength) throws android.os.RemoteException;
    void getSystemSelectionChannelsResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.network.RadioAccessSpecifier[] specifiers) throws android.os.RemoteException;
    void getVoiceRadioTechnologyResponse(android.hardware.radio.RadioResponseInfo info, int rat) throws android.os.RemoteException;
    void getVoiceRegistrationStateResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.network.RegStateResult voiceRegResponse) throws android.os.RemoteException;
    void isNrDualConnectivityEnabledResponse(android.hardware.radio.RadioResponseInfo info, boolean isEnabled) throws android.os.RemoteException;
    void setAllowedNetworkTypesBitmapResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setBandModeResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setBarringPasswordResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setCdmaRoamingPreferenceResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setCellInfoListRateResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setIndicationFilterResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setLinkCapacityReportingCriteriaResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setLocationUpdatesResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setNetworkSelectionModeAutomaticResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setNetworkSelectionModeManualResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setNrDualConnectivityStateResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setSignalStrengthReportingCriteriaResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setSuppServiceNotificationsResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setSystemSelectionChannelsResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void startNetworkScanResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void stopNetworkScanResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void supplyNetworkDepersonalizationResponse(android.hardware.radio.RadioResponseInfo info, int remainingRetries) throws android.os.RemoteException;
    void setUsageSettingResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void getUsageSettingResponse(android.hardware.radio.RadioResponseInfo info, int usageSetting) throws android.os.RemoteException;
    void setEmergencyModeResponse(android.hardware.radio.RadioResponseInfo info, android.hardware.radio.network.EmergencyRegResult regState) throws android.os.RemoteException;
    void triggerEmergencyNetworkScanResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void exitEmergencyModeResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void cancelEmergencyNetworkScanResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setNullCipherAndIntegrityEnabledResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void isNullCipherAndIntegrityEnabledResponse(android.hardware.radio.RadioResponseInfo info, boolean isEnabled) throws android.os.RemoteException;
    void isN1ModeEnabledResponse(android.hardware.radio.RadioResponseInfo info, boolean isEnabled) throws android.os.RemoteException;
    void setN1ModeEnabledResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void isCellularIdentifierTransparencyEnabledResponse(android.hardware.radio.RadioResponseInfo info, boolean isEnabled) throws android.os.RemoteException;
    void setCellularIdentifierTransparencyEnabledResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setSecurityAlgorithmsUpdatedEnabledResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void isSecurityAlgorithmsUpdatedEnabledResponse(android.hardware.radio.RadioResponseInfo info, boolean isEnabled) throws android.os.RemoteException;
    void setSatellitePlmnResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void setSatelliteEnabledForCarrierResponse(android.hardware.radio.RadioResponseInfo info) throws android.os.RemoteException;
    void isSatelliteEnabledForCarrierResponse(android.hardware.radio.RadioResponseInfo info, boolean isEnabled) throws android.os.RemoteException;
    int getInterfaceVersion() throws android.os.RemoteException;
    String getInterfaceHash() throws android.os.RemoteException;
}
