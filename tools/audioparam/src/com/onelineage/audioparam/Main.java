package com.onelineage.audioparam;

import java.lang.reflect.Method;

/**
 * Sends key=value pairs to the audio HAL, like AudioManager.setParameters,
 * from a shell (no app context needed):
 *
 *   CLASSPATH=ol_audioparam.dex app_process /system/bin \
 *       com.onelineage.audioparam.Main "g_call_sim_slot=0x02"
 *
 * One UI's Telecom sends g_call_sim_slot before every call, which makes the
 * Samsung audio HAL route call audio through that SIM's voice channel
 * (VSID). Lineage's Telecom never sends it, so with the SIM in the second
 * slot calls ran on the first slot's channel and were silent both ways.
 * master_prepare.sh runs this once the guest has booted (see
 * docs/SAMSUNG_IMS.md).
 */
public final class Main {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: Main <key=value[;key=value...]>");
            System.exit(2);
        }
        // AudioSystem.setParameters(String) is hidden; app_process is not
        // subject to the hidden-API policy for apps.
        Method m = Class.forName("android.media.AudioSystem").getMethod("setParameters", String.class);
        int status = (Integer) m.invoke(null, args[0]);
        System.out.println("setParameters(" + args[0] + ") = " + status);
        System.exit(status == 0 ? 0 : 1);
    }
}
