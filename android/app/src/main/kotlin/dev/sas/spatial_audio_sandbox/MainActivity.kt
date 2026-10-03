package dev.sas.spatial_audio_sandbox

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

class MainActivity : FlutterActivity() {
    private val poseChannel = "dev.sas.spatial_audio_sandbox/pose"
    private val acousticEvents = "dev.sas.spatial_audio_sandbox/acoustic"
    private val acousticMethods = "dev.sas.spatial_audio_sandbox/acoustic_ctl"
    private val deviceMethods = "dev.sas.spatial_audio_sandbox/device"
    private val micReqCode = 4747

    private val acoustic = AcousticBridge()
    private var pendingRole: Boolean? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, poseChannel)
            .setStreamHandler(PoseStreamHandler(this))

        // Android filters inbound broadcast/multicast UDP unless a lock is
        // held — without this the listener never sees SASB announces.
        val wifi = getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("sas_link").apply {
            setReferenceCounted(true)
            acquire()
        }

        // Phase D probe: does this hardware support Wi-Fi RTT / Aware peer
        // ranging? Logged once at startup — decides if a radio-based
        // distance path is even available on this device.
        val pm = packageManager
        android.util.Log.i("SAS", "rtt=${pm.hasSystemFeature("android.hardware.wifi.rtt")} " +
            "aware=${pm.hasSystemFeature("android.hardware.wifi.aware")} " +
            "uwb=${pm.hasSystemFeature("android.hardware.uwb")}")

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, acousticEvents)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(a: Any?, sink: EventChannel.EventSink?) {
                    acoustic.sink = sink
                }
                override fun onCancel(a: Any?) { acoustic.sink = null }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, acousticMethods)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val beacon = call.argument<String>("role") == "beacon"
                        if (hasMic()) {
                            acoustic.start(beacon)
                            result.success(null)
                        } else {
                            pendingRole = beacon
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.RECORD_AUDIO),
                                micReqCode)
                            result.success(null) // starts on grant
                        }
                    }
                    "ping" -> { acoustic.ping(); result.success(null) }
                    "stop" -> { acoustic.stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceMethods)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // e.g. "Pixel 6 Pro" — the link UI shows this instead
                    // of a bare beacon id.
                    "getDeviceName" -> result.success(Build.MODEL)
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasMic() = ContextCompat.checkSelfPermission(
        this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        req: Int, perms: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(req, perms, grants)
        if (req == micReqCode && grants.firstOrNull() ==
            PackageManager.PERMISSION_GRANTED) {
            pendingRole?.let { acoustic.start(it) }
        }
        pendingRole = null
    }

    override fun onDestroy() {
        acoustic.stop()
        multicastLock?.release()
        super.onDestroy()
    }
}

/**
 * Streams head pose: [w, x, y, z, gx, gy, gz]
 * - quat from TYPE_GAME_ROTATION_VECTOR (gyro+accel fusion, no magnetometer
 *   -> no indoor magnetic drift; absolute north is irrelevant since the app
 *   recenters anyway)
 * - gyro rad/s from TYPE_GYROSCOPE, cached and attached to each rotvec event
 */
