package ai.tunio.radioplayer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.Semaphore
import kotlin.math.abs
import kotlin.math.roundToInt

class VisualizerActivity : Activity() {
    private enum class PlaybackMode {
        ORDERED,
        RANDOM,
    }

    private class BandwidthLimitedDataSource(
        private val upstream: DataSource,
        private val maxBytesPerSecond: Long,
    ) : DataSource by upstream {
        private var openedAtMs = 0L
        private var transferredBytes = 0L

        override fun open(dataSpec: DataSpec): Long {
            openedAtMs = SystemClock.elapsedRealtime()
            transferredBytes = 0L
            return upstream.open(dataSpec)
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            val readBytes = upstream.read(buffer, offset, length)
            if (readBytes > 0) {
                transferredBytes += readBytes
                throttleBackgroundTransfer(transferredBytes, openedAtMs, maxBytesPerSecond)
            }
            return readBytes
        }

        override fun close() {
            upstream.close()
            openedAtMs = 0L
            transferredBytes = 0L
        }
    }

    private data class VideoPlacement(
        val x: Float,
        val y: Float,
        val width: Float,
        val height: Float,
    )

    companion object {
        const val EXTRA_URL = "visualizer_url"
        const val EXTRA_LOW_PERFORMANCE_MODE = "low_performance_mode"
        private const val TAG = "VisualizerActivity"
        private const val VIDEO_CACHE_DIR_NAME = "visualizer_video_cache"
        private const val IMAGE_CACHE_DIR_NAME = "visualizer_image_cache"
        private const val IMAGE_CACHE_MAX_BYTES = 512L * 1024L * 1024L // 512 MB
        private const val IMAGE_CACHE_MAX_ITEM_BYTES = 32L * 1024L * 1024L // 32 MB
        private const val IMAGE_CACHE_FREE_SPACE_FRACTION = 0.25
        private const val IMAGE_PREFETCH_MAX_ITEMS = 512
        private const val IMAGE_PREFETCH_DELAY_MS = 150L
        private const val IMAGE_DOWNLOAD_CONNECT_TIMEOUT_MS = 10_000
        private const val IMAGE_DOWNLOAD_READ_TIMEOUT_MS = 30_000
        // Image prefetch stays tiny — images are small and non-urgent.
        private const val IMAGE_PREFETCH_MAX_BYTES_PER_SECOND = 32L * 1024L
        // Video trickle must actually GROW the cache-only rotation while a
        // scene plays: at 32KB/s one low clip took ~85s and long scenes looped
        // two clips forever. 96KB/s caches a low clip in ~30s while leaving a
        // weak (~1.5-2 Mbit) link enough headroom for the radio stream.
        private const val VIDEO_PREFETCH_MAX_BYTES_PER_SECOND = 96L * 1024L
        // Hard ceiling for the on-disk video cache. The effective cap preserves existing
        // cached clips and only grows from currently-free space — see resolveVideoCacheMaxBytes.
        private const val VIDEO_CACHE_MAX_BYTES = 3L * 1024L * 1024L * 1024L // 3 GB
        // Do not allocate additional cache space from this reserved part of free storage.
        private const val MEDIA_CACHE_FREE_SPACE_RESERVE_BYTES = 1L * 1024L * 1024L * 1024L // 1 GB
        // Never add more than this fraction of the usable free space at creation time.
        private const val VIDEO_CACHE_FREE_SPACE_FRACTION = 0.5
        // How many distinct playlist clips to prefetch (whole clips, for offline playback).
        private const val VIDEO_PREFETCH_MAX_ITEMS = 64
        // Cache-only playback: when a scene arrives with nothing cached, the
        // first clip downloads at full speed and playback starts when it lands;
        // on failure (network down) the download retries this often.
        private const val PRIORITY_CLIP_RETRY_MS = 15_000L
        // Next-scene precache (the page announces upcoming clips): make sure a
        // couple of clips are cached before the switch — never the whole list,
        // category playlists can hold hundreds. Rate sits between the 32KB/s
        // trickle and full speed so the radio stream survives on weak links.
        private const val PRECACHE_CLIPS_PER_SCENE = 2
        private const val PRECACHE_MAX_BYTES_PER_SECOND = 128L * 1024L
        private const val PRECACHE_MAX_SOURCES = 200
        // A scene switch delivers "clear" (old scene unmounting) immediately
        // followed by "setPlaylist" (new scene mounting) from the same page
        // commit. Deferring the teardown this briefly lets that setPlaylist
        // cancel it and take over the live pipeline (seamless video→video).
        // If nothing follows — the next scene has no video — the teardown runs
        // moments later, invisible behind the already-opaque page.
        private const val CLEAR_COALESCE_MS = 150L
        private const val PLAYBACK_GUARD_CHECK_INTERVAL_MS = 3000L
        // Watchdog for a decoder that never emits the first frame — without it
        // a pre-first-frame stall left the screen black forever (the regular
        // guard deliberately skips the waitingForFirstFrame phase).
        private const val FIRST_FRAME_STALL_TIMEOUT_MS = 8000L
        // Prefer the real rendered-frame callback. A few old hardware decoders
        // never emit it, so use READY only as a delayed fallback after giving
        // the SurfaceView time to receive a frame.
        private const val FIRST_FRAME_READY_FALLBACK_MS = 750L
        private const val PLAYBACK_GUARD_STALL_TIMEOUT_MS = 12000L
        // The pipeline plays hidden until its first rendered frame (old
        // decoders emit no frame while paused). If the reveal got delayed and
        // the clip drifted past this, realign to zero so viewers never see a
        // clip start from its middle.
        private const val REVEAL_REALIGN_THRESHOLD_MS = 500L
        private const val PLAYBACK_GUARD_RECOVERY_COOLDOWN_MS = 2500L
        private const val PLAYBACK_PROGRESS_EPSILON_MS = 250L

        private fun throttleBackgroundTransfer(
            transferredBytes: Long,
            startedAtMs: Long,
            maxBytesPerSecond: Long,
        ) {
            if (startedAtMs <= 0L || maxBytesPerSecond <= 0L) {
                return
            }
            val expectedElapsedMs = transferredBytes * 1000L / maxBytesPerSecond
            val actualElapsedMs = SystemClock.elapsedRealtime() - startedAtMs
            val delayMs = expectedElapsedMs - actualElapsedMs
            if (delayMs <= 0L) {
                return
            }
            try {
                Thread.sleep(delayMs)
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                throw InterruptedIOException("Media prefetch interrupted").apply {
                    initCause(error)
                }
            }
        }

        @Volatile
        private var sharedVideoCache: SimpleCache? = null

        @Volatile
        private var sharedVideoCachePath: String? = null

        @Volatile
        private var sharedDatabaseProvider: StandaloneDatabaseProvider? = null

        // The cap the shared cache was actually created with. The SimpleCache is a
        // process-wide singleton, so its LRU cap is fixed at first creation; callers
        // read this back to keep their prefetch budget aligned with the real cap.
        @Volatile
        private var sharedVideoCacheMaxBytes: Long = VIDEO_CACHE_MAX_BYTES

        private fun obtainSharedVideoCache(context: Context, cacheDir: File, maxBytes: Long): SimpleCache {
            synchronized(this) {
                val desiredPath = cacheDir.absolutePath
                val existing = sharedVideoCache
                if (existing != null && sharedVideoCachePath == desiredPath) {
                    return existing
                }
                if (existing != null) {
                    try {
                        existing.release()
                    } catch (_: Throwable) {
                        // no-op
                    }
                    sharedVideoCache = null
                    sharedVideoCachePath = null
                }

                val provider = sharedDatabaseProvider ?: StandaloneDatabaseProvider(context).also {
                    sharedDatabaseProvider = it
                }
                val cache = SimpleCache(
                    cacheDir,
                    LeastRecentlyUsedCacheEvictor(maxBytes),
                    provider,
                )
                sharedVideoCache = cache
                sharedVideoCachePath = desiredPath
                sharedVideoCacheMaxBytes = maxBytes
                return cache
            }
        }

        fun ensureDirectoryWritable(dir: File): Boolean {
            return try {
                if (!dir.exists() && !dir.mkdirs()) {
                    return false
                }
                dir.isDirectory && dir.canWrite()
            } catch (_: Throwable) {
                false
            }
        }

        fun resolveVideoCacheDir(context: Context): File {
            val externalDirs = context.getExternalFilesDirs(null).filterNotNull()
            val removableDir = externalDirs.firstOrNull {
                Environment.isExternalStorageRemovable(it) && ensureDirectoryWritable(it)
            }
            if (removableDir != null) {
                return File(removableDir, VIDEO_CACHE_DIR_NAME).apply { mkdirs() }
            }
            val internalExternalDir = externalDirs.firstOrNull {
                !Environment.isExternalStorageRemovable(it) && ensureDirectoryWritable(it)
            }
            if (internalExternalDir != null) {
                return File(internalExternalDir, VIDEO_CACHE_DIR_NAME).apply { mkdirs() }
            }
            val internalDir = context.cacheDir.takeIf { ensureDirectoryWritable(it) }
            if (internalDir != null) {
                return File(internalDir, VIDEO_CACHE_DIR_NAME).apply { mkdirs() }
            }
            return File(context.cacheDir, VIDEO_CACHE_DIR_NAME).apply { mkdirs() }
        }

        private fun imageCacheDirFor(context: Context): File {
            val root = resolveVideoCacheDir(context).parentFile ?: context.cacheDir
            return File(root, IMAGE_CACHE_DIR_NAME).apply { mkdirs() }
        }

        private fun shortNameFromUrl(url: String): String {
            val withoutQuery = url.substringBefore('?')
            val last = withoutQuery.substringAfterLast('/')
            return if (last.isNotEmpty()) last else url
        }

        // Snapshot of the on-device screen cache for the web-admin "Screen Cache"
        // card. Returns primitives/lists that MethodChannel serializes as-is.
        fun collectScreenCacheInfo(context: Context): Map<String, Any?> {
            val videoDir = resolveVideoCacheDir(context)
            val imageDir = imageCacheDirFor(context)

            val videoItems = ArrayList<Map<String, Any?>>()
            var videoBytes = 0L
            var videoCount = 0
            val cache = sharedVideoCache
            if (cache != null) {
                for (key in HashSet(cache.keys)) {
                    val bytes = try {
                        cache.getCachedBytes(key, 0, Long.MAX_VALUE)
                    } catch (_: Throwable) {
                        0L
                    }
                    videoBytes += bytes
                    videoCount++
                    videoItems.add(
                        mapOf(
                            "name" to shortNameFromUrl(key),
                            // Cache key is "video:<absolute source URL>" — strip the
                            // prefix to expose the original CDN URL for a view link.
                            "url" to key.removePrefix("video:"),
                            "bytes" to bytes,
                        ),
                    )
                }
            } else {
                // No live SimpleCache instance: fall back to a directory size probe
                // (chunks can't be mapped back to clip URLs without opening it).
                videoDir.walkTopDown().filter { it.isFile }.forEach {
                    videoBytes += it.length()
                    videoCount++
                }
            }

            val imageFiles = imageDir.listFiles()
                ?.filter { it.isFile && it.name.endsWith(".webp", ignoreCase = true) }
                ?: emptyList()
            val imageBytes = imageFiles.fold(0L) { acc, file -> acc + file.length() }

            var newestMs = 0L
            imageFiles.forEach { if (it.lastModified() > newestMs) newestMs = it.lastModified() }
            videoDir.walkTopDown().filter { it.isFile }.forEach {
                if (it.lastModified() > newestMs) newestMs = it.lastModified()
            }

            videoItems.sortByDescending { (it["bytes"] as? Long) ?: 0L }

            return mapOf(
                "video" to mapOf(
                    "count" to videoCount,
                    "bytes" to videoBytes,
                    "items" to videoItems.take(100),
                ),
                "images" to mapOf(
                    "count" to imageFiles.size,
                    "bytes" to imageBytes,
                ),
                "newestMs" to newestMs,
            )
        }

        fun clearScreenCache(context: Context) {
            val cache = sharedVideoCache
            if (cache != null) {
                for (key in HashSet(cache.keys)) {
                    try {
                        cache.removeResource(key)
                    } catch (_: Throwable) {
                        // best effort
                    }
                }
            } else {
                // Safe to delete on disk only when no SimpleCache instance holds it.
                resolveVideoCacheDir(context).listFiles()?.forEach { it.deleteRecursively() }
            }
            imageCacheDirFor(context).listFiles()
                ?.filter { it.isFile && it.name.endsWith(".webp", ignoreCase = true) }
                ?.forEach { it.delete() }
        }
    }

