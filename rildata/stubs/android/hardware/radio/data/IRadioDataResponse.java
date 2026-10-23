package android.hardware.radio.data;
import android.hardware.radio.RadioResponseInfo;
// compile-only stub (AOSP radio data AIDL, current)
public interface IRadioDataResponse extends android.os.IInterface {
    abstract class Stub extends android.os.Binder implements IRadioDataResponse {
        public android.os.IBinder asBinder() { return this; }
    }
    void acknowledgeRequest(int serial) throws android.os.RemoteException;
    void allocatePduSessionIdResponse(RadioResponseInfo info, int id) throws android.os.RemoteException;
    void cancelHandoverResponse(RadioResponseInfo info) throws android.os.RemoteException;
    void deactivateDataCallResponse(RadioResponseInfo info) throws android.os.RemoteException;
    void getDataCallListResponse(RadioResponseInfo info, SetupDataCallResult[] dcResponse) throws android.os.RemoteException;
    void getSlicingConfigResponse(RadioResponseInfo info, SlicingConfig slicingConfig) throws android.os.RemoteException;
    void releasePduSessionIdResponse(RadioResponseInfo info) throws android.os.RemoteException;
    void setDataAllowedResponse(RadioResponseInfo info) throws android.os.RemoteException;
    void setDataProfileResponse(RadioResponseInfo info) throws android.os.RemoteException;
    void setDataThrottlingResponse(RadioResponseInfo info) throws android.os.RemoteException;
    void setInitialAttachApnResponse(RadioResponseInfo info) throws android.os.RemoteException;
    void setupDataCallResponse(RadioResponseInfo info, SetupDataCallResult dcResponse) throws android.os.RemoteException;
    void startHandoverResponse(RadioResponseInfo info) throws android.os.RemoteException;
    void startKeepaliveResponse(RadioResponseInfo info, KeepaliveStatus status) throws android.os.RemoteException;
    void stopKeepaliveResponse(RadioResponseInfo info) throws android.os.RemoteException;
    int getInterfaceVersion() throws android.os.RemoteException;
    String getInterfaceHash() throws android.os.RemoteException;
}
