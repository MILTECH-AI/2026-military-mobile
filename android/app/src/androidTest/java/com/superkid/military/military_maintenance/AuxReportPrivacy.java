package com.superkid.military.military_maintenance;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Metrics boundary: no raw question, model answer, image, token stream or device serial on disk. */
public final class AuxReportPrivacy {
    private static final Set<String> OMIT = new HashSet<>(Arrays.asList(
        "text", "query", "question", "quote", "prompt", "raw", "rawoutput", "image", "imagepath",
        "imageurl", "imagedata", "imagebytes", "tokenids", "inputids", "serial", "deviceserial",
        "modelpath", "indexpath", "knowledgepath", "metadatapath", "description"
    ));
    private static String digest(String value) {
        try {
            byte[] bytes = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder out = new StringBuilder();
            for (byte b : bytes) out.append(String.format("%02x", b & 255));
            return out.toString();
        } catch (Exception e) { throw new IllegalStateException(); }
    }
    private static Object clean(Object value) {
        if (value instanceof Map) {
            Map<String,Object> out = new LinkedHashMap<>();
            for (Object raw : ((Map<?,?>) value).entrySet()) {
                Map.Entry<?,?> e = (Map.Entry<?,?>) raw;
                String key = String.valueOf(e.getKey());
                String lower = key.toLowerCase(java.util.Locale.ROOT);
                Object item = e.getValue();
                if (OMIT.contains(lower) || lower.equals("error")) {
                    out.put(key + "Omitted", true);
                    if (item instanceof String) out.put(key + "Sha256", digest((String)item));
                } else if ((lower.equals("reason") || lower.equals("trimcommandoutput")) && item instanceof String && !((String)item).matches("[A-Za-z0-9_.:-]{0,120}")) {
                    out.put(key + "Sha256", digest((String)item));
                } else out.put(key, clean(item));
            }
            return out;
        }
        if (value instanceof List) {
            List<Object> out = new ArrayList<>();
            for (Object item : (List<?>) value) out.add(clean(item));
            return out;
        }
        return value;
    }
    @SuppressWarnings("unchecked")
    public static Map<String,Object> report(Map<?,?> input) {
        Map<String,Object> out = (Map<String,Object>) clean(input);
        out.put("deviceAlias", "NOTE20-AUX-01");
        out.put("role", "태블릿 앱의 AI 실행 성능 측정용 보조 기기");
        out.put("intendedAppFormFactor", "tablet");
        out.put("phoneLayoutFixesInScope", false);
        out.put("serialRecorded", false);
        out.put("rawQuestionsOrImagesLogged", false);
        out.put("privacyFilterAppliedBeforeWriting", true);
        return out;
    }
}
