package com.eggdog.attest;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import android.util.Log;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.cert.Certificate;

/** Generates an attested EC key (optionally StrongBox) and logs the chain, one cert per line. */
public class ProbeActivity extends Activity {
    private static final String TAG = "OLATTEST";

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        new Thread(() -> {
            Log.i(TAG, "build " + Build.FINGERPRINT + " | " + Build.MANUFACTURER + " " + Build.MODEL
                    + " " + Build.DEVICE + " | patch " + Build.VERSION.SECURITY_PATCH);
            probe(false);
            probe(true);
            Log.i(TAG, "done");
            runOnUiThread(this::finish);
        }).start();
    }

    private void probe(boolean strongBox) {
        String alias = strongBox ? "ol_probe_sb" : "ol_probe";
        try {
            KeyPairGenerator g = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
            g.initialize(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setAttestationChallenge("olprobe".getBytes())
                    .setIsStrongBoxBacked(strongBox)
                    .build());
            g.generateKeyPair();
            KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
            ks.load(null);
            Certificate[] chain = ks.getCertificateChain(alias);
            Log.i(TAG, (strongBox ? "strongbox" : "tee") + " chain length " + chain.length);
            for (int i = 0; i < chain.length; i++) {
                Log.i(TAG, (strongBox ? "sb" : "tee") + " cert" + i + " "
                        + Base64.encodeToString(chain[i].getEncoded(), Base64.NO_WRAP));
            }
        } catch (Throwable t) {
            Log.e(TAG, (strongBox ? "strongbox" : "tee") + " failed: " + t, t);
        }
    }
}
