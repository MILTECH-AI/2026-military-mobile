package com.superkid.military.military_maintenance

import android.os.*
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicReference

/** Fresh self-PSS in each process; never adds independently observed maxima. */
class FlowMemoryTrace(private val main: Handler, private val connection: () -> Pair<Messenger?, Boolean>) {
    private val executor = Executors.newSingleThreadScheduledExecutor()
    private var job: ScheduledFuture<*>? = null
    private val rows = mutableListOf<Map<String, Any?>>()
    private val events = mutableListOf<Map<String, Any?>>()
    @Volatile private var phase = "setup"
    private var started = 0L
    fun start(intervalMs: Long) {
        require(intervalMs in 250..2000 && job == null)
        synchronized(rows) { rows.clear() }; synchronized(events) { events.clear() }
        started = SystemClock.elapsedRealtimeNanos()
        job = executor.scheduleWithFixedDelay({ sample() }, 0, intervalMs, TimeUnit.MILLISECONDS)
    }
    fun mark(value: String) { require(value.length <= 120); phase = value; event("phase", value) }
    fun event(kind: String, value: String) {
        if (job != null) synchronized(events) { events.add(mapOf("atNanos" to SystemClock.elapsedRealtimeNanos(), "kind" to kind, "value" to value)) }
    }
    private fun sample() {
        val begin = SystemClock.elapsedRealtimeNanos(); val beginPhase = phase
        val latch = CountDownLatch(1); val child = AtomicReference<Map<String, Any?>?>()
        val response = Messenger(Handler(Looper.getMainLooper()) { msg ->
            child.set(msg.data.keySet().associateWith { msg.data.get(it) }); latch.countDown(); true
        })
        main.post {
            val (worker, bound) = connection()
            if (worker == null) {
                child.set(mapOf("state" to if (bound) "connecting" else "not_bound", "pssKb" to if (bound) null else 0))
                latch.countDown()
            } else try {
                worker.send(Message.obtain().apply { replyTo = response; data = Bundle().apply { putString("operation", "sample_memory") } })
            } catch (_: Exception) { latch.countDown() }
        }
        val uiStart = SystemClock.elapsedRealtimeNanos(); val uiPss = Debug.getPss(); val uiEnd = SystemClock.elapsedRealtimeNanos()
        latch.await(300, TimeUnit.MILLISECONDS)
        val end = SystemClock.elapsedRealtimeNanos(); val w = child.get()
        val childPss = w?.get("pssKb") as? Number
        val childStart = (w?.get("startNanos") as? Number)?.toLong()
        val childEnd = (w?.get("endNanos") as? Number)?.toLong()
        val skewMs = if (childStart != null && childEnd != null) kotlin.math.abs((uiStart+uiEnd)/2.0 - (childStart+childEnd)/2.0)/1e6 else null
        val row = mapOf("batchStartNanos" to begin, "batchEndNanos" to end, "phaseStart" to beginPhase, "phaseEnd" to phase,
            "windowMs" to (end-begin)/1e6, "ui" to mapOf("pid" to Process.myPid(), "pssKb" to uiPss, "startNanos" to uiStart, "endNanos" to uiEnd),
            "worker" to w, "pairedTotalPssKb" to childPss?.let { uiPss + it.toLong() }, "validPair" to (childPss != null),
            "midpointSkewMs" to skewMs, "readWindowsOverlap" to (childStart != null && childEnd != null && maxOf(uiStart,childStart) <= minOf(uiEnd,childEnd)),
            "samePhase" to (beginPhase == phase))
        synchronized(rows) { rows.add(row) }
    }
    fun stop(): Map<String, Any?> {
        job?.cancel(false); job = null
        // Drain the in-flight pair before returning; never block the main looper.
        return executor.submit<Map<String, Any?>> {
            mapOf("startNanos" to started, "endNanos" to SystemClock.elapsedRealtimeNanos(),
                "samples" to synchronized(rows) { rows.toList() }, "events" to synchronized(events) { events.toList() },
                "method" to "paired fresh self-PSS; common request window; not independent maxima or exact simultaneous/true-peak measurement")
        }.get(2, TimeUnit.SECONDS)
    }
    fun dispose() { job?.cancel(false); executor.shutdownNow() }
}
