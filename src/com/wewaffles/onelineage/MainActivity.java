package com.wewaffles.onelineage;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.app.LocaleManager;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.LocaleList;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.RadioButton;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {

    public enum Flavor {
        VANILLA,
        GAPPS
    }

    private TextView tvRootStatus;
    private TextView tvOsStatus;
    private TextView tvImageStatus;
    private TextView tvHeaderSubtitle;
    private TextView tvDownloadDesc;
    private TextView tvDownloadProgress;
    private ProgressBar pbDownload;
    private TextView tvConsoleLog;
    private TextView tvLogStatus;
    private ScrollView logScrollView;

    private LinearLayout cardFlavorVanilla;
    private LinearLayout cardFlavorGapps;
    private RadioButton rbVanilla;
    private RadioButton rbGapps;

    private Button btnDownloadLineage;
    private Button btnDeleteLineage;
    private Button btnBootLineage;
    private Button btnReturnOneUI;
    private Button btnBackupLauncher;
    private Button btnRestoreLauncher;
    private Button btnMenu;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object downloadPauseLock = new Object();
    private volatile boolean downloadRunning = false;
    private volatile boolean downloadPauseEnabled = false;
    private volatile boolean downloadPaused = false;
    private String downloadButtonIdleText;
    private int selectedTheme;
    private Palette currentPalette;
    private boolean isRootGranted = false;
    private String suBinary = "su";
    private Flavor selectedFlavor = Flavor.VANILLA;

    @Override
    protected void attachBaseContext(android.content.Context newBase) {
        super.attachBaseContext(applySavedLocale(newBase));
    }

    private static android.content.Context applySavedLocale(android.content.Context context) {
        if (Build.VERSION.SDK_INT >= 33) return context;
        String languageTag = context.getSharedPreferences("onelineage", MODE_PRIVATE)
                .getString("app_language", "");
        if (languageTag.isEmpty()) return context;
        Locale locale = Locale.forLanguageTag(languageTag);
        Locale.setDefault(locale);
        Configuration configuration = new Configuration(context.getResources().getConfiguration());
        configuration.setLocale(locale);
        return context.createConfigurationContext(configuration);
    }

    private static final String STAGE_DIR = "/data/local/tmp/lineage_stage";
    private static final String SYSTEM_RAW = STAGE_DIR + "/system.raw";

    private static final String URL_VANILLA = "https://downloads.sourceforge.net/project/misterztr-gsi/LineageOS/Android%2016/LineageOS-23.2-20260524-VANILLA-EXT4-GSI.7z?use_mirror=autoselect";
    private static final String URL_GAPPS = "https://downloads.sourceforge.net/project/misterztr-gsi/LineageOS/Android%2016/LineageOS-23.2-20260524-GAPPS-EXT4-GSI.7z?use_mirror=autoselect";
    private static final long ESTIMATED_VANILLA_BYTES = 922022276L;
    private static final long ESTIMATED_GAPPS_BYTES = 1167859370L;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        tvRootStatus = findViewById(R.id.tv_root_status);
        tvOsStatus = findViewById(R.id.tv_os_status);
        tvImageStatus = findViewById(R.id.tv_image_status);
        tvHeaderSubtitle = findViewById(R.id.tv_header_subtitle);
        tvDownloadDesc = findViewById(R.id.tv_download_desc);
        tvDownloadProgress = findViewById(R.id.tv_download_progress);
        pbDownload = findViewById(R.id.pb_download);
        tvConsoleLog = findViewById(R.id.tv_console_log);
        logScrollView = findViewById(R.id.log_scroll_view);
        logScrollView.setOnTouchListener((view, event) -> {
            view.getParent().requestDisallowInterceptTouchEvent(true);
            return false;
        });
        tvLogStatus = findViewById(R.id.tv_log_status);

        cardFlavorVanilla = findViewById(R.id.card_flavor_vanilla);
        cardFlavorGapps = findViewById(R.id.card_flavor_gapps);
        rbVanilla = findViewById(R.id.rb_vanilla);
        rbGapps = findViewById(R.id.rb_gapps);

        btnDownloadLineage = findViewById(R.id.btn_download_lineage);
        btnDeleteLineage = findViewById(R.id.btn_delete_lineage);
        btnBootLineage = findViewById(R.id.btn_boot_lineage);
        btnReturnOneUI = findViewById(R.id.btn_return_oneui);
        btnBackupLauncher = findViewById(R.id.btn_backup_launcher);
        btnRestoreLauncher = findViewById(R.id.btn_restore_launcher);
        btnMenu = findViewById(R.id.btn_menu);
        downloadButtonIdleText = getString(R.string.btn_download_lineage);

        setupFlavorSelection();
        selectedTheme = getSharedPreferences("onelineage", MODE_PRIVATE).getInt("color_theme", 0);
        if (selectedTheme < 0 || selectedTheme > 3) selectedTheme = 0;
        applyTheme();
        extractAssets();
        checkRootAndSystem();

        btnDownloadLineage.setOnClickListener(v -> downloadLineage());
        btnDeleteLineage.setOnClickListener(v -> confirmDeleteLineage());
        btnBootLineage.setOnClickListener(v -> bootLineage());
        btnReturnOneUI.setOnClickListener(v -> returnToOneUI());
        btnBackupLauncher.setOnClickListener(v -> backupLauncher());
        btnRestoreLauncher.setOnClickListener(v -> restoreLauncher());
        btnMenu.setOnClickListener(v -> showPreferencesDrawer());
    }

    @Override
    protected void onResume() {
        super.onResume();
        checkRootAndSystem();
    }

    private void setupFlavorSelection() {
        View.OnClickListener clickVanilla = v -> selectFlavor(Flavor.VANILLA);
        View.OnClickListener clickGapps = v -> selectFlavor(Flavor.GAPPS);

        cardFlavorVanilla.setOnClickListener(clickVanilla);
        cardFlavorGapps.setOnClickListener(clickGapps);

        selectFlavor(Flavor.GAPPS);
    }

    private void selectFlavor(Flavor flavor) {
        selectedFlavor = flavor;
        rbVanilla.setChecked(flavor == Flavor.VANILLA);
        rbGapps.setChecked(flavor == Flavor.GAPPS);

        cardFlavorVanilla.setBackgroundResource(flavor == Flavor.VANILLA ? R.drawable.radio_item_selected : R.drawable.radio_item_unselected);
        cardFlavorGapps.setBackgroundResource(flavor == Flavor.GAPPS ? R.drawable.radio_item_selected : R.drawable.radio_item_unselected);

        switch (flavor) {
            case VANILLA:
                tvDownloadDesc.setText(R.string.flavor_desc_vanilla);
                break;
            case GAPPS:
                tvDownloadDesc.setText(R.string.flavor_desc_gapps);
                break;
        }
        if (currentPalette != null) applyFlavorCardTheme();
    }

    private void showPreferencesDrawer() {
        Palette palette = currentPalette;
        Dialog dialog = new Dialog(this);
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(24), dp(32), dp(20), dp(20));
        panel.setBackground(roundDrawerBackground(palette));

        TextView title = drawerText(getString(R.string.settings_title), 24, palette.textPrimary, true);
        panel.addView(title, drawerParams(-1, -2));
        TextView subtitle = drawerText(getString(R.string.settings_subtitle), 14, palette.textSecondary, false);
        LinearLayout.LayoutParams subtitleParams = drawerParams(-1, -2);
        subtitleParams.topMargin = dp(4);
        panel.addView(subtitle, subtitleParams);

        ScrollView content = new ScrollView(this);
        content.setFillViewport(false);
        LinearLayout choices = new LinearLayout(this);
        choices.setOrientation(LinearLayout.VERTICAL);
        TextView languageLabel = drawerSectionTitle(getString(R.string.language_title), palette);
        choices.addView(languageLabel, drawerParams(-1, -2));
        int selectedLanguage = currentLanguageIndex();
        addDrawerChoice(choices, getString(R.string.language_english), selectedLanguage == 0,
                null, palette, () -> changeLanguage("en", dialog));
        addDrawerChoice(choices, getString(R.string.language_portuguese_brazil), selectedLanguage == 1,
                null, palette, () -> changeLanguage("pt-BR", dialog));

        TextView themeLabel = drawerSectionTitle(getString(R.string.theme_title), palette);
        LinearLayout.LayoutParams themeLabelParams = drawerParams(-1, -2);
        themeLabelParams.topMargin = dp(22);
        choices.addView(themeLabel, themeLabelParams);
        String[] themeNames = getResources().getStringArray(R.array.theme_names);
        for (int i = 0; i < themeNames.length; i++) {
            final int themeIndex = i;
            addDrawerChoice(choices, themeNames[i], selectedTheme == i,
                    Palette.forTheme(i).accent, palette, () -> {
                        selectedTheme = themeIndex;
                        getSharedPreferences("onelineage", MODE_PRIVATE).edit()
                                .putInt("color_theme", selectedTheme).apply();
                        applyTheme();
                        dialog.dismiss();
                        showPreferencesDrawer();
                    });
        }
        content.addView(choices);
        LinearLayout.LayoutParams contentParams = drawerParams(-1, 0);
        contentParams.weight = 1;
        contentParams.topMargin = dp(16);
        panel.addView(content, contentParams);

        TextView close = drawerText(getString(R.string.dialog_cancel), 14, palette.accent, true);
        close.setGravity(Gravity.CENTER);
        close.setBackground(rippleDrawable(palette.raisedSurface, palette.accentRipple, 24));
        close.setOnClickListener(v -> dialog.dismiss());
        LinearLayout.LayoutParams closeParams = drawerParams(-1, dp(48));
        closeParams.topMargin = dp(12);
        panel.addView(close, closeParams);

        dialog.setContentView(panel);
        Window window = dialog.getWindow();
        if (window != null) {
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams attributes = window.getAttributes();
            attributes.gravity = Gravity.START | Gravity.TOP;
            attributes.width = Math.min(dp(360), getResources().getDisplayMetrics().widthPixels - dp(40));
            attributes.height = WindowManager.LayoutParams.MATCH_PARENT;
            attributes.dimAmount = 0.38f;
            window.setAttributes(attributes);
        }
        dialog.show();
        if (window != null) {
            window.setLayout(Math.min(dp(360), getResources().getDisplayMetrics().widthPixels - dp(40)),
                    WindowManager.LayoutParams.MATCH_PARENT);
        }
    }

    private void addDrawerChoice(LinearLayout parent, String label, boolean selected, Integer swatch,
                                 Palette palette, Runnable action) {
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(dp(14), 0, dp(14), 0);
        row.setBackground(rippleDrawable(selected ? palette.primarySurface : palette.raisedSurface,
                palette.accentRipple, 18));
        row.setClickable(true);
        row.setFocusable(true);
        if (swatch != null) {
            View colorDot = new View(this);
            GradientDrawable dot = new GradientDrawable();
            dot.setShape(GradientDrawable.OVAL);
            dot.setColor(swatch);
            colorDot.setBackground(dot);
            LinearLayout.LayoutParams dotParams = drawerParams(dp(16), dp(16));
            dotParams.setMarginEnd(dp(12));
            row.addView(colorDot, dotParams);
        }
        TextView text = drawerText(label, 15, palette.textPrimary, selected);
        row.addView(text, new LinearLayout.LayoutParams(0, -2, 1));
        TextView check = drawerText(selected ? "✓" : "", 18, palette.accent, true);
        check.setGravity(Gravity.CENTER);
        row.addView(check, drawerParams(dp(28), dp(28)));
        row.setOnClickListener(v -> action.run());
        LinearLayout.LayoutParams params = drawerParams(-1, dp(52));
        params.topMargin = dp(6);
        parent.addView(row, params);
    }

    private void changeLanguage(String languageTag, Dialog dialog) {
        getSharedPreferences("onelineage", MODE_PRIVATE).edit()
                .putString("app_language", languageTag).apply();
        dialog.dismiss();
        if (Build.VERSION.SDK_INT >= 33) {
            LocaleManager localeManager = getSystemService(LocaleManager.class);
            if (localeManager != null) {
                localeManager.setApplicationLocales(LocaleList.forLanguageTags(languageTag));
            }
        } else {
            recreate();
        }
    }

    private int currentLanguageIndex() {
        Locale current = getResources().getConfiguration().getLocales().get(0);
        return "pt".equalsIgnoreCase(current.getLanguage()) ? 1 : 0;
    }

    private TextView drawerSectionTitle(String text, Palette palette) {
        TextView view = drawerText(text, 13, palette.accent, true);
        view.setPadding(dp(4), 0, 0, 0);
        return view;
    }

    private TextView drawerText(String text, int sizeSp, int color, boolean medium) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(sizeSp);
        view.setTextColor(color);
        view.setTypeface(android.graphics.Typeface.create(
                medium ? "sans-serif-medium" : "sans-serif",
                android.graphics.Typeface.NORMAL));
        return view;
    }

    private LinearLayout.LayoutParams drawerParams(int width, int height) {
        return new LinearLayout.LayoutParams(width, height);
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    private GradientDrawable roundDrawerBackground(Palette palette) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(palette.surface);
        background.setCornerRadii(new float[]{0, 0, dp(28), dp(28), dp(28), dp(28), 0, 0});
        return background;
    }

    private RippleDrawable rippleDrawable(int fill, int ripple, int radiusDp) {
        return new RippleDrawable(ColorStateList.valueOf(ripple),
                roundDrawable(fill, Color.TRANSPARENT, radiusDp), null);
    }

    private void applyTheme() {
        currentPalette = Palette.forTheme(selectedTheme);
        Palette palette = currentPalette;

        findViewById(R.id.root_scroll_view).setBackgroundColor(palette.background);
        getWindow().setStatusBarColor(palette.background);
        getWindow().setNavigationBarColor(palette.background);

        int[] cardIds = {
                R.id.card_system_status, R.id.card_switch_actions,
                R.id.card_image_management, R.id.card_launcher_safety, R.id.card_operation_log
        };
        for (int id : cardIds) {
            View card = findViewById(id);
            if (card != null) card.setBackground(roundDrawable(palette.surface, palette.outline, 24));
        }

        setThemedButton(btnBootLineage, palette.primary, palette.onPrimary, palette.primary);
        setThemedButton(btnReturnOneUI, palette.raisedSurface, palette.textPrimary, palette.accentRipple);
        setThemedButton(btnDownloadLineage, palette.raisedSurface, palette.accent, palette.accentRipple);
        setThemedButton(btnDeleteLineage, palette.errorSurface, palette.error, palette.error);
        setThemedButton(btnBackupLauncher, palette.raisedSurface, palette.textPrimary, palette.accentRipple);
        setThemedButton(btnRestoreLauncher, palette.raisedSurface, palette.textPrimary, palette.accentRipple);
        setThemedButton(btnMenu, palette.raisedSurface, palette.textPrimary, palette.accentRipple);

        logScrollView.setBackground(roundDrawable(palette.logBackground, palette.outline, 16));
        pbDownload.setProgressTintList(ColorStateList.valueOf(palette.accent));
        pbDownload.setIndeterminateTintList(ColorStateList.valueOf(palette.accent));
        applyTextPalette(findViewById(R.id.root_scroll_view), palette);
        applyFlavorCardTheme();
    }

    private void applyTextPalette(View view, Palette palette) {
        if (view instanceof TextView && !(view instanceof Button)) {
            TextView textView = (TextView) view;
            Object role = textView.getTag();
            if (role == null) {
                int color = textView.getCurrentTextColor();
                if (color == getColor(R.color.m3_primary)) role = "accent";
                else if (color == getColor(R.color.m3_text_primary)) role = "primary";
                else if (color == getColor(R.color.m3_text_secondary)) role = "secondary";
                else if (color == getColor(R.color.m3_text_tertiary)) role = "tertiary";
                else if (color == getColor(R.color.m3_error)) role = "error";
                else if (color == getColor(R.color.m3_log_text)) role = "log";
                else if (color == getColor(R.color.m3_on_primary)) role = "onPrimary";
                if (role != null) textView.setTag(role);
            }

            if ("accent".equals(role)) textView.setTextColor(palette.accent);
            else if ("primary".equals(role)) textView.setTextColor(palette.textPrimary);
            else if ("secondary".equals(role)) textView.setTextColor(palette.textSecondary);
            else if ("tertiary".equals(role)) textView.setTextColor(palette.textTertiary);
            else if ("error".equals(role)) textView.setTextColor(palette.error);
            else if ("log".equals(role)) textView.setTextColor(palette.logText);
            else if ("onPrimary".equals(role)) textView.setTextColor(palette.onPrimary);
        }

        if (view instanceof android.view.ViewGroup) {
            android.view.ViewGroup group = (android.view.ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                applyTextPalette(group.getChildAt(i), palette);
            }
        }
    }

    private void setSemanticTextColor(TextView view, int color) {
        view.setTag("semantic");
        view.setTextColor(color);
    }

    private void applyFlavorCardTheme() {
        if (currentPalette == null) return;
        setFlavorCardTheme(cardFlavorVanilla, selectedFlavor == Flavor.VANILLA);
        setFlavorCardTheme(cardFlavorGapps, selectedFlavor == Flavor.GAPPS);
        ColorStateList tint = ColorStateList.valueOf(currentPalette.accent);
        rbVanilla.setButtonTintList(tint);
        rbGapps.setButtonTintList(tint);
    }

    private void setFlavorCardTheme(View card, boolean selected) {
        int fill = selected ? currentPalette.primarySurface : currentPalette.raisedSurface;
        int stroke = selected ? currentPalette.accent : currentPalette.outline;
        card.setBackground(roundDrawable(fill, stroke, 16));
    }

    private void setThemedButton(Button button, int fill, int text, int ripple) {
        GradientDrawable shape = roundDrawable(fill, Color.TRANSPARENT, 28);
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(ripple), shape, null));
        button.setTextColor(text);
    }

    private GradientDrawable roundDrawable(int fill, int stroke, int radiusDp) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(radiusDp * getResources().getDisplayMetrics().density);
        if (stroke != Color.TRANSPARENT) {
            drawable.setStroke(Math.max(1, (int) getResources().getDisplayMetrics().density), stroke);
        }
        return drawable;
    }

    private static class Palette {
        final int background, surface, raisedSurface, primary, onPrimary, primarySurface;
        final int accent, accentRipple, textPrimary, textSecondary, textTertiary;
        final int error, errorSurface, outline, logBackground, logText;

        Palette(String background, String surface, String raisedSurface, String primary,
                String onPrimary, String primarySurface, String accent, String accentRipple,
                String textPrimary, String textSecondary, String textTertiary,
                String error, String errorSurface, String outline, String logBackground, String logText) {
            this.background = Color.parseColor(background);
            this.surface = Color.parseColor(surface);
            this.raisedSurface = Color.parseColor(raisedSurface);
            this.primary = Color.parseColor(primary);
            this.onPrimary = Color.parseColor(onPrimary);
            this.primarySurface = Color.parseColor(primarySurface);
            this.accent = Color.parseColor(accent);
            this.accentRipple = Color.parseColor(accentRipple);
            this.textPrimary = Color.parseColor(textPrimary);
            this.textSecondary = Color.parseColor(textSecondary);
            this.textTertiary = Color.parseColor(textTertiary);
            this.error = Color.parseColor(error);
            this.errorSurface = Color.parseColor(errorSurface);
            this.outline = Color.parseColor(outline);
            this.logBackground = Color.parseColor(logBackground);
            this.logText = Color.parseColor(logText);
        }

        static Palette forTheme(int theme) {
            switch (theme) {
                case 1:
                    return new Palette("#071820", "#0D2630", "#143641", "#83E7E8",
                            "#00363B", "#0B4850", "#83E7E8", "#386D72", "#E1F7F7",
                            "#A3CACE", "#6F969A", "#FFB4AB", "#4A2528", "#31525A",
                            "#06141A", "#C4E2E4");
                case 2:
                    return new Palette("#17131F", "#251D30", "#30263E", "#D0BCFF",
                            "#381E72", "#4A326C", "#D0BCFF", "#735A99", "#F1EAF7",
                            "#C9BFD4", "#90869B", "#FFB4AB", "#4A2537", "#51445D",
                            "#120F18", "#D8CEE3");
                case 3:
                    return new Palette("#000000", "#0A0A0A", "#151515", "#80DEEA",
                            "#00363F", "#063B42", "#80DEEA", "#28585F", "#F5F5F5",
                            "#B0BEC5", "#777777", "#FFB4AB", "#351719", "#333333",
                            "#000000", "#E0E0E0");
                default:
                    return new Palette("#111318", "#212329", "#2B2E35", "#A8C7FA",
                            "#062E6F", "#1A437E", "#A8C7FA", "#425B7F", "#E2E2E6",
                            "#9DA3AE", "#73777F", "#FFB4AB", "#411215", "#44474F",
                            "#141519", "#C4C7C5");
            }
        }
    }

    private void appendLog(final String text) {
        mainHandler.post(() -> {
            if (tvConsoleLog != null) {
                boolean wasAtBottom = logScrollView == null ||
                        logScrollView.getChildAt(0).getBottom() - logScrollView.getScrollY()
                                <= logScrollView.getHeight() + 16;
                tvConsoleLog.append(text + "\n");
                if (wasAtBottom && logScrollView != null) {
                    logScrollView.post(() -> logScrollView.fullScroll(View.FOCUS_DOWN));
                }
            }
        });
    }

    // Runs a root shell command with stdout+stderr merged and continuously drained.
    // Process.waitFor() deadlocks forever if the child fills its stdout/stderr pipe
    // (~64KB) without anyone reading it - e.g. "rm -rf" spewing a "Device or resource
    // busy" line per file when rootfs still has stale bind/loop mounts underneath it.
    private int runRootCmdDrained(String cmd) {
        try {
            ProcessBuilder pb = new ProcessBuilder(suBinary, "-c", cmd);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
            while (reader.readLine() != null) {
                // drain only; callers that need the output use their own reader.
            }
            return p.waitFor();
        } catch (Exception e) {
            return -1;
        }
    }

    private void setLogStatus(final String status) {
        mainHandler.post(() -> {
            if (tvLogStatus != null) {
                tvLogStatus.setText(status);
            }
        });
    }

    private void checkRootAndSystem() {
        executor.execute(() -> {
            // Attempt auto-activation of ksud if present
            try {
                File dfKsud = new File("/data/user_de/0/df.root/ksud");
                if (dfKsud.exists() && dfKsud.canExecute()) {
                    Runtime.getRuntime().exec(new String[]{dfKsud.getAbsolutePath(), "install"}).waitFor();
                }
            } catch (Exception ignored) {}

            String[] candidatePaths = {"/system/bin/su", "/data/adb/ksu/bin/su", "/system/xbin/su", "su"};
            boolean foundRoot = false;

            for (String path : candidatePaths) {
                try {
                    Process p = Runtime.getRuntime().exec(new String[]{path, "-c", "id"});
                    BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line = reader.readLine();
                    int exitCode = p.waitFor();

                    if (exitCode == 0 && line != null && line.contains("uid=0")) {
                        foundRoot = true;
                        suBinary = path;
                        break;
                    }
                } catch (Exception ignored) {}
            }

            isRootGranted = foundRoot;
            if (isRootGranted) {
                extractAssets();
            }
            mainHandler.post(() -> {
                if (isRootGranted) {
                    tvRootStatus.setText(R.string.status_root_active_detail);
                    setSemanticTextColor(tvRootStatus, Color.parseColor("#A5D6A7"));
                } else {
                    tvRootStatus.setText(R.string.status_root_denied_detail);
                    setSemanticTextColor(tvRootStatus, Color.parseColor("#FFB4AB"));
                }
            });

            // Check active userspace
            try {
                Process pOs = Runtime.getRuntime().exec(new String[]{suBinary, "-c", "getprop ro.lineage.version"});
                BufferedReader osReader = new BufferedReader(new InputStreamReader(pOs.getInputStream()));
                String osVer = osReader.readLine();
                pOs.waitFor();

                mainHandler.post(() -> {
                    if (osVer != null && !osVer.trim().isEmpty()) {
                        tvOsStatus.setText(getString(R.string.status_userspace_lineage, osVer.trim()));
                        setSemanticTextColor(tvOsStatus, Color.parseColor("#78D9EC"));
                        if (tvHeaderSubtitle != null) {
                            tvHeaderSubtitle.setText(R.string.header_subtitle_lineage);
                        }
                    } else {
                        tvOsStatus.setText(R.string.status_userspace_oneui);
                        setSemanticTextColor(tvOsStatus, Color.parseColor("#FFD54F"));
                        if (tvHeaderSubtitle != null) {
                            tvHeaderSubtitle.setText(R.string.header_subtitle_oneui);
                        }
                    }
                });
            } catch (Exception e) {
                mainHandler.post(() -> {
                    tvOsStatus.setText(R.string.status_userspace_oneui_short);
                    setSemanticTextColor(tvOsStatus, Color.parseColor("#FFD54F"));
                });
            }

            checkImageStatus();
        });
    }

    private void checkImageStatus() {
        executor.execute(() -> {
            try {
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", "[ -f " + SYSTEM_RAW + " ] && ls -lh " + SYSTEM_RAW + " || echo 'MISSING'"});
                BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String out = reader.readLine();
                p.waitFor();

                mainHandler.post(() -> {
                    if (out != null && !out.contains("MISSING") && !out.trim().isEmpty()) {
                        tvImageStatus.setText(getString(R.string.status_image_installed,
                                out.trim().replaceAll("\\s+", " ")));
                        setSemanticTextColor(tvImageStatus, Color.parseColor("#A5D6A7"));
                        downloadButtonIdleText = getString(R.string.btn_download_reinstall);
                        if (!downloadRunning) btnDownloadLineage.setText(downloadButtonIdleText);
                        btnBootLineage.setEnabled(true);
                        btnBootLineage.setAlpha(1.0f);
                    } else {
                        tvImageStatus.setText(R.string.status_image_missing);
                        setSemanticTextColor(tvImageStatus, Color.parseColor("#FFB4AB"));
                        downloadButtonIdleText = getString(R.string.btn_download_lineage);
                        if (!downloadRunning) btnDownloadLineage.setText(downloadButtonIdleText);
                        btnBootLineage.setEnabled(false);
                        btnBootLineage.setAlpha(0.5f);
                    }
                });
            } catch (Exception e) {
                mainHandler.post(() -> {
                    tvImageStatus.setText(getString(R.string.status_image_error, e.getMessage()));
                    setSemanticTextColor(tvImageStatus, Color.parseColor("#FFB4AB"));
                });
            }
        });
    }

    private void extractAssets() {
        executor.execute(() -> {
            String[] assets = {
                "switch_to_lineage.sh", "return_to_oneui.sh",
                "master_prepare.sh", "master_inner.sh",
                "zygote_exec", "clean_apex_info_list.xml",
                "services_patched.jar", "framework_patched.jar",
                "7zz", "PermissionController_patched.apk"
            };
            File filesDir = getFilesDir();
            for (String asset : assets) {
                File target = new File(filesDir, asset);
                if (target.exists() && target.length() > 0 && asset.endsWith(".jar")) {
                    continue; // Skip re-extracting large jars if already present
                }
                try (InputStream in = getAssets().open(asset);
                     OutputStream out = new FileOutputStream(target)) {
                    byte[] buffer = new byte[32768];
                    int read;
                    while ((read = in.read(buffer)) != -1) {
                        out.write(buffer, 0, read);
                    }
                    target.setExecutable(true, false);
                    target.setReadable(true, false);
                } catch (Exception e) {
                    appendLog(getString(R.string.log_root_error_unpacking, asset, e.getMessage()));
                }
            }
            if (isRootGranted) {
                try {
                    Runtime.getRuntime().exec(new String[]{
                        suBinary, "-c",
                        "mkdir -p " + STAGE_DIR + " && " +
                        "for f in " + filesDir.getAbsolutePath() + "/*; do " +
                        "  base=$(basename \"$f\"); " +
                        "  cp -f \"$f\" \"" + STAGE_DIR + "/$base\"; " +
                        "done && " +
                        "cp -f " + filesDir.getAbsolutePath() + "/7zz /data/local/tmp/7zz 2>/dev/null; " +
                        "chmod 755 " + STAGE_DIR + "/*.sh " + STAGE_DIR + "/zygote_exec " + STAGE_DIR + "/7zz /data/local/tmp/7zz 2>/dev/null"
                    }).waitFor();
                } catch (Exception ignored) {}
            }
            appendLog(getString(R.string.log_assets_ready));
        });
    }

    private void downloadLineage() {
        if (downloadRunning) {
            if (downloadPauseEnabled) toggleDownloadPause();
            return;
        }
        if (!isRootGranted) {
            appendLog(getString(R.string.log_root_required_setup));
            return;
        }
        startNetworkDownload(selectedFlavor);
    }

    private void toggleDownloadPause() {
        synchronized (downloadPauseLock) {
            downloadPaused = !downloadPaused;
            if (!downloadPaused) downloadPauseLock.notifyAll();
        }

        final boolean paused = downloadPaused;
        mainHandler.post(() -> {
            btnDownloadLineage.setText(paused ? R.string.btn_resume_download : R.string.btn_pause_download);
            tvDownloadProgress.setText(paused
            ? getString(R.string.progress_download_paused)
                    : getString(R.string.progress_download_resuming));
        });
        setLogStatus(getString(paused ? R.string.status_paused : R.string.status_downloading));
        appendLog(getString(paused ? R.string.log_download_paused : R.string.log_download_resumed));
    }

    private void waitWhileDownloadPaused() throws Exception {
        synchronized (downloadPauseLock) {
            while (downloadPaused) {
                try {
                    downloadPauseLock.wait();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new Exception("Download interrupted while paused", e);
                }
            }
        }
    }

    private void downloadFileWithRedirects(String initialUrl, File targetFile, long expectedBytes) throws Exception {
        String currentUrl = initialUrl;
        HttpURLConnection conn = null;
        int redirectCount = 0;
        final int MAX_REDIRECTS = 10;

        while (redirectCount < MAX_REDIRECTS) {
            URL url = new URL(currentUrl);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestProperty("User-Agent", "Wget/1.21.3");
            conn.setRequestProperty("Accept", "*/*");
            conn.setConnectTimeout(25000);
            conn.setReadTimeout(30000);
            conn.setInstanceFollowRedirects(false);

            int code = conn.getResponseCode();
            if (code == HttpURLConnection.HTTP_MOVED_PERM ||
                code == HttpURLConnection.HTTP_MOVED_TEMP ||
                code == HttpURLConnection.HTTP_SEE_OTHER ||
                code == 307 || code == 308) {

                String loc = conn.getHeaderField("Location");
                if (loc == null || loc.trim().isEmpty()) {
                    throw new Exception("Redirect code " + code + " without Location header");
                }
                currentUrl = loc.trim();
                conn.disconnect();
                redirectCount++;
                appendLog(getString(R.string.log_redirect, redirectCount));
                continue;
            }

            if (code != HttpURLConnection.HTTP_OK) {
                throw new Exception("HTTP server error code: " + code);
            }

            break;
        }

        if (redirectCount >= MAX_REDIRECTS || conn == null) {
            throw new Exception("Too many redirects: " + redirectCount);
        }

        long contentLength = -1;
        try {
            contentLength = Long.parseLong(conn.getHeaderField("Content-Length"));
        } catch (Exception ignored) {}
        final long totalBytes = (contentLength > 0) ? contentLength : expectedBytes;

        mainHandler.post(() -> {
            pbDownload.setMax(100);
            pbDownload.setProgress(0);
        });

        long startMs = System.currentTimeMillis();
        long lastUpdateMs = 0;
        long currentBytes = 0;

        try (InputStream in = conn.getInputStream();
             OutputStream out = new FileOutputStream(targetFile)) {

            byte[] buffer = new byte[65536];
            int read;
            while (true) {
                waitWhileDownloadPaused();
                read = in.read(buffer);
                if (read == -1) break;
                out.write(buffer, 0, read);
                currentBytes += read;

                long now = System.currentTimeMillis();
                if (now - lastUpdateMs > 250) {
                    lastUpdateMs = now;
                    final int pct = (totalBytes > 0) ? (int) Math.min(100, (currentBytes * 100) / totalBytes) : 0;
                    final long elapsedSec = Math.max(1, (now - startMs) / 1000);
                    final double speedMb = (currentBytes / 1048576.0) / elapsedSec;
                    final String progStr = getString(R.string.progress_downloading,
                            currentBytes / 1048576, totalBytes / 1048576, pct, speedMb);
                    if (!downloadPaused) {
                        mainHandler.post(() -> {
                            pbDownload.setProgress(pct);
                            tvDownloadProgress.setText(progStr);
                        });
                    }
                }
            }
            out.flush();
        } finally {
            conn.disconnect();
        }

        if (targetFile.length() < 1000000) {
            throw new Exception("Downloaded file is too small (" + targetFile.length() + " bytes).");
        }
    }

    private void startNetworkDownload(final Flavor flavor) {
        if (downloadRunning) return;
        downloadRunning = true;
        downloadPaused = false;
        downloadPauseEnabled = false;
        executor.execute(() -> {
            setLogStatus(getString(R.string.status_preparing));
            mainHandler.post(() -> {
                pbDownload.setVisibility(View.VISIBLE);
                pbDownload.setIndeterminate(false);
                pbDownload.setProgress(0);
                tvDownloadProgress.setVisibility(View.VISIBLE);
                tvDownloadProgress.setText(R.string.progress_connecting);
                btnDownloadLineage.setText(R.string.btn_preparing);
                btnDownloadLineage.setEnabled(false);
            });

            appendLog(getString(R.string.log_setup_start, STAGE_DIR));
            try {
                runRootCmdDrained("mkdir -p " + STAGE_DIR + " && chmod 777 " + STAGE_DIR);
                appendLog(getString(R.string.log_wiping_userdata));
                runRootCmdDrained(wipeUserDataCmd());

                String downloadUrl = (flavor == Flavor.GAPPS) ? URL_GAPPS : URL_VANILLA;
                final long totalBytes = (flavor == Flavor.GAPPS) ? ESTIMATED_GAPPS_BYTES : ESTIMATED_VANILLA_BYTES;
                // Download into the app's own cache dir, NOT STAGE_DIR directly: this
                // process writes as the unprivileged app, and /data/local/tmp paths
                // created by root are labeled shell_data_file, which SELinux blocks
                // untrusted_app from writing to no matter what chmod says (this is the
                // actual cause of "lineage_dl.7z: open failed: EACCES"). su (used below
                // for extraction) can read the app's cache dir fine, same as
                // extractAssets() already does for the other staged files.
                final File targetArchive = new File(getCacheDir(), "lineage_dl.7z");

                appendLog(getString(R.string.log_network_fetch, flavor.name()));
                appendLog(getString(R.string.log_url, downloadUrl));
                setLogStatus(getString(R.string.status_downloading));
                downloadPauseEnabled = true;
                mainHandler.post(() -> {
                    btnDownloadLineage.setText(R.string.btn_pause_download);
                    btnDownloadLineage.setEnabled(true);
                });

                downloadFileWithRedirects(downloadUrl, targetArchive, totalBytes);
                downloadPauseEnabled = false;
                synchronized (downloadPauseLock) {
                    downloadPaused = false;
                    downloadPauseLock.notifyAll();
                }

                appendLog(getString(R.string.log_download_complete, targetArchive.length() / 1048576));
                setLogStatus(getString(R.string.status_extracting));
                mainHandler.post(() -> {
                    pbDownload.setIndeterminate(true);
                    tvDownloadProgress.setText(R.string.progress_extracting);
                    btnDownloadLineage.setText(R.string.btn_installing);
                    btnDownloadLineage.setEnabled(false);
                });

                appendLog(getString(R.string.log_extracting_archive, targetArchive.getAbsolutePath()));
                String extractCmd = "rm -f " + STAGE_DIR + "/*.img " + SYSTEM_RAW + "; " +
                                   STAGE_DIR + "/7zz x -y -o" + STAGE_DIR + " " + targetArchive.getAbsolutePath() + " && " +
                                   "mv -f " + STAGE_DIR + "/*.img " + SYSTEM_RAW + " && " +
                                   "rm -f " + targetArchive.getAbsolutePath() + " && chmod 644 " + SYSTEM_RAW;
                int extRet = runRootCmdDrained(extractCmd);
                if (extRet != 0 || !new File(SYSTEM_RAW).exists()) {
                    throw new Exception(getString(R.string.log_extract_failed, extRet));
                }

                appendLog(getString(R.string.log_extract_complete));

                mainHandler.post(() -> {
                    pbDownload.setVisibility(View.GONE);
                    tvDownloadProgress.setText(getString(R.string.progress_installed, flavor.name()));
                });
                setLogStatus(getString(R.string.status_ready));
                checkImageStatus();

            } catch (Exception e) {
                appendLog(getString(R.string.log_setup_failed, e.getMessage()));
                setLogStatus(getString(R.string.status_error));
                mainHandler.post(() -> {
                    pbDownload.setVisibility(View.GONE);
                    tvDownloadProgress.setText(getString(R.string.progress_setup_failed, e.getMessage()));
                });
            } finally {
                downloadPauseEnabled = false;
                synchronized (downloadPauseLock) {
                    downloadPaused = false;
                    downloadPauseLock.notifyAll();
                }
                downloadRunning = false;
                mainHandler.post(() -> {
                    btnDownloadLineage.setText(downloadButtonIdleText);
                    btnDownloadLineage.setEnabled(true);
                });
            }
        });
    }

    // Unmounts the container rootfs and detaches any loop device backed by a file
    // under STAGE_DIR. Bounded retry loop (not an unbounded "while mount|grep" loop)
    // so it can never hang forever, and retries losetup -d once since EBUSY is often
    // transient right after pkill -9 (kernel hasn't finished releasing the dying
    // container's private mount namespace yet).
    private String containerUnmountCmd() {
        String rootfs = STAGE_DIR + "/rootfs";
        return "BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox); " +
               "[ -x \"$BB\" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1); " +
               "umount -l " + rootfs + "/apex/* 2>/dev/null || true; " +
               "umount -l " + rootfs + "/* 2>/dev/null || true; " +
               "umount -l " + rootfs + " 2>/dev/null || true; " +
               "n=0; while [ $n -lt 50 ] && mount | grep -q '" + rootfs + "'; do " +
               "  umount -l " + rootfs + " 2>/dev/null || true; " +
               "  n=$((n+1)); sleep 0.1; " +
               "done; " +
               "if [ -x \"$BB\" ]; then " +
               "  for l in $($BB losetup -a | grep -F '" + STAGE_DIR + "' | cut -d: -f1); do " +
               "    $BB losetup -d \"$l\" 2>/dev/null || { sleep 0.3; $BB losetup -d \"$l\" 2>/dev/null || true; }; " +
               "  done; " +
               "fi";
    }

    private String wipeUserDataCmd() {
        return containerUnmountCmd() + "; " +
               "rm -rf " + STAGE_DIR + "/data " + STAGE_DIR + "/rootfs; mkdir -p " + STAGE_DIR + "/rootfs";
    }

    private void confirmDeleteLineage() {
        new AlertDialog.Builder(this)
            .setTitle(R.string.dialog_delete_title)
            .setMessage(R.string.dialog_delete_message)
            .setPositiveButton(R.string.dialog_delete_confirm, (dialog, which) -> deleteLineage())
            .setNegativeButton(R.string.dialog_cancel, null)
            .show();
    }

    private void deleteLineage() {
        executor.execute(() -> {
            setLogStatus(getString(R.string.status_cleaning));
            appendLog(getString(R.string.log_cleanup_start));
            try {
                // Only kill zygote64/surfaceflinger/vold/system_server by name if the
                // LineageOS container's rootfs is actually mounted. If it isn't (e.g.
                // we're sitting on stock One UI with no switch in progress), those
                // pidof lookups resolve to the HOST's own real daemons - killing them
                // crashes/reboots the device instead of cleaning up a container.
                String cleanupCmd =
                    "if mount | grep -q '" + STAGE_DIR + "/rootfs '; then " +
                    "  pkill -9 -f 'ctl.stop zygote' 2>/dev/null || true; " +
                    "  pkill -9 -f 'ui_activator' 2>/dev/null || true; " +
                    "  pkill -9 -f 'zygote_exec' 2>/dev/null || true; " +
                    "  pkill -9 -f 'system_server' 2>/dev/null || true; " +
                    "  pkill -9 -f org.lineageos 2>/dev/null || true; " +
                    "  pkill -9 -x zygote64 2>/dev/null || true; " +
                    "  kill -9 $(pidof surfaceflinger) 2>/dev/null || true; " +
                    "  kill -9 $(pidof bootanimation) 2>/dev/null || true; " +
                    // Matched by the container's distinctive vold launch flags, never
                    // "pidof vold" bare - that would kill the HOST's real vold too if
                    // both happened to be alive, crashing the device (confirmed live).
                    "  pkill -9 -f 'blkid_context=u:r:blkid:s0' 2>/dev/null || true; " +
                    "  sleep 0.3; " +
                    "fi; " +
                    containerUnmountCmd() + "; " +
                    // If a loop device is still stuck busy (namespace teardown lagging),
                    // truncating frees the backing blocks immediately even though rm -f
                    // alone would leave them held open by that loop device.
                    "truncate -s 0 " + SYSTEM_RAW + " 2>/dev/null || true; " +
                    "rm -f " + SYSTEM_RAW + " " + STAGE_DIR + "/*.img " + STAGE_DIR + "/*.7z " + STAGE_DIR + "/*.img.tmp; " +
                    "rm -rf " + STAGE_DIR + "/data " + STAGE_DIR + "/rootfs; " +
                    "mkdir -p " + STAGE_DIR + "/rootfs; " +
                    "if [ -f " + SYSTEM_RAW + " ]; then echo 'WARNING: system.raw still present!'; else echo 'Container unmounted, data wiped, and storage freed.'; fi";

                Process p = new ProcessBuilder(suBinary, "-c", cleanupCmd).redirectErrorStream(true).start();
                BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                boolean stillPresent = false;
                while ((line = reader.readLine()) != null) {
                    appendLog("  " + line);
                    if (line.contains("WARNING: system.raw still present")) {
                        stillPresent = true;
                    }
                }
                p.waitFor();
                if (stillPresent) {
                    appendLog(getString(R.string.log_cleanup_warning));
                    setLogStatus(getString(R.string.status_error));
                } else {
                    appendLog(getString(R.string.log_cleanup_done));
                    setLogStatus(getString(R.string.status_idle));
                }
                checkImageStatus();
            } catch (Exception e) {
                appendLog(getString(R.string.log_delete_failed, e.getMessage()));
                setLogStatus(getString(R.string.status_error));
            }
        });
    }

    private void bootLineage() {
        if (!isRootGranted) {
            appendLog(getString(R.string.log_root_required_boot));
            return;
        }
        appendLog(getString(R.string.log_boot_start));
        setLogStatus(getString(R.string.status_switching));
        executor.execute(() -> {
            try {
                File filesDir = getFilesDir();
                String syncCmd = "for f in " + filesDir.getAbsolutePath() + "/*; do " +
                                 "  base=$(basename \"$f\"); " +
                                 "  cp -f \"$f\" \"" + STAGE_DIR + "/$base\"; " +
                                 "done && " +
                                 "chmod 755 " + STAGE_DIR + "/*.sh " + STAGE_DIR + "/zygote_exec " + STAGE_DIR + "/7zz";
                Runtime.getRuntime().exec(new String[]{suBinary, "-c", syncCmd}).waitFor();

                String stageScript = STAGE_DIR + "/switch_to_lineage.sh";
                String cmd = "stageScript=" + STAGE_DIR + "/switch_to_lineage.sh; " +
                             "chmod 755 $stageScript; " +
                             "BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox); " +
                             "[ -x \"$BB\" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1); " +
                             "if [ -n \"$BB\" ] && [ -x \"$BB\" ]; then " +
                             "  $BB setsid /system/bin/sh $stageScript </dev/null >" + STAGE_DIR + "/takeover_app.log 2>&1 & " +
                             "else " +
                             "  nohup /system/bin/sh $stageScript </dev/null >" + STAGE_DIR + "/takeover_app.log 2>&1 & " +
                             "fi";
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd});
                p.waitFor();
                appendLog(getString(R.string.log_takeover_spawned));
            } catch (Exception e) {
                appendLog(getString(R.string.log_launch_failed, e.getMessage()));
                setLogStatus(getString(R.string.status_error));
            }
        });
    }

    private void returnToOneUI() {
        if (!isRootGranted) {
            appendLog(getString(R.string.log_root_required_restore));
            return;
        }
        appendLog(getString(R.string.log_return_start));
        setLogStatus(getString(R.string.status_restoring));
        executor.execute(() -> {
            try {
                String stageScript = STAGE_DIR + "/return_to_oneui.sh";
                String cmd = "stageScript=" + STAGE_DIR + "/return_to_oneui.sh; " +
                             "chmod 755 $stageScript; " +
                             "BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox); " +
                             "[ -x \"$BB\" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1); " +
                             "if [ -n \"$BB\" ] && [ -x \"$BB\" ]; then " +
                             "  $BB setsid /system/bin/sh $stageScript </dev/null >" + STAGE_DIR + "/restore_app.log 2>&1 & " +
                             "else " +
                             "  nohup /system/bin/sh $stageScript </dev/null >" + STAGE_DIR + "/restore_app.log 2>&1 & " +
                             "fi";
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd});
                p.waitFor();
                appendLog(getString(R.string.log_restore_triggered));
            } catch (Exception e) {
                appendLog(getString(R.string.log_restore_failed, e.getMessage()));
                setLogStatus(getString(R.string.status_error));
            }
        });
    }

    private void backupLauncher() {
        executor.execute(() -> {
            setLogStatus(getString(R.string.status_backing_up));
            appendLog(getString(R.string.log_backup_start));
            try {
                String cmd = "mkdir -p /data/local/tmp/lineage_backups && " +
                             "cp -a /data/user/0/com.sec.android.app.launcher/databases/* /data/local/tmp/lineage_backups/ 2>/dev/null && " +
                             "ls -la /data/local/tmp/lineage_backups/";
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd});
                BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                while ((line = reader.readLine()) != null) {
                    appendLog("  " + line);
                }
                p.waitFor();
                appendLog(getString(R.string.log_backup_done));
                setLogStatus(getString(R.string.status_idle));
            } catch (Exception e) {
                appendLog(getString(R.string.log_backup_failed, e.getMessage()));
                setLogStatus(getString(R.string.status_error));
            }
        });
    }

    private void restoreLauncher() {
        executor.execute(() -> {
            setLogStatus(getString(R.string.status_restoring));
            appendLog(getString(R.string.log_launcher_restore_start));
            try {
                String cmd = "if [ -d /data/local/tmp/lineage_backups ]; then " +
                             "LAUNCHER_DATA=/data/user/0/com.sec.android.app.launcher; " +
                             "L_UID=$(stat -c %u $LAUNCHER_DATA 2>/dev/null || echo 10160); " +
                             "L_GID=$(stat -c %g $LAUNCHER_DATA 2>/dev/null || echo 10160); " +
                             "cp -a /data/local/tmp/lineage_backups/* $LAUNCHER_DATA/databases/ && " +
                             "chown -R ${L_UID}:${L_GID} $LAUNCHER_DATA/databases && " +
                             "chmod 771 $LAUNCHER_DATA/databases && " +
                             "chmod 660 $LAUNCHER_DATA/databases/* && " +
                             "am force-stop com.sec.android.app.launcher && " +
                             "am start -a android.intent.action.MAIN -c android.intent.category.HOME && " +
                             "echo 'Restored launcher successfully with UID '${L_UID}; else echo 'No backup found!'; fi";
                Process p = Runtime.getRuntime().exec(new String[]{suBinary, "-c", cmd});
                BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line;
                while ((line = reader.readLine()) != null) {
                    appendLog("  " + line);
                }
                p.waitFor();
                setLogStatus(getString(R.string.status_idle));
            } catch (Exception e) {
                appendLog(getString(R.string.log_launcher_restore_failed, e.getMessage()));
                setLogStatus(getString(R.string.status_error));
            }
        });
    }
}
