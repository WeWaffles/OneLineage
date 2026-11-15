package com.eggdog.oneui;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Runs inside PixelOS. A small floating card with one action: reboot the phone,
 * which comes back up in One UI (PixelOS only runs on top of it).
 */
public class ReturnActivity extends Activity {

    private TextView button;
    private boolean busy;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        int surface = getColor(android.R.color.system_neutral1_800);
        int onSurface = getColor(android.R.color.system_neutral1_50);
        int accent = getColor(android.R.color.system_accent1_200);
        int onAccent = getColor(android.R.color.system_accent1_900);

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(22), dp(22), dp(22), dp(22));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(surface);
        bg.setCornerRadius(dp(28));
        card.setBackground(bg);

        TextView title = new TextView(this);
        title.setText("One UI");
        title.setTextColor(onSurface);
        title.setTextSize(20);
        title.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL));
        card.addView(title);

        button = new TextView(this);
        button.setText("Go back to One UI");
        button.setTextColor(onAccent);
        button.setTextSize(16);
        button.setGravity(Gravity.CENTER);
        button.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL));
        GradientDrawable pill = new GradientDrawable();
        pill.setColor(accent);
        pill.setCornerRadius(dp(26));
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(0x33000000), pill, null));
        button.setClickable(true);
        button.setOnClickListener(v -> goBack());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(260), dp(52));
        lp.topMargin = dp(16);
        card.addView(button, lp);

        setContentView(card);
    }

    private void goBack() {
        if (busy) return;
        busy = true;
        button.setText("Restarting…");
        new Thread(() -> {
            // Privileged system app: reboot with the REBOOT permission, no root.
            try {
                getSystemService(android.os.PowerManager.class).reboot(null);
                return;
            } catch (Throwable ignored) {
                // Not privileged (e.g. sideloaded): fall back to root.
            }
            String err = null;
            try {
                Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", "sync; reboot"});
                if (p.waitFor() != 0) err = "Root was denied";
            } catch (Exception e) {
                err = "Root not available";
            }
            final String msg = err;
            if (msg != null) {
                runOnUiThread(() -> {
                    busy = false;
                    button.setText(msg + " - tap to retry");
                });
            }
        }).start();
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