class PoseStreamHandler(private val context: Context) :
    EventChannel.StreamHandler, SensorEventListener {

    private var sensorManager: SensorManager? = null
    private var sink: EventChannel.EventSink? = null
    private val quat = FloatArray(4)
    private val gyro = floatArrayOf(0f, 0f, 0f)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        sensorManager = sm
        val rot = sm.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?: sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (rot == null) {
            events?.error("NO_SENSOR", "no rotation-vector sensor on this device", null)
            return
        }
        sm.registerListener(this, rot, SensorManager.SENSOR_DELAY_GAME)
        sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE)?.let {
            sm.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
    }

    override fun onCancel(arguments: Any?) {
        sensorManager?.unregisterListener(this)
        sensorManager = null
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_GAME_ROTATION_VECTOR, Sensor.TYPE_ROTATION_VECTOR -> {
                // quat out order: [w, x, y, z]
                SensorManager.getQuaternionFromVector(quat, event.values)
                sink?.success(
                    floatArrayOf(
                        quat[0], quat[1], quat[2], quat[3],
                        gyro[0], gyro[1], gyro[2]
                    )
                )
            }
            Sensor.TYPE_GYROSCOPE -> {
                gyro[0] = event.values[0]
                gyro[1] = event.values[1]
                gyro[2] = event.values[2]
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}

/**
 * Two-way acoustic ranging (NTP-style, cancels both phones' software audio
 * latencies):
 *
 *   listener emits chirp (audio-clock t1) → beacon mic detects (t2) →
 *   beacon chirps back (t3) → listener mic detects (t4)
 *   d = c · ((t4−t1) − (t3−t2)) / 2
 *
 * Detection: Goertzel energy at ~18 kHz over 128-sample hops (~2.7 ms).
 * Events to Dart: [type, nanos] — type 1 = local emit, 2 = local recv,
 * 3 = responder delay (t3−t2, beacon role only).
 */
class AcousticBridge {
    var sink: EventChannel.EventSink? = null

    private val rate = 48000
    private val hop = 128
    private val chirpLen = 576 // 12 ms
    private val mainHandler = Handler(Looper.getMainLooper())

    // Two-tone protocol: the listener pings at 17 kHz, the beacon replies at
    // 19 kHz — each side detects only the *other* frequency, so a device can
    // never hear its own chirp and replies can't be confused with pings.
    private var emitFreq = 17000.0
    private var detectFreq = 19000.0

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var autoReply = false
    private var framesRead = 0L
    private var lastStampNs = 0L
    private var lastStampFrame = 0L

    /** EventSink.success must run on the main thread. */
    private fun emit(type: Int, nanos: Long) {
        mainHandler.post { sink?.success(listOf(type, nanos)) }
    }

    private fun chirp(freq: Double): ShortArray {
        val buf = ShortArray(chirpLen)
        for (i in 0 until chirpLen) {
            val t = i / rate.toDouble()
            val env = 0.5 - 0.5 * cos(2 * PI * i / chirpLen) // Hann window
            buf[i] = (sin(2 * PI * freq * t) * env * 30000).toInt().toShort()
        }
        return buf
    }

    fun start(beaconRole: Boolean) {
        if (running) return
        autoReply = beaconRole
        if (beaconRole) {
            emitFreq = 19000.0; detectFreq = 17000.0
        } else {
            emitFreq = 17000.0; detectFreq = 19000.0
        }
        running = true
        thread = Thread { run() }.apply { isDaemon = true; start() }
    }

    fun stop() {
        running = false
        try { thread?.join(500) } catch (_: InterruptedException) {}
        thread = null
    }

    fun ping() = emitChirp()

    private fun run() {
        val min = AudioRecord.getMinBufferSize(
            rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.UNPROCESSED, rate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                min * 2)
        } catch (_: Exception) {
            AudioRecord(MediaRecorder.AudioSource.MIC, rate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                min * 2)
        }
        record = rec
        rec.startRecording()

        val buf = ShortArray(hop)
        var above = 0
        var detected = false
        var s1 = 0.0
        var s2 = 0.0
        val stamp = AudioTimestamp()
        val w = 2 * cos(2 * PI * detectFreq / rate)

        while (running) {
            val n = rec.read(buf, 0, hop)
            if (n <= 0) continue

            // AudioRecord.getTimestamp returns a status int, not Boolean.
            if (rec.getTimestamp(stamp, AudioTimestamp.TIMEBASE_MONOTONIC)
                == AudioRecord.SUCCESS) {
                lastStampNs = stamp.nanoTime
                lastStampFrame = stamp.framePosition
            }

            // Goertzel at the *remote* chirp frequency across this hop.
            var s0: Double
            for (i in 0 until n) {
                s0 = buf[i] + w * s1 - s2
                s2 = s1; s1 = s0
            }
            val power = s1 * s1 + s2 * s2 - w * s1 * s2
            val hit = power > 2.0e8
            framesRead += n

            if (hit) {
                above++
            } else {
                if (detected && above == 0) detected = false
                above = 0
                continue
            }

            if (above >= 2 && !detected) {
                detected = true
                // Arrival ≈ this hop's start frame → map to audio clock.
                val atFrame = framesRead - n - hop
                val ns = lastStampNs +
                    ((atFrame - lastStampFrame) * 1e9 / rate).toLong()
                emit(2, ns)
                if (autoReply) {
                    emitChirpWithDelay(ns)
                }
            }
        }
        rec.stop(); rec.release()
        record = null
    }

    /** Play a chirp and report its audio-clock emit timestamp. */
    private fun emitChirp() = emitChirpWithDelay(0L)

    private fun emitChirpWithDelay(recvNs: Long) {
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build())
            .setBufferSizeInBytes(chirpLen * 2)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()
        track.write(chirp(emitFreq), 0, chirpLen)
        track.play()
        // getTimestamp is only valid once frames are actually presented —
        // poll briefly, then report emit (and responder delay) events.
        Thread {
            val stamp = AudioTimestamp()
            var got = false
            repeat(20) {
                // AudioTrack.getTimestamp is monotonic-only, single arg.
                if (!got && track.getTimestamp(stamp)) {
                    got = true
                    emit(1, stamp.nanoTime)
                    if (recvNs != 0L) emit(3, stamp.nanoTime - recvNs)
                } else Thread.sleep(5)
            }
            Thread.sleep(200)
            track.stop(); track.release()
        }.start()
    }
}