    private lateinit var rootLayout: FrameLayout
    private lateinit var videoLayer: FrameLayout
    private lateinit var videoPlayerView: PlayerView
    private lateinit var dimOverlayView: View
    private lateinit var transitionOverlayView: View
    private lateinit var webView: WebView
    private lateinit var marqueeOverlayController: MarqueeOverlayController

    private var player: ExoPlayer? = null
    private var playlist: List<String> = emptyList()
    private val playQueue = mutableListOf<Int>()
    private val mediaIdToPlaylistIndex = mutableMapOf<String, Int>()
    private var mediaIdSerial: Long = 0
    private var currentIndex: Int = -1
    private var currentOwnerId: String? = null
    private var currentPlaylistKey: String = ""
    private var currentPlaybackMode = PlaybackMode.RANDOM
    private var currentDimAlpha: Float = 0f
    private var currentPlacement: VideoPlacement? = null
    private var cachedSceneViewportRect: RectF? = null
    private var waitingForFirstFrame = false
    private var firstFrameWaitToken = 0L
    private var pendingRevealAfterTransform = false
    private var firstFrameWaitStartedAtMs = 0L
    private var realignedAtReveal = false
    private var pendingClearRunnable: Runnable? = null
    // Cache-only playback: true while the current playlist has no fully cached
    // clip yet — the video layer stays hidden, the page renders the scene
    // opaquely, and the first clip is being downloaded with priority.
    private var awaitingFirstCachedClip = false
    // Quiet first-frame wait: the video joins a scene already on screen, so
    // the page keeps its normal background instead of the black shutter.
    private var suppressWaitingBlackout = false
    private val closeTapSlop by lazy { ViewConfiguration.get(this).scaledTouchSlop.toFloat() }
    private var closeTapDownX: Float = 0f
    private var closeTapDownY: Float = 0f
    private var lowPerformanceMode: Boolean = false
    private val playbackGuardHandler = Handler(Looper.getMainLooper())
    private var playbackGuardRunnable: Runnable? = null
    private var lastObservedPlaybackPositionMs: Long = -1L
    private var lastPlaybackProgressRealtimeMs: Long = 0L
    private var lastRecoveryAttemptRealtimeMs: Long = 0L
    private lateinit var playbackCacheDataSourceFactory: CacheDataSource.Factory
    private lateinit var prefetchCacheDataSourceFactory: CacheDataSource.Factory
    private lateinit var precacheCacheDataSourceFactory: CacheDataSource.Factory
    private var lastPrecacheKey: String = ""
    private val mediaPrefetchPermit = Semaphore(1, true)
    private val prefetchExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var prefetchFuture: Future<*>? = null
    @Volatile
    private var prefetchToken: Int = 0
    @Volatile
    private var activeCacheWriter: CacheWriter? = null
    private lateinit var videoCache: SimpleCache
    private var videoCacheMaxBytes: Long = VIDEO_CACHE_MAX_BYTES
    private lateinit var imageCacheDir: File
    private var imageCacheMaxBytes: Long = IMAGE_CACHE_MAX_BYTES
    private val imageCacheLocks = ConcurrentHashMap<String, Any>()
    private val imagePrefetchExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var imagePrefetchFuture: Future<*>? = null
    @Volatile
    private var imagePrefetchToken: Int = 0
    @Volatile
    private var activeImagePrefetchConnection: HttpURLConnection? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lowPerformanceMode = intent?.getBooleanExtra(EXTRA_LOW_PERFORMANCE_MODE, false) ?: false
        // Allow inspecting the screen-player WebView from desktop Chrome via
        // chrome://inspect (Elements/Console/Performance/Paint-flashing) — only
        // in debuggable builds, so production/release stays locked down.
        if (0 != (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE)) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
        setupWindow()
        initPlayer()

        marqueeOverlayController = MarqueeOverlayController(this)
        webView = createWebView()
        setContentView(createLayout())

        videoPlayerView.player = player
        VisualizerController.currentActivity = this

        val url = intent?.getStringExtra(EXTRA_URL)
        if (url.isNullOrEmpty()) {
            VisualizerController.notifyError("Missing visualizer URL")
            finish()
        } else {
            loadUrl(url)
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        lowPerformanceMode = intent?.getBooleanExtra(EXTRA_LOW_PERFORMANCE_MODE, lowPerformanceMode) ?: lowPerformanceMode
        intent?.getStringExtra(EXTRA_URL)?.let { loadUrl(it) }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopPlaybackGuard()
        if (VisualizerController.currentActivity == this) {
            VisualizerController.currentActivity = null
        }
        clearNativeVideo()
        marqueeOverlayController.clearAll()
        cancelVideoPrefetch()
        prefetchExecutor.shutdownNow()
        cancelImagePrefetch()
        imagePrefetchExecutor.shutdownNow()
        videoPlayerView.player = null
        player?.release()
        player = null
        webView.destroy()
        VisualizerController.notifyClosed()
    }

    fun runJavaScript(script: String) {
        webView.evaluateJavascript(script, null)
    }

