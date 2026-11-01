package com.superkid.military.military_maintenance;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONObject;

/** Boundary tests of the production decision function; no mock model or claimed physical pressure. */
public class MemoryPolicyInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Map<String,Object> out=new LinkedHashMap<>(); int passed=0;
        long mib=1024L*1024;
        try {
            for(int level:new int[]{5,10,15,40,60,80}) {
                if(!MemoryWarningPolicy.decide(level,2048*mib,384*mib,false,true,true,false).action.equals(MemoryWarningPolicy.DEFER)) throw new AssertionError(); passed++;
                if(!MemoryWarningPolicy.decide(level,2048*mib,384*mib,false,true,false,false).action.equals(MemoryWarningPolicy.RELEASE)) throw new AssertionError(); passed++;
            }
            if(!MemoryWarningPolicy.decide(20,0,384*mib,true,true,true,false).action.equals(MemoryWarningPolicy.IGNORE)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(15,512*mib,384*mib,false,true,true,false).action.equals(MemoryWarningPolicy.FALLBACK)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(15,512*mib+1,384*mib,false,true,true,false).action.equals(MemoryWarningPolicy.DEFER)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(15,2048*mib,384*mib,true,true,true,false).action.equals(MemoryWarningPolicy.FALLBACK)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(15,-1,0,false,false,true,false).action.equals(MemoryWarningPolicy.FALLBACK)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(15,700*mib,384*mib,false,true,true,true).action.equals(MemoryWarningPolicy.FALLBACK)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(15,800*mib,384*mib,false,true,true,true).action.equals(MemoryWarningPolicy.DEFER)) throw new AssertionError();passed++;
            if(MemoryWarningPolicy.decide(15,950*mib,1024*mib,false,true,true,false).thresholdBytes!=1024*mib) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(15,950*mib,1024*mib,false,true,true,false).action.equals(MemoryWarningPolicy.FALLBACK)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(-1,2048*mib,384*mib,false,true,true,false).action.equals(MemoryWarningPolicy.DEFER)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(-1,2048*mib,384*mib,false,true,false,false).action.equals(MemoryWarningPolicy.RELEASE)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(-1,512*mib,384*mib,false,true,true,false).action.equals(MemoryWarningPolicy.FALLBACK)) throw new AssertionError();passed++;
            if(!MemoryWarningPolicy.decide(-1,-1,0,false,false,true,false).action.equals(MemoryWarningPolicy.FALLBACK)) throw new AssertionError();passed++;
            out.put("status","passed");
        } catch(Throwable e) {out.put("status","failed");out.put("failureClass",e.getClass().getSimpleName());}
        out.put("passedAssertions",passed);out.put("actualRamPressureExperiment",false);
        try(FileOutputStream f=new FileOutputStream(new File(getTargetContext().getFilesDir(),"memory-policy-result.json"))) {
            f.write(new JSONObject(AuxReportPrivacy.report(out)).toString(2).getBytes(StandardCharsets.UTF_8));
        }catch(Exception ignored){}
        finish("passed".equals(out.get("status"))?Activity.RESULT_OK:Activity.RESULT_CANCELED,new Bundle());
    }
}
