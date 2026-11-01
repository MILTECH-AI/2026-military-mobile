package com.superkid.military.military_maintenance;

import android.app.Activity;
import android.app.Instrumentation;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.os.Bundle;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/** Counts only; never exports database rows, questions, identifiers or document text. */
public class AuxStoreInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    private long count(SQLiteDatabase db, String query) {
        try (Cursor c = db.rawQuery(query, new String[]{"DEMO-NOTE20-AUX-001"})) {
            if (!c.moveToFirst()) throw new IllegalStateException();
            return c.getLong(0);
        }
    }
    @Override public void onStart() {
        new Thread(() -> {
            Map<String,Object> result = new LinkedHashMap<>();
            result.put("deviceAlias", "NOTE20-AUX-01");
            result.put("role", "태블릿 앱의 AI 실행 성능 측정용 보조 기기");
            result.put("intendedAppFormFactor", "tablet");
            result.put("phoneLayoutFixesInScope", false);
            result.put("serialRecorded", false);
            result.put("rawQuestionsOrImagesLogged", false);
            result.put("readOnly", true);
            result.put("status", "failed");
            File file = new File(getTargetContext().getApplicationInfo().dataDir, "app_flutter/military.sqlite");
            try (SQLiteDatabase db = SQLiteDatabase.openDatabase(file.getPath(), null, SQLiteDatabase.OPEN_READONLY)) {
                result.put("fakeVehicleCount", count(db, "SELECT COUNT(*) FROM vehicles WHERE id=?"));
                result.put("fakeMaintenanceCount", count(db, "SELECT COUNT(*) FROM maintenance WHERE vehicle_id=?"));
                try (Cursor c = db.rawQuery("SELECT value FROM app_metadata WHERE key='maintenance_support'", null)) {
                    if (c.moveToFirst()) {
                        JSONObject lib = new JSONObject(c.getString(0));
                        JSONObject knowledge = lib.optJSONObject("knowledge");
                        result.put("evidenceCount", lib.optJSONArray("evidence") == null ? 0 : lib.getJSONArray("evidence").length());
                        result.put("conceptCount", knowledge == null || knowledge.optJSONArray("concepts") == null ? 0 : knowledge.getJSONArray("concepts").length());
                        result.put("templateCount", knowledge == null || knowledge.optJSONArray("templates") == null ? 0 : knowledge.getJSONArray("templates").length());
                        result.put("pendingCount", knowledge == null || knowledge.optJSONArray("pending") == null ? 0 : knowledge.getJSONArray("pending").length());
                        result.put("ruleCount", lib.optJSONArray("rules") == null ? 0 : lib.getJSONArray("rules").length());
                    } else result.put("supportMetadataPresent", false);
                }
                result.put("status", "passed");
            } catch (Throwable e) { result.put("failureType", e.getClass().getSimpleName()); }
            try (FileOutputStream out = new FileOutputStream(new File(getTargetContext().getFilesDir(), "aux-store-result.json"))) {
                out.write(new JSONObject(result).toString(2).getBytes(StandardCharsets.UTF_8));
            } catch (Exception ignored) { }
            finish("passed".equals(result.get("status")) ? Activity.RESULT_OK : Activity.RESULT_CANCELED,
                new Bundle());
        }).start();
    }
}
