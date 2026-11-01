package com.superkid.military.military_maintenance;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityNodeInfo;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/** Self-targeted test APK; framework-only dependencies, no target-app restart or clipboard. */
public class AuxUiInstrumentation extends Instrumentation {
    private Bundle args;
    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        args = arguments == null ? new Bundle() : arguments;
        start();
    }
    private AccessibilityNodeInfo find(AccessibilityNodeInfo n, String selector) {
        if (n == null) return null;
        String text = n.getText() == null ? "" : n.getText().toString();
        String label = n.getContentDescription() == null ? "" : n.getContentDescription().toString();
        String hint = n.getHintText() == null ? "" : n.getHintText().toString();
        if ("com.superkid.military.military_maintenance".contentEquals(n.getPackageName() == null ? "" : n.getPackageName()) &&
            "android.widget.EditText".contentEquals(n.getClassName() == null ? "" : n.getClassName()) &&
            (text.contains(selector) || label.contains(selector) || hint.contains(selector))) return n;
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo result = find(n.getChild(i), selector);
            if (result != null) return result;
        }
        return null;
    }
    @Override public void onStart() {
        new Thread(() -> {
            Map<String,Object> result = new LinkedHashMap<>();
            result.put("deviceAlias", "NOTE20-AUX-01");
            result.put("role", "태블릿 앱의 AI 실행 성능 측정용 보조 기기");
            result.put("intendedAppFormFactor", "tablet");
            result.put("phoneLayoutFixesInScope", false);
            result.put("rawQuestionsOrImagesLogged", false);
            result.put("serialRecorded", false);
            result.put("operation", "accessibility_set_text");
            result.put("status", "failed");
            String failureCode = "unclassified";
            try {
                String selector = args.getString("selector");
                String value = args.getString("value");
                if (selector == null || value == null || selector.length() > 100 || value.length() > 2000)
                    throw new IllegalArgumentException("invalid_arguments");
                result.put("requestedValueLength", value.length());
                try { getUiAutomation().waitForIdle(500, 5000); } catch (Exception ignored) { }
                long deadline = SystemClock.elapsedRealtime() + 10000;
                AccessibilityNodeInfo target = null;
                while (target == null && SystemClock.elapsedRealtime() < deadline) {
                    target = find(getUiAutomation().getRootInActiveWindow(), selector);
                    if (target == null) SystemClock.sleep(250);
                }
                if (target == null) { failureCode = "field_not_accessible"; throw new IllegalStateException(); }
                target.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SHOW_ON_SCREEN.getId());
                result.put("focusAccepted", target.performAction(AccessibilityNodeInfo.ACTION_FOCUS));
                result.put("clickAccepted", target.performAction(AccessibilityNodeInfo.ACTION_CLICK));
                try { getUiAutomation().waitForIdle(500, 5000); } catch (Exception ignored) { }
                target = find(getUiAutomation().getRootInActiveWindow(), selector);
                if (target == null) { failureCode = "field_changed_after_focus"; throw new IllegalStateException(); }
                Bundle input = new Bundle();
                input.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
                if (!target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, input)) {
                    failureCode = "set_text_rejected"; throw new IllegalStateException();
                }
                // Flutter dispatches the semantics action asynchronously to Dart.
                // An accepted accessibility action is not proof the controller changed.
                SystemClock.sleep(800);
                AccessibilityNodeInfo observed = find(getUiAutomation().getRootInActiveWindow(), selector);
                result.put("observedTextLength", observed == null || observed.getText() == null ? 0 : observed.getText().length());
                if (observed == null || observed.getText() == null || !observed.getText().toString().contains(value)) {
                    failureCode = "text_not_reflected"; throw new IllegalStateException();
                }
                result.put("status", "passed");
                result.put("valueReflected", true);
                result.put("textValueLogged", false);
            } catch (Throwable e) {
                result.put("failureType", e.getClass().getSimpleName());
                result.put("failureCode", failureCode);
            }
            try (FileOutputStream out = new FileOutputStream(new File(getContext().getFilesDir(), "aux-ui-result.json"))) {
                out.write(new JSONObject(result).toString(2).getBytes(StandardCharsets.UTF_8));
            } catch (Throwable ignored) { result.put("resultFileWritten", false); }
            Bundle output = new Bundle();
            output.putString("status", result.get("status").toString());
            if (result.containsKey("failureCode")) output.putString("failureCode", result.get("failureCode").toString());
            if (result.containsKey("failureType")) output.putString("failureType", result.get("failureType").toString());
            finish("passed".equals(result.get("status")) ? Activity.RESULT_OK : Activity.RESULT_CANCELED, output);
        }).start();
    }
}
