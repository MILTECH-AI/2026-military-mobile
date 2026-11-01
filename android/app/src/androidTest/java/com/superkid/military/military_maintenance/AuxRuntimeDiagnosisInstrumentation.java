package com.superkid.military.military_maintenance;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import org.json.JSONObject;
import org.json.JSONArray;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.ArrayList;
import java.util.Map;

/** Constructor/inference diagnosis only. Not a latency or isolated-worker measurement. */
public class AuxRuntimeDiagnosisInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        new Thread(() -> {
            Map<String,Object> report=new LinkedHashMap<>();
            OnnxEmbeddingSession session=null;
            String phase="construct";
            report.put("purpose", "diagnose_constructor_and_inference_not_performance");
            report.put("productionWorkerPath", false);
            report.put("process64Bit", android.os.Process.is64Bit());
            try {
                session=new OnnxEmbeddingSession(getTargetContext(),2);
                phase="infer";
                // Constant synthetic input, not a source maintenance sentence.
                JSONObject result=new JSONObject(session.infer("{\"text\":\"AUX_RUNTIME_DIAGNOSTIC\",\"diagnostic\":true}"));
                report.put("dimensions", result.getJSONArray("embedding").length());
                phase="infer_first_parity_input";
                File probes=new File(getTargetContext().getFilesDir(),"rag-probes.json");
                String probeText=new String(java.nio.file.Files.readAllBytes(probes.toPath()),StandardCharsets.UTF_8);
                JSONObject first=new JSONArray(probeText).getJSONObject(0);
                JSONObject parityResult=new JSONObject(session.infer(new JSONObject().put("text",first.getString("text")).put("diagnostic",true).toString()));
                report.put("firstParityInputDimensions",parityResult.getJSONArray("embedding").length());
                report.put("firstParityInputTokens",parityResult.getJSONArray("tokenIds").length());
                report.put("status", "passed");
            } catch(Throwable failure) {
                report.put("status", "failed"); report.put("failurePhase", phase);
                ArrayList<Object> chain=new ArrayList<>();
                for(Throwable e=failure;e!=null && chain.size()<6;e=e.getCause()) {
                    Map<String,Object> item=new LinkedHashMap<>();
                    item.put("exceptionClass", e.getClass().getName());
                    // Constructor messages cannot contain questions, images or identifiers.
                    // Still retain only explicit fixed diagnostic vocabulary, never the message.
                    String message=e.getMessage()==null?"":e.getMessage();
                    ArrayList<String> flags=new ArrayList<>();
                    for(String code:new String[]{"dlopen failed","cannot locate symbol","not found","No implementation","NOT_IMPLEMENTED","INVALID_ARGUMENT","MatMulInteger","DynamicQuantizeLinear","ConvInteger","Permission denied","ORT_FAIL","QLinearMatMul","UnsatisfiedLinkError","q8gemm","SHAPE_INFERENCE_NOT_REGISTERED"}) {
                        if(message.contains(code)) flags.add(code);
                    }
                    item.put("knownMessageFlags",flags);
                    item.put("rawMessageNotRecorded",true);
                    chain.add(item);
                }
                report.put("exceptionChain",chain);
            } finally {
                if(session!=null) try {session.close();}catch(Throwable ignored){}
            }
            try(FileOutputStream out=new FileOutputStream(new File(getTargetContext().getFilesDir(),"aux-runtime-diagnosis.json"))) {
                out.write(new JSONObject(AuxReportPrivacy.report(report)).toString(2).getBytes(StandardCharsets.UTF_8));
            } catch(Exception ignored){}
            finish(Activity.RESULT_OK,new Bundle());
        }).start();
    }
}
