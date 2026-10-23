package android.hardware.radio.network;
// generated compile-only stub (gen_stubs.ps1)
public interface IRadioNetwork extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioNetwork {
        public static IRadioNetwork asInterface(android.os.IBinder b) { return null; }
    }
    void getAllowedNetworkTypesBitmap(int serial) throws android.os.RemoteException;
    void getAvailableBandModes(int serial) throws android.os.RemoteException;
    void getAvailableNetworks(int serial) throws android.os.RemoteException;
    void getBarringInfo(int serial) throws android.os.RemoteException;
    void getCdmaRoamingPreference(int serial) throws android.os.RemoteException;
    void getCellInfoList(int serial) throws android.os.RemoteException;
    void getDataRegistrationState(int serial) throws android.os.RemoteException;
    void getImsRegistrationState(int serial) throws android.os.RemoteException;
    void getNetworkSelectionMode(int serial) throws android.os.RemoteException;
    void getOperator(int serial) throws android.os.RemoteException;
    void getSignalStrength(int serial) throws android.os.RemoteException;
    void getSystemSelectionChannels(int serial) throws android.os.RemoteException;
    void getVoiceRadioTechnology(int serial) throws android.os.RemoteException;
    void getVoiceRegistrationState(int serial) throws android.os.RemoteException;
    void isNrDualConnectivityEnabled(int serial) throws android.os.RemoteException;
    void responseAcknowledgement() throws android.os.RemoteException;
    void setAllowedNetworkTypesBitmap(int serial, int networkTypeBitmap) throws android.os.RemoteException;
    void setBandMode(int serial, int mode) throws android.os.RemoteException;
    void setBarringPassword(int serial, String facility, String oldPassword, String newPassword) throws android.os.RemoteException;
    void setCdmaRoamingPreference(int serial, int type) throws android.os.RemoteException;
    void setCellInfoListRate(int serial, int rate) throws android.os.RemoteException;
    void setIndicationFilter(int serial, int indicationFilter) throws android.os.RemoteException;
    void setLinkCapacityReportingCriteria(int serial, int hysteresisMs, int hysteresisDlKbps, int hysteresisUlKbps, int[] thresholdsDownlinkKbps, int[] thresholdsUplinkKbps, int accessNetwork) throws android.os.RemoteException;
    void setLocationUpdates(int serial, boolean enable) throws android.os.RemoteException;
    void setNetworkSelectionModeAutomatic(int serial) throws android.os.RemoteException;
    void setNetworkSelectionModeManual(int serial, String operatorNumeric, int ran) throws android.os.RemoteException;
    void setNrDualConnectivityState(int serial, byte nrDualConnectivityState) throws android.os.RemoteException;
    void setResponseFunctions(android.hardware.radio.network.IRadioNetworkResponse radioNetworkResponse, android.hardware.radio.network.IRadioNetworkIndication radioNetworkIndication) throws android.os.RemoteException;
    void setSignalStrengthReportingCriteria(int serial, android.hardware.radio.network.SignalThresholdInfo[] signalThresholdInfos) throws android.os.RemoteException;
    void setSuppServiceNotifications(int serial, boolean enable) throws android.os.RemoteException;
    void setSystemSelectionChannels(int serial, boolean specifyChannels, android.hardware.radio.network.RadioAccessSpecifier[] specifiers) throws android.os.RemoteException;
    void startNetworkScan(int serial, android.hardware.radio.network.NetworkScanRequest request) throws android.os.RemoteException;
    void stopNetworkScan(int serial) throws android.os.RemoteException;
    void supplyNetworkDepersonalization(int serial, String netPin) throws android.os.RemoteException;
    void setUsageSetting(int serial, int usageSetting) throws android.os.RemoteException;
    void getUsageSetting(int serial) throws android.os.RemoteException;
    void setEmergencyMode(int serial, int emcModeType) throws android.os.RemoteException;
    void triggerEmergencyNetworkScan(int serial, android.hardware.radio.network.EmergencyNetworkScanTrigger request) throws android.os.RemoteException;
    void cancelEmergencyNetworkScan(int serial, boolean resetScan) throws android.os.RemoteException;
    void exitEmergencyMode(int serial) throws android.os.RemoteException;
    void setNullCipherAndIntegrityEnabled(int serial, boolean enabled) throws android.os.RemoteException;
    void isNullCipherAndIntegrityEnabled(int serial) throws android.os.RemoteException;
    void isN1ModeEnabled(int serial) throws android.os.RemoteException;
    void setN1ModeEnabled(int serial, boolean enable) throws android.os.RemoteException;
    void isCellularIdentifierTransparencyEnabled(int serial) throws android.os.RemoteException;
    void setCellularIdentifierTransparencyEnabled(int serial, boolean enabled) throws android.os.RemoteException;
    void setSecurityAlgorithmsUpdatedEnabled(int serial, boolean enable) throws android.os.RemoteException;
    void isSecurityAlgorithmsUpdatedEnabled(int serial) throws android.os.RemoteException;
    void setSatellitePlmn(int serial, int simSlot, String[] carrierPlmnArray, String[] allSatellitePlmnArray) throws android.os.RemoteException;
    void setSatelliteEnabledForCarrier(int serial, int simSlot, boolean satelliteEnabled) throws android.os.RemoteException;
    void isSatelliteEnabledForCarrier(int serial, int simSlot) throws android.os.RemoteException;
}
