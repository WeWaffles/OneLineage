package android.os;
// compile-only stub; the device's framework provides the real class
public interface IBinder {
    interface DeathRecipient { void binderDied(); }
    void linkToDeath(DeathRecipient recipient, int flags) throws RemoteException;
}
