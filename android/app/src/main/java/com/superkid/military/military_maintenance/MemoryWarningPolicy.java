package com.superkid.military.military_maintenance;

/** Free-memory reserves during pressure, not model admission or minimum device RAM. */
public final class MemoryWarningPolicy {
    public static final long BASIC_RESERVE_BYTES = 512L * 1024 * 1024;
    public static final long GENERATION_RESERVE_BYTES = 768L * 1024 * 1024;
    public static final String IGNORE = "ignore";
    public static final String DEFER = "finish_then_release";
    public static final String RELEASE = "release_idle";
    public static final String FALLBACK = "fallback_now";
    public static final class Decision {
        public final String action;
        public final long reserveBytes, thresholdBytes;
        Decision(String action,long reserve,long threshold) {
            this.action=action; this.reserveBytes=reserve; this.thresholdBytes=threshold;
        }
    }
    public static Decision decide(int level,long availableBytes,long androidThresholdBytes,
                                  boolean lowMemory,boolean snapshotKnown,boolean busy,boolean generation) {
        long reserve=generation?GENERATION_RESERVE_BYTES:BASIC_RESERVE_BYTES;
        long threshold=Math.max(reserve,Math.max(0,androidThresholdBytes));
        // UI_HIDDEN is visibility, not evidence of memory pressure.
        boolean pressure=level==-1 || level==5 || level==10 || level==15 || level>=40;
        if(!pressure || level==20) return new Decision(IGNORE,reserve,threshold);
        boolean severe=level==-1 || level==15 || level>=60;
        if((!snapshotKnown && severe) || (snapshotKnown && (lowMemory || availableBytes<=threshold)))
            return new Decision(FALLBACK,reserve,threshold);
        return new Decision(busy?DEFER:RELEASE,reserve,threshold);
    }
    private MemoryWarningPolicy() {}
}