    private fun setupWindow() {
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_FULLSCREEN,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.decorView.post {
                window.insetsController?.hide(
                    WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars(),
                )
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                android.view.View.SYSTEM_UI_FLAG_FULLSCREEN or
                    android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                )
        }
    }

    private fun initPlayer() {
        initVideoCaching()
        initImageCaching()
        val mediaSourceFactory = DefaultMediaSourceFactory(playbackCacheDataSourceFactory)
        val silentVideoAttrs = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .build()

        val noAudioTracks = TrackSelectionParameters.Builder(this)
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
            .build()

        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
            .apply {
            repeatMode = Player.REPEAT_MODE_OFF
            playWhenReady = true
            videoScalingMode = if (lowPerformanceMode) {
                C.VIDEO_SCALING_MODE_SCALE_TO_FIT
            } else {
                C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING
            }
            volume = 0f
            trackSelectionParameters = noAudioTracks
            // Do not participate in Android audio focus - audio app remains authoritative.
            setAudioAttributes(silentVideoAttrs, false)
            addListener(
                object : Player.Listener {
                    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                        val mediaId = mediaItem?.mediaId
                        if (!mediaId.isNullOrEmpty()) {
                            val transitionedIndex = mediaIdToPlaylistIndex[mediaId]
                            if (transitionedIndex != null) {
                                currentIndex = transitionedIndex
                            }
                        }

                        dropPlayedItems()
                        ensureQueueDepth()
                        // A loop resets currentPosition to zero. Treat the item
                        // transition itself as progress so the watchdog does not
                        // mistake the next loop for a 12-second decoder stall.
                        markPlaybackProgressIfAdvanced(forceRefresh = true)

                        // Keep transitions hard-cut here: visual overlay fade can drift
                        // behind the actual decoder frame switch on some devices.
                    }

                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_READY && waitingForFirstFrame) {
                            scheduleFirstFrameReadyFallback()
                        }
                        // Mid-playback rebuffer = the visible "micro-freeze": the
                        // clip is not fully cached and the network fell behind.
                        // Cheap diagnostic, visible via `adb logcat -s VisualizerActivity`.
                        if (playbackState == Player.STATE_BUFFERING && !waitingForFirstFrame) {
                            Log.w(
                                TAG,
                                "rebuffering at ${player?.currentPosition}ms of ${player?.currentMediaItem?.localConfiguration?.uri}",
                            )
                        }
                        markPlaybackProgressIfAdvanced()
                        if (playbackState == Player.STATE_ENDED) {
                            hardCutToNext()
                        }
                    }

                    override fun onRenderedFirstFrame() {
                        if (waitingForFirstFrame) {
                            pendingRevealAfterTransform = true
                            maybeRevealVideoAfterFirstFrame()
                        } else {
                            // Layer already visible (e.g. clip rotation):
                            // still report readiness — older web bundles
                            // listen for this event.
                            notifyNativeVideoReady(currentOwnerId)
                        }
                    }

                    override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                        maybeRevealVideoAfterFirstFrame()
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        if (isPlaying) {
                            markPlaybackProgressIfAdvanced(forceRefresh = true)
                        }
                    }

                    override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                        Log.w(TAG, "player error, hard cut fallback: ${error.message}")
                        transitionOverlayView.alpha = 0f
                        if (tryPlayCachedFallback()) {
                            return
                        }
                        hardCutToNext()
                    }
                },
            )
        }
    }

    private fun initVideoCaching() {
        val cacheDir = resolveVideoCacheDir(this)
        val appContext = applicationContext
        val desiredCap = resolveVideoCacheMaxBytes(cacheDir)
        val cache = obtainSharedVideoCache(appContext, cacheDir, desiredCap)
        videoCache = cache
        // The cache is a process-wide singleton whose cap is fixed at first creation;
        // read that real cap back so the prefetch budget can't overshoot it.
        videoCacheMaxBytes = sharedVideoCacheMaxBytes
        Log.d(TAG, "Video cache cap=${videoCacheMaxBytes / (1024L * 1024L)}MB dir=${cacheDir.absolutePath}")
        val httpFactory = DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true)
        val upstreamFactory = DefaultDataSource.Factory(appContext, httpFactory)
        val limitedPrefetchUpstreamFactory = DataSource.Factory {
            BandwidthLimitedDataSource(
                upstreamFactory.createDataSource(),
                VIDEO_PREFETCH_MAX_BYTES_PER_SECOND,
            )
        }
        val cacheKeyFactory = CacheKeyFactory { dataSpec ->
            buildVideoCacheKey(dataSpec.uri)
        }
        Log.d(TAG, "Video cache directory: ${cacheDir.absolutePath}")

        // Let normal playback populate the cache. Otherwise the active video
        // and its background prefetch download the same bytes twice.
        playbackCacheDataSourceFactory = CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstreamFactory)
            .setCacheKeyFactory(cacheKeyFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

        // Background prefetch fills cache out-of-band.
        prefetchCacheDataSourceFactory = CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(limitedPrefetchUpstreamFactory)
            .setCacheKeyFactory(cacheKeyFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

        // Next-scene precache: faster than the trickle, gentler than playback.
        val limitedPrecacheUpstreamFactory = DataSource.Factory {
            BandwidthLimitedDataSource(
                upstreamFactory.createDataSource(),
                PRECACHE_MAX_BYTES_PER_SECOND,
            )
        }
        precacheCacheDataSourceFactory = CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(limitedPrecacheUpstreamFactory)
            .setCacheKeyFactory(cacheKeyFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }


    // Preserve the cache already on disk, then allow it to grow by a fraction of currently
    // usable free space. Counting existing data separately is important: availableBytes does
    // not include it, and using only availableBytes would shrink and evict the offline cache
    // every time the process starts.
    private fun resolveVideoCacheMaxBytes(cacheDir: File): Long {
        return try {
            val stat = StatFs(cacheDir.absolutePath)
            val existingCacheBytes = cacheDirectoryBytes(cacheDir, VIDEO_CACHE_MAX_BYTES)
                .coerceIn(0L, VIDEO_CACHE_MAX_BYTES)
            val usableFree = (stat.availableBytes - MEDIA_CACHE_FREE_SPACE_RESERVE_BYTES)
                .coerceAtLeast(0L)
            val growthBudget = (usableFree.toDouble() * VIDEO_CACHE_FREE_SPACE_FRACTION).toLong()
            (existingCacheBytes + growthBudget)
                .coerceAtMost(VIDEO_CACHE_MAX_BYTES)
        } catch (error: Throwable) {
            Log.d(TAG, "Cache size probe failed, using default cap: ${error.message}")
            VIDEO_CACHE_MAX_BYTES
        }
    }

    private fun cacheDirectoryBytes(cacheDir: File, maxBytes: Long): Long {
        return cacheDir.walkTopDown()
            .filter { it.isFile }
            .fold(0L) { total, file ->
                (total + file.length()).coerceAtMost(maxBytes)
            }
    }

    private fun initImageCaching() {
        val videoCacheDir = resolveVideoCacheDir(this)
        val mediaCacheRoot = videoCacheDir.parentFile ?: cacheDir
        imageCacheDir = File(mediaCacheRoot, IMAGE_CACHE_DIR_NAME).apply { mkdirs() }
        imageCacheDir.listFiles()
            ?.filter { it.isFile && it.name.endsWith(".tmp") }
            ?.forEach { it.delete() }
        imageCacheMaxBytes = resolveImageCacheMaxBytes(imageCacheDir)
        trimImageCache()
        Log.d(
            TAG,
            "Image cache cap=${imageCacheMaxBytes / (1024L * 1024L)}MB dir=${imageCacheDir.absolutePath}",
        )
    }

    private fun resolveImageCacheMaxBytes(cacheDir: File): Long {
        return try {
            val stat = StatFs(cacheDir.absolutePath)
            val existingCacheBytes = cacheDirectoryBytes(cacheDir, IMAGE_CACHE_MAX_BYTES)
                .coerceIn(0L, IMAGE_CACHE_MAX_BYTES)
            val usableFree = (stat.availableBytes - MEDIA_CACHE_FREE_SPACE_RESERVE_BYTES)
                .coerceAtLeast(0L)
            val growthBudget = (usableFree.toDouble() * IMAGE_CACHE_FREE_SPACE_FRACTION).toLong()
            (existingCacheBytes + growthBudget)
                .coerceAtMost(IMAGE_CACHE_MAX_BYTES)
        } catch (error: Throwable) {
            Log.d(TAG, "Image cache size probe failed, using default cap: ${error.message}")
            IMAGE_CACHE_MAX_BYTES
        }
    }

    private fun buildVideoCacheKey(uri: Uri?): String {
        if (uri == null) {
            return "video:unknown"
        }
        // Keep the complete absolute URL so equal file names from different paths or hosts
        // can never share cached spans. Only fragments are excluded because they are not sent
        // to the server and therefore cannot identify different media bytes.
        val normalized = uri.buildUpon().fragment(null).build().toString()
        return "video:$normalized"
    }

    private fun createWebView(): WebView {
        return WebView(this).apply {
            setLayerType(View.LAYER_TYPE_HARDWARE, null)
            overScrollMode = View.OVER_SCROLL_NEVER
            isVerticalScrollBarEnabled = false
            isHorizontalScrollBarEnabled = false
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.loadsImagesAutomatically = true
            settings.cacheMode = WebSettings.LOAD_NO_CACHE
            settings.setSupportZoom(false)
            settings.builtInZoomControls = false
            settings.displayZoomControls = false
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_BOUND, true)
            }
            setBackgroundColor(Color.TRANSPARENT)
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        closeTapDownX = event.x
                        closeTapDownY = event.y
                    }
                    MotionEvent.ACTION_UP -> {
                        val movedX = abs(event.x - closeTapDownX)
                        val movedY = abs(event.y - closeTapDownY)
                        if (event.pointerCount == 1 && movedX <= closeTapSlop && movedY <= closeTapSlop) {
                            closeVisualizerFromWebTap()
                        }
                    }
                }
                false
            }
            addJavascriptInterface(NativeVideoJsBridge(), "TunioNativeVideo")
            addJavascriptInterface(NativeImageCacheJsBridge(), "TunioNativeImageCache")
            webChromeClient = object : WebChromeClient() {
                override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean {
                    val message = consoleMessage?.message().orEmpty()
                    if (message.startsWith("[TunioImage]")) {
                        Log.d(
                            TAG,
                            "Image component ${message.removePrefix("[TunioImage]").trim()}",
                        )
                        return true
                    }
                    return super.onConsoleMessage(consoleMessage)
                }
            }
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(
                    view: WebView?,
                    request: WebResourceRequest?,
                ): WebResourceResponse? {
                    if (request?.method != "GET") {
                        return null
                    }
                    return interceptCachedImageRequest(request.url)
                }

                @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
                override fun shouldInterceptRequest(view: WebView?, url: String?): WebResourceResponse? {
                    return interceptCachedImageRequest(url?.let(Uri::parse))
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    Log.d(TAG, "onPageFinished url=$url")
                    // A fresh page re-registers its marquees; drop overlays the
                    // previous page never got to clear (crash, reload).
                    marqueeOverlayController.clearAll()
                    enforceWebViewMediaMuted(view)
                    syncPageTransparencyForNativeVideo(view)
                    applyLowPerformanceWebMode(view)
                    rootLayout.postDelayed({ enforceWebViewMediaMuted(view) }, 350L)
                    rootLayout.postDelayed({ syncPageTransparencyForNativeVideo(view) }, 350L)
                    rootLayout.postDelayed({ applyLowPerformanceWebMode(view) }, 350L)
                    rootLayout.postDelayed({ enforceWebViewMediaMuted(view) }, 1200L)
                    rootLayout.postDelayed({ syncPageTransparencyForNativeVideo(view) }, 1200L)
                    rootLayout.postDelayed({ applyLowPerformanceWebMode(view) }, 1200L)
                    view?.evaluateJavascript(
                        """
                        (function() {
                          var bridgeType = typeof (window.TunioNativeVideo && window.TunioNativeVideo.postMessage);
                          return JSON.stringify({
                            href: String(window.location.href || ''),
                            bridgeType: bridgeType
                          });
                        })();
                        """.trimIndent(),
                    ) { result ->
                        Log.d(TAG, "pageContext=$result")
                    }
                    VisualizerController.notifyReady()
                }
            }
        }
    }

    private fun closeVisualizerFromWebTap() {
        if (isFinishing || isDestroyed) {
            return
        }
        clearNativeVideo()
        finish()
    }

    private fun enforceWebViewMediaMuted(view: WebView?) {
        view?.evaluateJavascript(
            """
            (function() {
              try {
                function muteElement(el) {
                  if (!el) return;
                  el.muted = true;
                  el.defaultMuted = true;
                  el.volume = 0;
                }

                var media = document.querySelectorAll('video,audio');
                for (var i = 0; i < media.length; i += 1) {
                  muteElement(media[i]);
                }

                if (!window.__tunioMuteObserver) {
                  window.__tunioMuteObserver = new MutationObserver(function(mutations) {
                    for (var i = 0; i < mutations.length; i += 1) {
                      var nodes = mutations[i].addedNodes || [];
                      for (var j = 0; j < nodes.length; j += 1) {
                        var node = nodes[j];
                        if (!node || node.nodeType !== 1) continue;
                        if (node.matches && node.matches('video,audio')) {
                          muteElement(node);
                        }
                        var nested = node.querySelectorAll ? node.querySelectorAll('video,audio') : [];
                        for (var k = 0; k < nested.length; k += 1) {
                          muteElement(nested[k]);
                        }
                      }
                    }
                  });
                  window.__tunioMuteObserver.observe(document.documentElement || document.body, {
                    childList: true,
                    subtree: true
                  });
                }

                return media.length;
              } catch (e) {
                return -1;
              }
            })();
            """.trimIndent(),
            null,
        )
    }

    private fun applyLowPerformanceWebMode(view: WebView?) {
        if (!lowPerformanceMode) {
            return
        }
        view?.evaluateJavascript(
            """
            (function() {
              try {
                var root = document.documentElement;
                var body = document.body;
                if (root && root.dataset) {
                  root.dataset.tunioPerformanceMode = 'low';
                }
                if (body && body.dataset) {
                  body.dataset.tunioPerformanceMode = 'low';
                }

                var stage = document.getElementById('tunio-scene-stage');
                var appRoot = document.getElementById('tunio-screen-player-root');
                if (stage && stage.dataset) stage.dataset.tunioPerformanceMode = 'low';
                if (appRoot && appRoot.dataset) appRoot.dataset.tunioPerformanceMode = 'low';

                var styleId = '__tunio_low_performance_style';
                var style = document.getElementById(styleId);
                if (!style) {
                  style = document.createElement('style');
                  style.id = styleId;
                  style.textContent = [
                    ':root{--tunio-performance-mode:low;}',
                    '*{-webkit-backdrop-filter:none !important;backdrop-filter:none !important;}',
                    '[style*="blur("],[style*="backdrop-filter"],[class*="blur"],[class*="glass"],[class*="frost"]{',
                    '  -webkit-backdrop-filter:none !important;',
                    '  backdrop-filter:none !important;',
                    '  filter:none !important;',
                    '}'
                  ].join('');
                  (document.head || root || body).appendChild(style);
                }

                return true;
              } catch (e) {
                return false;
              }
            })();
            """.trimIndent(),
            null,
        )
    }

    private fun createLayout(): FrameLayout {
        rootLayout = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        videoLayer = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            visibility = View.GONE
        }

        videoPlayerView = PlayerView(this).apply {
            useController = false
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
            setShutterBackgroundColor(Color.BLACK)
            alpha = 0f
            addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
                val newWidth = right - left
                val newHeight = bottom - top
                val oldWidth = oldRight - oldLeft
                val oldHeight = oldBottom - oldTop
                if (newWidth <= 0 || newHeight <= 0) {
                    return@addOnLayoutChangeListener
                }
                if (newWidth == oldWidth && newHeight == oldHeight) {
                    return@addOnLayoutChangeListener
                }
                if (applyVideoCenterCropTransform()) {
                    maybeRevealVideoAfterFirstFrame()
                }
            }
        }

        dimOverlayView = View(this).apply {
            setBackgroundColor(Color.BLACK)
            alpha = 0f
        }

        transitionOverlayView = View(this).apply {
            setBackgroundColor(Color.BLACK)
            alpha = 0f
        }

        val matchParent = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
        )

        videoLayer.addView(videoPlayerView, FrameLayout.LayoutParams(matchParent))
        videoLayer.addView(dimOverlayView, FrameLayout.LayoutParams(matchParent))
        videoLayer.addView(transitionOverlayView, FrameLayout.LayoutParams(matchParent))

        rootLayout.addView(videoLayer, FrameLayout.LayoutParams(matchParent))
        rootLayout.addView(webView, FrameLayout.LayoutParams(matchParent))
        rootLayout.addView(marqueeOverlayController.layer, FrameLayout.LayoutParams(matchParent))

        rootLayout.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            val newWidth = right - left
            val newHeight = bottom - top
            val oldWidth = oldRight - oldLeft
            val oldHeight = oldBottom - oldTop
            if (newWidth <= 0 || newHeight <= 0) {
                return@addOnLayoutChangeListener
            }
            if (newWidth == oldWidth && newHeight == oldHeight) {
                return@addOnLayoutChangeListener
            }
            if (videoLayer.visibility == View.VISIBLE) {
                applyStoredPlacement()
            }
        }

        return rootLayout
    }

    private fun loadUrl(url: String) {
        marqueeOverlayController.clearAll()
        webView.loadUrl(url)
    }

    private fun syncPageTransparencyForNativeVideo(view: WebView?) {
        val forceBlackBackground = waitingForFirstFrame && !suppressWaitingBlackout
        // No renderable video yet (nothing cached, or a quiet prepare): the
        // page must stay opaque and show the scene normally — neither the
        // transparent video hole nor the black shutter.
        val suppressVideoLayer = awaitingFirstCachedClip || (waitingForFirstFrame && suppressWaitingBlackout)
        if (view == null) {
            return
        }
        view.evaluateJavascript(
            """
            (function() {
              try {
                var stage = document.getElementById('tunio-scene-stage');
                var root = document.getElementById('tunio-screen-player-root');
                var hasVideoLayer =
                  (stage && stage.dataset && stage.dataset.tunioHasVideoLayer === '1') ||
                  (root && root.dataset && root.dataset.tunioHasVideoLayer === '1') ||
                  (document.documentElement.dataset && document.documentElement.dataset.tunioHasVideoLayer === '1') ||
                  (document.body && document.body.dataset && document.body.dataset.tunioHasVideoLayer === '1');
                var nativeMode =
                  (stage && stage.dataset && stage.dataset.tunioNativeVideoMode === '1') ||
                  (root && root.dataset && root.dataset.tunioNativeVideoMode === '1') ||
                  (document.documentElement.dataset && document.documentElement.dataset.tunioNativeVideoMode === '1') ||
                  (document.body && document.body.dataset && document.body.dataset.tunioNativeVideoMode === '1');
                var forceBlack = ${if (forceBlackBackground) "true" else "false"};
                var suppressVideo = ${if (suppressVideoLayer) "true" else "false"};
                var shouldBeTransparent = Boolean(hasVideoLayer && nativeMode && !forceBlack && !suppressVideo);

                var styleId = '__tunio_native_video_transparency';
                var style = document.getElementById(styleId);
                var blackoutStyleId = '__tunio_native_video_blackout';
                var blackoutStyle = document.getElementById(blackoutStyleId);

                if (shouldBeTransparent) {
                  if (blackoutStyle && blackoutStyle.parentNode) {
                    blackoutStyle.parentNode.removeChild(blackoutStyle);
                  }
                  if (!style) {
                    style = document.createElement('style');
                    style.id = styleId;
                    style.textContent = 'html,body,#__next,#tunio-screen-player-root{background:transparent!important;}';
                    (document.head || document.documentElement).appendChild(style);
                  }
                  if (document.documentElement) {
                    document.documentElement.style.background = 'transparent';
                  }
                  if (document.body) {
                    document.body.style.background = 'transparent';
                  }
                } else {
                  if (style && style.parentNode) {
                    style.parentNode.removeChild(style);
                  }
                  if (forceBlack) {
                    if (!blackoutStyle) {
                      blackoutStyle = document.createElement('style');
                      blackoutStyle.id = blackoutStyleId;
                      blackoutStyle.textContent = 'html,body,#__next,#tunio-screen-player-root{background:#000!important;}';
                      (document.head || document.documentElement).appendChild(blackoutStyle);
                    }
                    if (document.documentElement) {
                      document.documentElement.style.background = '#000';
                    }
                    if (document.body) {
                      document.body.style.background = '#000';
                    }
                  } else {
                    if (blackoutStyle && blackoutStyle.parentNode) {
                      blackoutStyle.parentNode.removeChild(blackoutStyle);
                    }
                    if (document.documentElement) {
                      document.documentElement.style.removeProperty('background');
                    }
                    if (document.body) {
                      document.body.style.removeProperty('background');
                    }
                  }
                }

                return JSON.stringify({
                  hasVideoLayer: Boolean(hasVideoLayer),
                  nativeMode: Boolean(nativeMode),
                  shouldBeTransparent: shouldBeTransparent,
                  forceBlack: forceBlack
                });
              } catch (e) {}
            })();
            """.trimIndent(),
        ) { result ->
            Log.d(TAG, "nativeVideoTransparency=$result")
        }
    }

    private fun handleNativeVideoMessage(payload: String) {
        val json = try {
            JSONObject(payload)
        } catch (_: Throwable) {
            return
        }

        when (json.optString("action")) {
            "setPlaylist" -> handleSetPlaylist(json)
            "precache" -> handlePrecache(json)
            "clear" -> requestClearNativeVideo(json.optString("ownerId"))
            "setMarquee" -> marqueeOverlayController.setMarquee(json)
            "clearMarquee" -> marqueeOverlayController.clearMarquee(json.optString("ownerId"))
            else -> {
                // no-op (older/newer web bundles may send unknown actions,
                // e.g. the retired "sceneEnding" hint)
            }
        }

        // SPA can switch between web-rendered and native video layers without page reload.
        // Re-sync transparency on every bridge message so visual updates apply immediately.
        syncPageTransparencyForNativeVideo(webView)
    }

    // Owner-guarded and briefly deferred: a late "clear" from an unmounting
    // outgoing scene must not kill the playlist a newer scene already owns,
    // and the clear+setPlaylist pair of a video→video switch coalesces into a
    // pipeline handover instead of a teardown.
    private fun requestClearNativeVideo(ownerId: String?) {
        if (!ownerId.isNullOrEmpty() && currentOwnerId != null && ownerId != currentOwnerId) {
            Log.d(TAG, "clear ignored, owner mismatch: $ownerId != $currentOwnerId")
            return
        }
        cancelPendingClear()
        val runnable = Runnable {
            pendingClearRunnable = null
            clearNativeVideo()
        }
        pendingClearRunnable = runnable
        playbackGuardHandler.postDelayed(runnable, CLEAR_COALESCE_MS)
    }

    private fun cancelPendingClear() {
        pendingClearRunnable?.let { playbackGuardHandler.removeCallbacks(it) }
        pendingClearRunnable = null
    }

    private fun handleNativeImageCacheMessage(payload: String) {
        val json = try {
            JSONObject(payload)
        } catch (_: Throwable) {
            return
        }
        if (json.optString("action") != "setSources") {
            return
        }

        val sourceJson = json.optJSONArray("sources") ?: return
        val sources = buildList {
            for (index in 0 until sourceJson.length()) {
                val source = sourceJson.optString(index)
                if (source.isNotBlank() && isCacheableImageUri(Uri.parse(source))) {
                    add(source)
                }
            }
        }.distinct().take(IMAGE_PREFETCH_MAX_ITEMS)
        scheduleImagePrefetch(sources)
    }

    private fun scheduleImagePrefetch(sources: List<String>) {
        cancelImagePrefetch()
        if (sources.isEmpty() || imageCacheMaxBytes <= 0L) {
            return
        }

        val token = ++imagePrefetchToken
        imagePrefetchFuture = imagePrefetchExecutor.submit {
            setBackgroundPrefetchPriority()
            for (source in sources) {
                if (Thread.currentThread().isInterrupted || token != imagePrefetchToken) {
                    return@submit
                }
                val wasCached = imageCacheFileForSource(source).isFile
                try {
                    mediaPrefetchPermit.acquire()
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return@submit
                }
                val cachedFile = try {
                    if (token != imagePrefetchToken) {
                        return@submit
                    }
                    getOrDownloadCachedImage(source, isPrefetch = true)
                } finally {
                    mediaPrefetchPermit.release()
                }
                if (!wasCached && cachedFile != null) {
                    try {
                        Thread.sleep(IMAGE_PREFETCH_DELAY_MS)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return@submit
                    }
                }
            }
        }
    }

    private fun cancelImagePrefetch() {
        imagePrefetchToken += 1
        activeImagePrefetchConnection?.disconnect()
        activeImagePrefetchConnection = null
        imagePrefetchFuture?.cancel(true)
        imagePrefetchFuture = null
    }

    private fun interceptCachedImageRequest(uri: Uri?): WebResourceResponse? {
        val imageUri = uri ?: return null
        if (!isCacheableImageUri(imageUri)) {
            return null
        }
        val startedAtMs = SystemClock.elapsedRealtime()
        val cacheFileBeforeRequest = imageCacheFileForSource(imageUri.toString())
        val wasCached = cacheFileBeforeRequest.isFile && hasWebpSignature(cacheFileBeforeRequest)
        val cacheFile = getOrDownloadCachedImage(imageUri.toString()) ?: return null
        Log.d(
            TAG,
            "Image request cache=${if (wasCached) "hit" else "miss"} " +
                "duration=${SystemClock.elapsedRealtime() - startedAtMs}ms " +
                "bytes=${cacheFile.length()} path=${imageUri.path}",
        )
        return try {
            WebResourceResponse("image/webp", null, FileInputStream(cacheFile))
        } catch (error: Throwable) {
            Log.d(TAG, "Cached image open failed for $uri: ${error.message}")
            null
        }
    }

    private fun isCacheableImageUri(uri: Uri?): Boolean {
        if (uri == null || !uri.scheme.equals("https", ignoreCase = true)) {
            return false
        }
        if (!uri.host.equals("cdn.tunio.ai", ignoreCase = true)) {
            return false
        }
        val path = uri.path.orEmpty()
        return path.startsWith("/screens_media/") && path.endsWith(".webp", ignoreCase = true)
    }

    private fun getOrDownloadCachedImage(source: String, isPrefetch: Boolean = false): File? {
        val uri = Uri.parse(source)
        if (!isCacheableImageUri(uri)) {
            return null
        }

        val cacheKey = hashImageCacheKey(source)
        val cacheFile = imageCacheFileForSource(source)
        readCompleteCachedImage(cacheFile)?.let { return it }
        if (imageCacheMaxBytes <= 0L) {
            return null
        }

        val lock = imageCacheLocks.getOrPut(cacheKey) { Any() }
        return synchronized(lock) {
            readCompleteCachedImage(cacheFile) ?: downloadImageToCache(source, cacheFile, isPrefetch)
        }
    }

    private fun readCompleteCachedImage(cacheFile: File): File? {
        if (!cacheFile.isFile || !hasWebpSignature(cacheFile)) {
            cacheFile.delete()
            return null
        }
        cacheFile.setLastModified(System.currentTimeMillis())
        return cacheFile
    }

    private fun downloadImageToCache(source: String, cacheFile: File, isPrefetch: Boolean): File? {
        val tempFile = File(imageCacheDir, "${cacheFile.name}.tmp")
        val maxCacheableBytes = minOf(IMAGE_CACHE_MAX_ITEM_BYTES, imageCacheMaxBytes)
        var connection: HttpURLConnection? = null
        try {
            if (Thread.currentThread().isInterrupted) {
                return null
            }
            connection = (URL(source).openConnection() as HttpURLConnection).apply {
                connectTimeout = IMAGE_DOWNLOAD_CONNECT_TIMEOUT_MS
                readTimeout = IMAGE_DOWNLOAD_READ_TIMEOUT_MS
                instanceFollowRedirects = true
                requestMethod = "GET"
                useCaches = false
            }
            if (isPrefetch) {
                activeImagePrefetchConnection = connection
            }
            connection.connect()
            if (connection.responseCode !in 200..299) {
                return null
            }
            val contentType = connection.contentType
                ?.substringBefore(';')
                ?.trim()
                ?.lowercase()
            val supportedContentType = contentType == "image/webp" ||
                contentType == "image/x-webp" ||
                contentType == "application/octet-stream"
            if (!supportedContentType) {
                Log.d(TAG, "Image cache rejected content type for $source: $contentType")
                return null
            }
            val declaredLength = connection.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L
            if (declaredLength > maxCacheableBytes) {
                Log.d(TAG, "Image cache item too large: $source ($declaredLength bytes)")
                return null
            }

            var writtenBytes = 0L
            val transferStartedAtMs = SystemClock.elapsedRealtime()
            BufferedInputStream(connection.inputStream).use { input ->
                BufferedOutputStream(tempFile.outputStream()).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        if (Thread.currentThread().isInterrupted) {
                            throw InterruptedException("Image prefetch interrupted")
                        }
                        val readBytes = input.read(buffer)
                        if (readBytes < 0) {
                            break
                        }
                        writtenBytes += readBytes
                        if (writtenBytes > maxCacheableBytes) {
                            throw IllegalStateException("Image exceeds cache item limit")
                        }
                        output.write(buffer, 0, readBytes)
                        if (isPrefetch) {
                            throttleBackgroundTransfer(
                                writtenBytes,
                                transferStartedAtMs,
                                IMAGE_PREFETCH_MAX_BYTES_PER_SECOND,
                            )
                        }
                    }
                }
            }
            if (writtenBytes <= 0L || (declaredLength >= 0L && writtenBytes != declaredLength)) {
                return null
            }
            if (!hasWebpSignature(tempFile)) {
                Log.d(TAG, "Image cache rejected invalid WebP body: $source")
                return null
            }
            if (!tempFile.renameTo(cacheFile)) {
                return null
            }
            cacheFile.setLastModified(System.currentTimeMillis())
            trimImageCache(cacheFile)
            return cacheFile
        } catch (error: Throwable) {
            Log.d(TAG, "Image cache download failed for $source: ${error.message}")
            return null
        } finally {
            if (activeImagePrefetchConnection === connection) {
                activeImagePrefetchConnection = null
            }
            connection?.disconnect()
            if (tempFile.exists()) {
                tempFile.delete()
            }
        }
    }

    private fun hasWebpSignature(file: File): Boolean {
        if (!file.isFile || file.length() < 12L) {
            return false
        }
        return try {
            val header = ByteArray(12)
            FileInputStream(file).use { input ->
                var offset = 0
                while (offset < header.size) {
                    val readBytes = input.read(header, offset, header.size - offset)
                    if (readBytes < 0) {
                        return false
                    }
                    offset += readBytes
                }
            }
            header[0] == 'R'.code.toByte() &&
                header[1] == 'I'.code.toByte() &&
                header[2] == 'F'.code.toByte() &&
                header[3] == 'F'.code.toByte() &&
                header[8] == 'W'.code.toByte() &&
                header[9] == 'E'.code.toByte() &&
                header[10] == 'B'.code.toByte() &&
                header[11] == 'P'.code.toByte()
        } catch (_: Throwable) {
            false
        }
    }

    private fun trimImageCache(protectedFile: File? = null) {
        try {
            val files = imageCacheDir.listFiles()
                ?.filter { it.isFile && it.extension.equals("webp", ignoreCase = true) }
                ?.sortedBy { it.lastModified() }
                .orEmpty()
            var totalBytes = files.sumOf { it.length() }
            for (file in files) {
                if (totalBytes <= imageCacheMaxBytes) {
                    break
                }
                if (file == protectedFile) {
                    continue
                }
                val fileBytes = file.length()
                if (file.delete()) {
                    totalBytes -= fileBytes
                }
            }
        } catch (error: Throwable) {
            Log.d(TAG, "Image cache trim failed: ${error.message}")
        }
    }

    private fun hashImageCacheKey(source: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(source.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    private fun imageCacheFileForSource(source: String): File {
        return File(imageCacheDir, "${hashImageCacheKey(source)}.webp")
    }

    private fun setBackgroundPrefetchPriority() {
        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
        } catch (_: Throwable) {
            // Prefetch remains safe on its dedicated executor if priority adjustment is unavailable.
        }
    }

    private fun handleSetPlaylist(json: JSONObject) {
        val ownerId = json.optString("ownerId")
        if (ownerId.isEmpty()) {
            return
        }

        val listJson = json.optJSONArray("playlist") ?: return
        val nextPlaylist = mutableListOf<String>()
        for (i in 0 until listJson.length()) {
            val item = listJson.optString(i)
            if (item.isNotBlank()) {
                nextPlaylist.add(item)
            }
        }
        if (nextPlaylist.isEmpty()) {
            clearNativeVideo()
            return
        }

        cancelPendingClear()
        val nextPlaybackMode = if (json.optString("playbackMode") == "ordered") {
            PlaybackMode.ORDERED
        } else {
            PlaybackMode.RANDOM
        }
        val nextPlaylistKey = "${nextPlaybackMode.name}\u0000${nextPlaylist.joinToString("\u0001")}"
        val samePlaylist = ownerId == currentOwnerId &&
            nextPlaylistKey == currentPlaylistKey &&
            playlist.isNotEmpty() &&
            (player?.mediaItemCount ?: 0) > 0

        // Keep scene transitions enabled; low-performance mode should reduce
        // heavy visual effects (blur/backdrop) but not remove transitions.
        currentDimAlpha = json.optDouble("dimAlpha", 0.0).toFloat().coerceIn(0f, 1f)
        storePlacement(json.optJSONObject("rect"))
        if (samePlaylist) {
            Log.d(TAG, "setPlaylist skipped restart (same owner/playlist), owner=$ownerId")
            applyStoredPlacement()
            if (!waitingForFirstFrame) {
                // While the first frame is still pending, readiness is reported
                // by the reveal path.
                notifyNativeVideoReady(ownerId)
            }
            return
        }

        // A live pipeline (video→video scene switch) is handed over to the new
        // playlist instead of being torn down — same mechanism as clip changes
        // inside one scene, so there is no black gap.
        val canHandover = !waitingForFirstFrame &&
            videoLayer.visibility == View.VISIBLE &&
            videoPlayerView.alpha == 1f &&
            (player?.mediaItemCount ?: 0) > 0

        currentOwnerId = ownerId
        playlist = nextPlaylist
        currentPlaylistKey = nextPlaylistKey
        currentPlaybackMode = nextPlaybackMode

        // Cache-only playback: never stream to the screen. If nothing from
        // this playlist is on disk yet, keep the page rendering the scene
        // opaquely, download the first clip with priority and start playback
        // the moment it lands.
        val hasCachedClip = playlist.any { hasCachedDataForSource(it) }
        Log.d(
            TAG,
            "setPlaylist owner=$ownerId tracks=${nextPlaylist.size} mode=$nextPlaybackMode " +
                "handover=$canHandover cached=$hasCachedClip",
        )
        if (!hasCachedClip) {
            awaitingFirstCachedClip = true
            enterAwaitingCachedState()
            // Random playlists start from a random clip — otherwise every
            // cold start would show the same (newest) clip of the category.
            startPriorityClipDownload(
                if (currentPlaybackMode == PlaybackMode.RANDOM) playlist.random() else playlist.first(),
            )
            return
        }

        awaitingFirstCachedClip = false
        applyStoredPlacement()
        refillQueue(avoidCurrent = false)
        if (canHandover) {
            handoverToNewPlaylist()
        } else {
            hideUntilFirstFrame()
            startPlaybackPipeline()
        }
        scheduleVideoPrefetch(playlist)
    }

    // No cached clip to show: hide the native layer entirely and let the page
    // render the scene with its normal background — no transparent hole, no
    // black shutter — while the priority download fills the cache.
    private fun enterAwaitingCachedState() {
        firstFrameWaitToken += 1
        waitingForFirstFrame = false
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = false
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoPlayerView.alpha = 0f
        videoLayer.visibility = View.GONE
        webView.setBackgroundColor(Color.TRANSPARENT)
        player?.stop()
        syncPageTransparencyForNativeVideo(webView)
    }

    // Downloads one clip at full speed (unlike the throttled background
    // prefetch — this one gates the scene's video) and starts playback once
    // it is fully cached. Retries while the playlist stays current.
    private fun startPriorityClipDownload(source: String) {
        val playlistKeySnapshot = currentPlaylistKey
        cancelVideoPrefetch()
        val token = ++prefetchToken
        Log.i(TAG, "priority caching first clip: $source")
        prefetchFuture = prefetchExecutor.submit {
            var success = false
            var writer: CacheWriter? = null
            try {
                val uri = Uri.parse(source)
                val dataSpec = DataSpec.Builder()
                    .setUri(uri)
                    .setKey(buildVideoCacheKey(uri))
                    .build()
                val cacheWriter = CacheWriter(
                    playbackCacheDataSourceFactory.createDataSource(),
                    dataSpec,
                    null,
                    null,
                )
                writer = cacheWriter
                activeCacheWriter = cacheWriter
                cacheWriter.cache()
                success = true
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return@submit
            } catch (error: Throwable) {
                Log.d(TAG, "Priority clip caching failed for $source: ${error.message}")
            } finally {
                if (activeCacheWriter === writer) {
                    activeCacheWriter = null
                }
            }
            if (token != prefetchToken) {
                return@submit
            }
            runOnUiThread {
                if (token != prefetchToken || !awaitingFirstCachedClip || currentPlaylistKey != playlistKeySnapshot) {
                    return@runOnUiThread
                }
                if (success && hasCachedDataForSource(source)) {
                    startPlaybackFromCache()
                } else {
                    playbackGuardHandler.postDelayed(
                        {
                            if (awaitingFirstCachedClip && currentPlaylistKey == playlistKeySnapshot) {
                                startPriorityClipDownload(source)
                            }
                        },
                        PRIORITY_CLIP_RETRY_MS,
                    )
                }
            }
        }
    }

    private fun startPlaybackFromCache() {
        Log.i(TAG, "first clip cached, starting playback")
        awaitingFirstCachedClip = false
        applyStoredPlacement()
        refillQueue(avoidCurrent = false)
        beginQuietFirstFrameWait()
        startPlaybackPipeline()
        scheduleVideoPrefetch(playlist)
    }

    // The page announces the clips the UPCOMING scene will need. Make sure a
    // couple of them are fully cached before the switch, so cache-only
    // playback has something to show immediately. Deliberately never downloads
    // the whole list — category playlists can hold hundreds of clips; the rest
    // trickle in via the regular background prefetch across rotations.
    private fun handlePrecache(json: JSONObject) {
        if (awaitingFirstCachedClip) {
            // The full-speed first-clip download owns the link right now.
            return
        }
        val listJson = json.optJSONArray("sources") ?: return
        val sources = buildList {
            for (i in 0 until minOf(listJson.length(), PRECACHE_MAX_SOURCES)) {
                val item = listJson.optString(i)
                if (item.isNotBlank()) {
                    add(item)
                }
            }
        }.distinct()
        if (sources.isEmpty()) {
            return
        }

        val ordered = json.optString("playbackMode") == "ordered"
        val requestKey = "${if (ordered) "O" else "R"} ${sources.joinToString("")}"
        if (requestKey == lastPrecacheKey && prefetchFuture?.isDone == false) {
            // Same announcement re-sent while the previous run is still going.
            return
        }

        val cachedCount = sources.count { hasCachedDataForSource(it) }
        val need = PRECACHE_CLIPS_PER_SCENE - cachedCount
        if (need <= 0) {
            return
        }
        val candidates = (if (ordered) sources else sources.shuffled())
            .filter { !hasCachedDataForSource(it) }
            .take(need)
        if (candidates.isEmpty()) {
            return
        }

        Log.i(TAG, "precache: announced=${sources.size} cached=$cachedCount downloading=${candidates.size}")
        lastPrecacheKey = requestKey
        cancelVideoPrefetch()
        val token = ++prefetchToken
        val resumePlaylist = playlist
        prefetchFuture = prefetchExecutor.submit {
            setBackgroundPrefetchPriority()
            for (source in candidates) {
                if (Thread.currentThread().isInterrupted || token != prefetchToken) {
                    return@submit
                }
                try {
                    mediaPrefetchPermit.acquire()
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return@submit
                }
                try {
                    if (token != prefetchToken) {
                        return@submit
                    }
                    var writer: CacheWriter? = null
                    try {
                        val uri = Uri.parse(source)
                        val dataSpec = DataSpec.Builder()
                            .setUri(uri)
                            .setKey(buildVideoCacheKey(uri))
                            .build()
                        val cacheWriter = CacheWriter(
                            precacheCacheDataSourceFactory.createDataSource(),
                            dataSpec,
                            null,
                            null,
                        )
                        writer = cacheWriter
                        activeCacheWriter = cacheWriter
                        cacheWriter.cache()
                        Log.i(TAG, "precache done: $source")
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return@submit
                    } catch (error: Throwable) {
                        Log.d(TAG, "precache failed for $source: ${error.message}")
                    } finally {
                        if (activeCacheWriter === writer) {
                            activeCacheWriter = null
                        }
                    }
                } finally {
                    mediaPrefetchPermit.release()
                }
            }
            // Precache preempted the current scene's trickle — resume it.
            if (token == prefetchToken && resumePlaylist.isNotEmpty()) {
                runOnUiThread {
                    if (token == prefetchToken && playlist == resumePlaylist) {
                        scheduleVideoPrefetch(playlist)
                    }
                }
            }
        }
    }

    // Video→video scene switch without tearing the pipeline down: trim the old
    // queue after the playing item, queue the new scene's first clip and cut to
    // it. The codec and surface stay alive, so the old clip's last frame holds
    // on screen until the new clip's first frame renders — no black gap.
    private fun handoverToNewPlaylist() {
        val instance = player
        val firstIndex = nextIndex()
        val mediaItem = if (firstIndex in playlist.indices) createMediaItemForIndex(firstIndex) else null
        if (instance == null || mediaItem == null) {
            hideUntilFirstFrame()
            startPlaybackPipeline()
            return
        }

        val playingItemIndex = instance.currentMediaItemIndex
        val itemCount = instance.mediaItemCount
        if (itemCount > playingItemIndex + 1) {
            for (i in playingItemIndex + 1 until itemCount) {
                mediaIdToPlaylistIndex.remove(instance.getMediaItemAt(i).mediaId)
            }
            instance.removeMediaItems(playingItemIndex + 1, itemCount)
        }
        // The still-playing item's id maps into the REPLACED playlist — drop it
        // so onMediaItemTransition can't resolve it against the new one.
        instance.currentMediaItem?.mediaId?.let(mediaIdToPlaylistIndex::remove)

        currentIndex = firstIndex
        instance.addMediaItem(mediaItem)
        instance.seekToNextMediaItem()
        instance.playWhenReady = true
        instance.play()
        markPlaybackProgressIfAdvanced(forceRefresh = true)
    }

    private fun clearNativeVideo() {
        Log.d(TAG, "clearNativeVideo")
        cancelPendingClear()
        cancelVideoPrefetch()
        stopPlaybackGuard()
        playlist = emptyList()
        playQueue.clear()
        mediaIdToPlaylistIndex.clear()
        mediaIdSerial = 0
        currentIndex = -1
        currentOwnerId = null
        currentPlaylistKey = ""
        currentPlaybackMode = PlaybackMode.RANDOM
        currentPlacement = null
        firstFrameWaitToken += 1
        waitingForFirstFrame = false
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = false
        awaitingFirstCachedClip = false
        realignedAtReveal = false
        firstFrameWaitStartedAtMs = 0L
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoPlayerView.alpha = 0f
        dimOverlayView.alpha = 0f
        videoLayer.visibility = View.GONE
        resetPlaybackGuardState()
        player?.stop()
    }

    private fun scheduleVideoPrefetch(playlistSnapshot: List<String>) {
        // Playback itself writes the active clip to cache. Excluding it here
        // avoids a second concurrent HTTP request for the same video.
        val activeSource = playlistSnapshot.getOrNull(currentIndex)
        val targets = playlistSnapshot
            .asSequence()
            .filter { it.isNotBlank() }
            .filter { it != activeSource }
            .distinct()
            .toList()
            // The backend returns categories newest-first. Downloading in that
            // order made the cache — and therefore the cache-only rotation — a
            // deterministic "top of the list" sample. Shuffling the download
            // order makes the cache a RANDOM sample of the category, so the
            // rotation reproduces the web player's random mechanics.
            .let { if (currentPlaybackMode == PlaybackMode.RANDOM) it.shuffled() else it }
            .take(VIDEO_PREFETCH_MAX_ITEMS)

        cancelVideoPrefetch()
        if (targets.isEmpty() || videoCacheMaxBytes <= 0L) {
            return
        }

        val token = ++prefetchToken
        prefetchFuture = prefetchExecutor.submit {
            setBackgroundPrefetchPriority()
            for (source in targets) {
                if (Thread.currentThread().isInterrupted || token != prefetchToken) {
                    return@submit
                }
                // Let LRU evict older scenes while this pass makes the active scene recent.
                // Stopping based on total cache size would leave new scenes network-only.
                try {
                    mediaPrefetchPermit.acquire()
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return@submit
                }
                try {
                    if (token != prefetchToken) {
                        return@submit
                    }
                    prefetchVideoToCache(source, token)
                } finally {
                    mediaPrefetchPermit.release()
                }
            }
        }
    }

    private fun cancelVideoPrefetch() {
        prefetchToken += 1
        try {
            activeCacheWriter?.cancel()
        } catch (_: Throwable) {
            // no-op
        }
        prefetchFuture?.cancel(true)
        prefetchFuture = null
    }

    private fun prefetchVideoToCache(source: String, token: Int) {
        var writer: CacheWriter? = null
        try {
            if (token != prefetchToken) {
                return
            }
            val uri = Uri.parse(source)
            // No length set -> DataSpec defaults to the whole resource, so the clip is
            // cached in full and can play end-to-end offline.
            val dataSpec = DataSpec.Builder()
                .setUri(uri)
                .setKey(buildVideoCacheKey(uri))
                .build()
            val cacheWriter = CacheWriter(
                prefetchCacheDataSourceFactory.createDataSource(),
                dataSpec,
                null,
                null,
            )
            writer = cacheWriter
            activeCacheWriter = cacheWriter
            cacheWriter.cache()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (error: Throwable) {
            Log.d(TAG, "Video prefetch skipped for $source: ${error.message}")
        } finally {
            if (activeCacheWriter === writer) {
                activeCacheWriter = null
            }
        }
    }

    private fun tryPlayCachedFallback(): Boolean {
        val instance = player ?: return false
        if (playlist.isEmpty()) {
            return false
        }
        val currentMediaId = instance.currentMediaItem?.mediaId.orEmpty()
        if (currentMediaId.startsWith("fallback-")) {
            return false
        }

        val candidateSources = if (currentPlaybackMode == PlaybackMode.ORDERED && currentIndex >= 0) {
            (1..playlist.size).map { offset -> playlist[(currentIndex + offset) % playlist.size] }
        } else {
            playlist.shuffled()
        }
        val currentSource = playlist.getOrNull(currentIndex)
        val fallbackSource = candidateSources
            .asSequence()
            .filter { it.isNotBlank() && it != currentSource }
            .filter { hasCachedDataForSource(it) }
            .firstOrNull()
            ?: return false
        val fallbackIndex = playlist.indexOf(fallbackSource)
        val mediaItem = createFallbackMediaItem(fallbackSource, fallbackIndex)
        Log.w(TAG, "Using cached fallback clip: $fallbackSource")
        instance.stop()
        instance.clearMediaItems()
        instance.addMediaItem(mediaItem)
        instance.prepare()
        instance.playWhenReady = true
        instance.play()
        return true
    }

    private fun hasCachedDataForSource(source: String): Boolean {
        val key = buildVideoCacheKey(Uri.parse(source))
        if (key == "video:unknown") {
            return false
        }
        return try {
            val contentLength = ContentMetadata.getContentLength(
                videoCache.getContentMetadata(key),
            )
            contentLength > 0L && videoCache.isCached(key, 0L, contentLength)
        } catch (_: Throwable) {
            false
        }
    }

    private fun createFallbackMediaItem(source: String, playlistIndex: Int): MediaItem {
        val mediaId = "fallback-${mediaIdSerial++}"
        if (playlistIndex >= 0) {
            mediaIdToPlaylistIndex[mediaId] = playlistIndex
        }
        return MediaItem.Builder()
            .setUri(Uri.parse(source))
            .setMediaId(mediaId)
            .build()
    }

    private fun refillQueue(avoidCurrent: Boolean) {
        playQueue.clear()
        if (playlist.isEmpty()) {
            return
        }

        // Cache-only playback: the rotation only ever includes fully cached
        // clips. The background prefetch keeps caching the rest; they join
        // automatically on the next refill.
        val indices = playlist.indices.filter { hasCachedDataForSource(playlist[it]) }.toMutableList()
        if (indices.isEmpty()) {
            return
        }
        if (currentPlaybackMode == PlaybackMode.ORDERED) {
            if (avoidCurrent && currentIndex >= 0 && indices.size > 1) {
                // Rotate so the queue starts at the first cached index after
                // the current one, wrapping around.
                val startPos = indices.indexOfFirst { it > currentIndex }.let { if (it < 0) 0 else it }
                val rotated = ArrayList<Int>(indices.size)
                rotated.addAll(indices.subList(startPos, indices.size))
                rotated.addAll(indices.subList(0, startPos))
                indices.clear()
                indices.addAll(rotated)
            }
        } else {
            indices.shuffle()
            if (avoidCurrent && currentIndex >= 0 && indices.size > 1 && indices[0] == currentIndex) {
                val swapAt = indices.indexOfFirst { it != currentIndex }
                if (swapAt > 0) {
                    val first = indices[0]
                    indices[0] = indices[swapAt]
                    indices[swapAt] = first
                }
            }
        }
        playQueue.addAll(indices)
    }

    private fun nextIndex(): Int {
        if (playlist.isEmpty()) {
            return -1
        }
        if (playQueue.isEmpty()) {
            refillQueue(avoidCurrent = true)
        }
        return if (playQueue.isEmpty()) -1 else playQueue.removeAt(0)
    }

    private fun createMediaItemForIndex(index: Int): MediaItem? {
        val source = playlist.getOrNull(index) ?: return null
        val mediaId = "tunio-${mediaIdSerial++}-$index"
        mediaIdToPlaylistIndex[mediaId] = index
        return MediaItem.Builder()
            .setUri(Uri.parse(source))
            .setMediaId(mediaId)
            .build()
    }

    private fun addNextMediaItem(): Boolean {
        val index = nextIndex()
        if (index < 0 || index >= playlist.size) {
            return false
        }
        val mediaItem = createMediaItemForIndex(index) ?: return false
        player?.addMediaItem(mediaItem)
        return true
    }

    private fun startPlaybackPipeline() {
        if (playlist.isEmpty()) {
            return
        }

        resetPlaybackGuardState()
        startPlaybackGuard()

        player?.apply {
            stop()
            clearMediaItems()
        }
        mediaIdToPlaylistIndex.clear()
        mediaIdSerial = 0
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f

        val firstIndex = nextIndex()
        if (firstIndex < 0 || firstIndex >= playlist.size) {
            return
        }
        currentIndex = firstIndex

        val firstMediaItem = createMediaItemForIndex(firstIndex) ?: return
        player?.apply {
            addMediaItem(firstMediaItem)
            addNextMediaItem()
            prepare()
            playWhenReady = true
            play()
        }
    }

    private fun hideUntilFirstFrame() {
        firstFrameWaitToken += 1
        waitingForFirstFrame = true
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = false
        realignedAtReveal = false
        firstFrameWaitStartedAtMs = SystemClock.elapsedRealtime()
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 1f
        videoPlayerView.alpha = 0f
        webView.setBackgroundColor(Color.BLACK)
        syncPageTransparencyForNativeVideo(webView)
    }

    // Quiet variant of hideUntilFirstFrame: the video joins a scene that is
    // already on screen (its first clip just finished caching), so the page
    // keeps rendering the scene opaquely instead of blacking out; the video
    // reveals on its first frame.
    private fun beginQuietFirstFrameWait() {
        firstFrameWaitToken += 1
        waitingForFirstFrame = true
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = true
        realignedAtReveal = false
        firstFrameWaitStartedAtMs = SystemClock.elapsedRealtime()
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoPlayerView.alpha = 0f
        syncPageTransparencyForNativeVideo(webView)
    }

    private fun scheduleFirstFrameReadyFallback() {
        val token = firstFrameWaitToken
        val ownerId = currentOwnerId
        playbackGuardHandler.postDelayed(
            {
                if (
                    !waitingForFirstFrame ||
                    token != firstFrameWaitToken ||
                    ownerId != currentOwnerId ||
                    player?.playbackState != Player.STATE_READY
                ) {
                    return@postDelayed
                }

                // This fallback is only for decoders that never emit
                // onRenderedFirstFrame; realign hidden playback to zero and
                // reveal the layer.
                player?.pause()
                player?.seekTo(0)
                player?.playWhenReady = true
                player?.play()
                pendingRevealAfterTransform = true
                maybeRevealVideoAfterFirstFrame()
            },
            FIRST_FRAME_READY_FALLBACK_MS,
        )
    }

    private fun maybeRevealVideoAfterFirstFrame() {
        if (!waitingForFirstFrame || !pendingRevealAfterTransform) {
            return
        }
        if (!applyVideoCenterCropTransform()) {
            return
        }
        // The clip has been playing hidden while the reveal was blocked (slow
        // layout / busy WebView). Realign to zero once so the audience never
        // sees a clip start from its middle; the reveal then happens on the
        // frame the seek renders.
        val instance = player
        if (instance != null && !realignedAtReveal && instance.currentPosition > REVEAL_REALIGN_THRESHOLD_MS) {
            Log.d(TAG, "reveal realign: clip drifted to ${instance.currentPosition}ms while hidden, seeking to 0")
            realignedAtReveal = true
            pendingRevealAfterTransform = false
            instance.seekTo(0)
            return
        }
        waitingForFirstFrame = false
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = false
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoPlayerView.alpha = 1f
        webView.setBackgroundColor(Color.TRANSPARENT)
        syncPageTransparencyForNativeVideo(webView)
        notifyNativeVideoReady(currentOwnerId)
    }

    private fun ensureQueueDepth() {
        if (playlist.isEmpty()) {
            return
        }
        // Keep a following item queued even for a one-clip playlist. Media3 can
        // then loop gaplessly instead of reaching ENDED and releasing the codec
        // on every second pass.
        val targetQueueDepth = 2
        while ((player?.mediaItemCount ?: 0) < targetQueueDepth) {
            if (!addNextMediaItem()) {
                break
            }
        }
    }

    private fun dropPlayedItems() {
        val instance = player ?: return
        val removeCount = instance.currentMediaItemIndex
        if (removeCount <= 0) {
            return
        }

        for (i in 0 until removeCount) {
            val mediaId = instance.getMediaItemAt(i).mediaId
            mediaIdToPlaylistIndex.remove(mediaId)
        }
        instance.removeMediaItems(0, removeCount)
    }

    private fun hardCutToNext() {
        if (playlist.isEmpty()) {
            return
        }
        val instance = player
        val queuedNextIndex = instance
            ?.takeIf { it.currentMediaItemIndex + 1 < it.mediaItemCount }
            ?.getMediaItemAt(instance.currentMediaItemIndex + 1)
            ?.mediaId
            ?.let(mediaIdToPlaylistIndex::get)
        val index = queuedNextIndex ?: nextIndex()
        if (index < 0 || index >= playlist.size) {
            return
        }

        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        mediaIdToPlaylistIndex.clear()
        mediaIdSerial = 0
        currentIndex = index

        val mediaItem = createMediaItemForIndex(index) ?: return
        player?.apply {
            stop()
            clearMediaItems()
            addMediaItem(mediaItem)
            addNextMediaItem()
            prepare()
            playWhenReady = true
            play()
        }
    }

    private fun startPlaybackGuard() {
        if (playbackGuardRunnable != null) {
            return
        }

        playbackGuardRunnable = object : Runnable {
            override fun run() {
                runPlaybackGuardCycle()
                playbackGuardHandler.postDelayed(this, PLAYBACK_GUARD_CHECK_INTERVAL_MS)
            }
        }.also { runnable ->
            playbackGuardHandler.postDelayed(runnable, PLAYBACK_GUARD_CHECK_INTERVAL_MS)
        }
    }

    private fun stopPlaybackGuard() {
        playbackGuardRunnable?.let { playbackGuardHandler.removeCallbacks(it) }
        playbackGuardRunnable = null
    }

    private fun resetPlaybackGuardState() {
        lastObservedPlaybackPositionMs = -1L
        lastPlaybackProgressRealtimeMs = 0L
        lastRecoveryAttemptRealtimeMs = 0L
    }

    private fun markPlaybackProgressIfAdvanced(forceRefresh: Boolean = false) {
        val instance = player ?: return
        val now = SystemClock.elapsedRealtime()
        val currentPosition = instance.currentPosition.coerceAtLeast(0L)
        val hasAdvanced = lastObservedPlaybackPositionMs < 0L ||
            currentPosition >= (lastObservedPlaybackPositionMs + PLAYBACK_PROGRESS_EPSILON_MS)

        if (forceRefresh || hasAdvanced) {
            lastObservedPlaybackPositionMs = currentPosition
            lastPlaybackProgressRealtimeMs = now
        }
    }

    private fun runPlaybackGuardCycle() {
        val instance = player ?: return
        if (playlist.isEmpty() || videoLayer.visibility != View.VISIBLE) {
            return
        }

        if (waitingForFirstFrame) {
            val waitedMs = SystemClock.elapsedRealtime() - firstFrameWaitStartedAtMs
            if (firstFrameWaitStartedAtMs > 0L && waitedMs >= FIRST_FRAME_STALL_TIMEOUT_MS) {
                Log.w(TAG, "PlaybackGuard: no first frame after ${waitedMs}ms, recovering")
                firstFrameWaitStartedAtMs = SystemClock.elapsedRealtime()
                if (!tryPlayCachedFallback()) {
                    hardCutToNext()
                }
            }
            return
        }

        markPlaybackProgressIfAdvanced()

        val now = SystemClock.elapsedRealtime()
        val playbackState = instance.playbackState
        val stallDurationMs = if (lastPlaybackProgressRealtimeMs <= 0L) 0L else now - lastPlaybackProgressRealtimeMs

        if (!instance.playWhenReady) {
            Log.w(TAG, "PlaybackGuard recovery: playWhenReady=false")
            instance.playWhenReady = true
            instance.play()
            markPlaybackProgressIfAdvanced(forceRefresh = true)
            return
        }

        if (playbackState == Player.STATE_IDLE) {
            recoverPlayback("state=IDLE")
            return
        }

        val potentiallyStalledState = playbackState == Player.STATE_READY || playbackState == Player.STATE_BUFFERING
        if (potentiallyStalledState && stallDurationMs >= PLAYBACK_GUARD_STALL_TIMEOUT_MS) {
            recoverPlayback("no progress for ${stallDurationMs}ms, state=$playbackState")
        }
    }

    private fun recoverPlayback(reason: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastRecoveryAttemptRealtimeMs < PLAYBACK_GUARD_RECOVERY_COOLDOWN_MS) {
            return
        }
        lastRecoveryAttemptRealtimeMs = now

        val instance = player ?: return
        Log.w(TAG, "PlaybackGuard recovery: $reason")

        if (instance.mediaItemCount == 0) {
            startPlaybackPipeline()
            return
        }

        when (instance.playbackState) {
            Player.STATE_ENDED -> {
                hardCutToNext()
                return
            }
            Player.STATE_IDLE -> {
                instance.prepare()
                instance.playWhenReady = true
                instance.play()
                markPlaybackProgressIfAdvanced(forceRefresh = true)
            }
            Player.STATE_READY,
            Player.STATE_BUFFERING,
            -> {
                // play() cannot heal a stuck decoder in READY/BUFFERING. Rebuild
                // the pipeline (or use another fully cached clip from this same
                // scene) so a frozen frame cannot persist forever.
                if (!tryPlayCachedFallback()) {
                    hardCutToNext()
                }
            }
            else -> Unit
        }
    }

    // Tells the SPA the current playlist rendered a frame — the player gates
    // scene switches on this event during prewarm.
    private fun notifyNativeVideoReady(ownerId: String?) {
        if (ownerId.isNullOrEmpty()) {
            return
        }
        val safeOwnerId = ownerId.replace("\\", "").replace("'", "").replace("\"", "")
        webView.evaluateJavascript(
            """
            (function() {
              try {
                var detail = { ownerId: '$safeOwnerId' };
                var event;
                try {
                  event = new CustomEvent('tunio-native-video-ready', { detail: detail });
                } catch (e) {
                  event = document.createEvent('CustomEvent');
                  event.initCustomEvent('tunio-native-video-ready', false, false, detail);
                }
                window.dispatchEvent(event);
              } catch (e) {}
            })();
            """.trimIndent(),
            null,
        )
    }

    // Stores the placement without touching the layer: while nothing is cached
    // the video layer must stay hidden, so showing it is a separate step
    // (applyStoredPlacement) taken only when playback actually starts.
    private fun storePlacement(rect: JSONObject?) {
        currentPlacement = VideoPlacement(
            x = rect?.optDouble("x", 0.0)?.toFloat() ?: 0f,
            y = rect?.optDouble("y", 0.0)?.toFloat() ?: 0f,
            width = rect?.optDouble("width", 100.0)?.toFloat() ?: 100f,
            height = rect?.optDouble("height", 100.0)?.toFloat() ?: 100f,
        )
    }

    private fun applyStoredPlacement() {
        val placement = currentPlacement ?: return
        applyPlacement(placement, currentDimAlpha)
    }

    private fun applyPlacement(placement: VideoPlacement, dimAlpha: Float) {
        rootLayout.post {
            val rootW = rootLayout.width.coerceAtLeast(1)
            val rootH = rootLayout.height.coerceAtLeast(1)
            if (isPlacementFullBleed(placement)) {
                // Full-bleed video needs no page geometry: lay the layer out
                // immediately. Waiting for the WebView JS roundtrip here used
                // to gate the first-frame reveal for seconds during scene
                // switches (the page's JS thread is saturated right then), so
                // the clip played hidden and appeared mid-clip.
                applyResolvedPlacement(placement, dimAlpha, null, rootW, rootH)
                return@post
            }
            resolveSceneViewportRect { viewport ->
                applyResolvedPlacement(placement, dimAlpha, viewport, rootW, rootH)
            }
        }
    }

    private fun applyResolvedPlacement(
        placement: VideoPlacement,
        dimAlpha: Float,
        viewport: RectF?,
        rootW: Int,
        rootH: Int,
    ) {
        val useViewport = viewport != null
        val containerLeft = if (useViewport) viewport!!.left else 0f
        val containerTop = if (useViewport) viewport!!.top else 0f
        val containerW = if (useViewport) viewport!!.width().coerceAtLeast(1f) else rootW.toFloat()
        val containerH = if (useViewport) viewport!!.height().coerceAtLeast(1f) else rootH.toFloat()

        val left = (containerLeft + (containerW * (placement.x / 100f))).roundToInt().coerceAtLeast(0)
        val top = (containerTop + (containerH * (placement.y / 100f))).roundToInt().coerceAtLeast(0)
        val w = (containerW * (placement.width / 100f)).roundToInt().coerceAtLeast(1)
        val h = (containerH * (placement.height / 100f)).roundToInt().coerceAtLeast(1)

        val params = FrameLayout.LayoutParams(w, h).apply {
            leftMargin = left
            topMargin = top
        }

        videoLayer.layoutParams = params
        videoLayer.visibility = View.VISIBLE
        if (applyVideoCenterCropTransform()) {
            maybeRevealVideoAfterFirstFrame()
        }
        dimOverlayView.alpha = dimAlpha.coerceIn(0f, 1f)
    }

    private fun isPlacementFullBleed(placement: VideoPlacement): Boolean {
        fun close(a: Float, b: Float): Boolean = kotlin.math.abs(a - b) <= 0.01f
        return close(placement.x, 0f) &&
            close(placement.y, 0f) &&
            close(placement.width, 100f) &&
            close(placement.height, 100f)
    }

    private fun resolveSceneViewportRect(onResolved: (RectF?) -> Unit) {
        val script = """
            (function() {
              try {
                var root = document.getElementById('tunio-screen-player-root');
                var viewport = document.getElementById('tunio-scene-viewport');
                if (!root || !viewport) return '';
                var rootRect = root.getBoundingClientRect();
                var viewportRect = viewport.getBoundingClientRect();
                var dpr = Number(window.devicePixelRatio || 1);
                if (!isFinite(dpr) || dpr <= 0) dpr = 1;
                return [
                  viewportRect.left - rootRect.left,
                  viewportRect.top - rootRect.top,
                  viewportRect.width,
                  viewportRect.height,
                  dpr
                ].join(',');
              } catch (e) {
                return '';
              }
            })();
        """.trimIndent()

        webView.evaluateJavascript(script) { rawResult ->
            val parsed = parseSceneViewportRect(rawResult)
            if (parsed != null) {
                cachedSceneViewportRect = parsed
                onResolved(parsed)
            } else {
                onResolved(cachedSceneViewportRect)
            }
        }
    }

    private fun parseSceneViewportRect(rawResult: String?): RectF? {
        val cleaned = rawResult?.trim().orEmpty()
        if (cleaned.isEmpty() || cleaned == "null" || cleaned == "\"\"") {
            return null
        }

        val unquoted = if (cleaned.length >= 2 && cleaned.first() == '"' && cleaned.last() == '"') {
            cleaned.substring(1, cleaned.length - 1)
        } else {
            cleaned
        }

        val normalized = unquoted
            .replace("\\\\", "\\")
            .replace("\\\"", "\"")
        val parts = normalized.split(',')
        if (parts.size < 4) {
            return null
        }

        val left = parts[0].toFloatOrNull() ?: return null
        val top = parts[1].toFloatOrNull() ?: return null
        val width = parts[2].toFloatOrNull() ?: return null
        val height = parts[3].toFloatOrNull() ?: return null
        val dpr = if (parts.size >= 5) {
            parts[4].toFloatOrNull()?.takeIf { it > 0f } ?: 1f
        } else {
            1f
        }
        if (width <= 0f || height <= 0f) {
            return null
        }

        val scaledLeft = left * dpr
        val scaledTop = top * dpr
        val scaledWidth = width * dpr
        val scaledHeight = height * dpr
        return RectF(scaledLeft, scaledTop, scaledLeft + scaledWidth, scaledTop + scaledHeight)
    }

    private fun applyVideoCenterCropTransform(): Boolean {
        val viewW = videoPlayerView.width
        val viewH = videoPlayerView.height

        if (viewW <= 0 || viewH <= 0) {
            return false
        }

        return true
    }

    private inner class NativeVideoJsBridge {
        @JavascriptInterface
        fun isAvailable(): Boolean = true

        // The SPA probes this before offloading features to the native layer;
        // older APKs lack the method, so the web falls back to DOM rendering.
        @JavascriptInterface
        fun getCapabilities(): String = """{"nativeVideo":true,"nativeMarquee":true}"""

        @JavascriptInterface
        fun postMessage(payload: String?) {
            if (payload.isNullOrBlank()) {
                return
            }
            runOnUiThread {
                handleNativeVideoMessage(payload)
            }
        }
    }

    private inner class NativeImageCacheJsBridge {
        @JavascriptInterface
        fun postMessage(payload: String?) {
            if (payload.isNullOrBlank()) {
                return
            }
            handleNativeImageCacheMessage(payload)
        }
    }
}
