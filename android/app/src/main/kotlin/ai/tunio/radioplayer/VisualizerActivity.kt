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
import android.webkit.WebChromeClient
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
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.random.Random
import kotlin.math.abs
import kotlin.math.roundToInt

class VisualizerActivity : Activity() {
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
        // Hard ceiling for the on-disk video cache. The effective cap is
        // min(this, a fraction of currently-free space) — see resolveVideoCacheMaxBytes.
        private const val VIDEO_CACHE_MAX_BYTES = 3L * 1024L * 1024L * 1024L // 3 GB
        // Always keep at least this much free on the volume the cache lives on.
        private const val VIDEO_CACHE_FREE_SPACE_RESERVE_BYTES = 1L * 1024L * 1024L * 1024L // 1 GB
        // Never use more than this fraction of the free space available at creation time.
        private const val VIDEO_CACHE_FREE_SPACE_FRACTION = 0.5
        // Stop prefetching once the cache is this full, so a pass never evicts the clips
        // it just wrote (the LRU evictor still hard-caps the total on disk regardless).
        private const val VIDEO_PREFETCH_CACHE_FILL_FRACTION = 0.9
        // How many distinct playlist clips to prefetch (whole clips, for offline playback).
        private const val VIDEO_PREFETCH_MAX_ITEMS = 64
        // How long a bridge "clear" waits before executing: the setPlaylist of
        // the next scene arrives within the same switch and cancels it, so the
        // last frame stays on screen instead of dropping to black.
        private const val CLEAR_HANDOVER_GRACE_MS = 350L
        private const val PLAYBACK_GUARD_CHECK_INTERVAL_MS = 3000L
        private const val PLAYBACK_GUARD_STALL_TIMEOUT_MS = 12000L
        private const val PLAYBACK_GUARD_RECOVERY_COOLDOWN_MS = 2500L
        private const val PLAYBACK_PROGRESS_EPSILON_MS = 250L

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
    private var currentDimAlpha: Float = 0f
    private var currentPlacement: VideoPlacement? = null
    private var cachedSceneViewportRect: RectF? = null
    private var transitionMs: Int = 0
    private var isTransitionRunning = false
    private var waitingForFirstFrame = false
    private var pendingRevealAfterTransform = false
    private var suppressWaitingBlackout = false
    private var pendingClearRunnable: Runnable? = null
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
    private val prefetchExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var prefetchFuture: Future<*>? = null
    @Volatile
    private var prefetchToken: Int = 0
    @Volatile
    private var activeCacheWriter: CacheWriter? = null
    private lateinit var videoCache: SimpleCache
    private var videoCacheMaxBytes: Long = VIDEO_CACHE_MAX_BYTES
    private val knownSources = linkedSetOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lowPerformanceMode = intent?.getBooleanExtra(EXTRA_LOW_PERFORMANCE_MODE, false) ?: false
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

                        // Keep transitions hard-cut here: visual overlay fade can drift
                        // behind the actual decoder frame switch on some devices.
                    }

                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_READY && waitingForFirstFrame) {
                            pendingRevealAfterTransform = true
                            maybeRevealVideoAfterFirstFrame()
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
                            // Last-frame handover path: the layer is already
                            // visible, just report readiness to the page.
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
                        waitingForFirstFrame = false
                        transitionOverlayView.alpha = 0f
                        if (tryPlayRandomCachedFallback()) {
                            return
                        }
                        hardCutToNext()
                    }
                },
            )
        }
    }

    private fun initVideoCaching() {
        val cacheDir = resolveVideoCacheDirectory()
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
        val cacheKeyFactory = CacheKeyFactory { dataSpec ->
            buildVideoCacheKey(dataSpec.uri)
        }
        Log.d(TAG, "Video cache directory: ${cacheDir.absolutePath}")

        // Playback must not write into cache on the critical rendering path.
        playbackCacheDataSourceFactory = CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstreamFactory)
            .setCacheKeyFactory(cacheKeyFactory)
            .setCacheWriteDataSinkFactory(null)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

        // Background prefetch fills cache out-of-band.
        prefetchCacheDataSourceFactory = CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstreamFactory)
            .setCacheKeyFactory(cacheKeyFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }

    private fun resolveVideoCacheDirectory(): File {
        val externalDirs = getExternalFilesDirs(null).filterNotNull()
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

        val internalDir = cacheDir.takeIf { ensureDirectoryWritable(it) }
        if (internalDir != null) {
            return File(internalDir, VIDEO_CACHE_DIR_NAME).apply { mkdirs() }
        }

        return File(cacheDir, VIDEO_CACHE_DIR_NAME).apply { mkdirs() }
    }

    // Size the cache from how much space the target volume actually has right now:
    // take at most VIDEO_CACHE_FREE_SPACE_FRACTION of the free space after reserving
    // VIDEO_CACHE_FREE_SPACE_RESERVE_BYTES, capped at VIDEO_CACHE_MAX_BYTES. This is
    // what keeps the flash from filling up and the box from hanging on a small drive.
    private fun resolveVideoCacheMaxBytes(cacheDir: File): Long {
        return try {
            val stat = StatFs(cacheDir.absolutePath)
            val usableFree = stat.availableBytes - VIDEO_CACHE_FREE_SPACE_RESERVE_BYTES
            if (usableFree <= 0L) {
                0L
            } else {
                (usableFree.toDouble() * VIDEO_CACHE_FREE_SPACE_FRACTION).toLong()
                    .coerceIn(0L, VIDEO_CACHE_MAX_BYTES)
            }
        } catch (error: Throwable) {
            Log.d(TAG, "Cache size probe failed, using default cap: ${error.message}")
            VIDEO_CACHE_MAX_BYTES
        }
    }

    private fun ensureDirectoryWritable(dir: File): Boolean {
        return try {
            if (!dir.exists() && !dir.mkdirs()) {
                return false
            }
            dir.isDirectory && dir.canWrite()
        } catch (_: Throwable) {
            false
        }
    }

    private fun buildVideoCacheKey(uri: Uri?): String {
        if (uri == null) {
            return "video:unknown"
        }

        val quality = uri.pathSegments
            .firstOrNull { it.equals("hd", ignoreCase = true) || it.equals("low", ignoreCase = true) }
            ?.lowercase()

        val fileName = uri.lastPathSegment
            ?.substringAfterLast('/')
            ?.substringBefore('?')
            ?.lowercase()
            .orEmpty()

        if (fileName.isNotEmpty()) {
            if (!quality.isNullOrEmpty()) {
                val dotIndex = fileName.lastIndexOf('.')
                val withQuality = if (dotIndex > 0) {
                    val base = fileName.substring(0, dotIndex)
                    val ext = fileName.substring(dotIndex)
                    "${base}_${quality}${ext}"
                } else {
                    "${fileName}_${quality}"
                }
                return "video:$withQuality"
            }
            return "video:$fileName"
        }

        val normalized = uri.buildUpon().clearQuery().fragment(null).build().toString()
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
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
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
            // Keeps the last decoded frame on screen across player.stop() +
            // new prepare — the video-to-video scene handover relies on it.
            setKeepContentOnPlayerReset(true)
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
        view?.evaluateJavascript(
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
                var shouldBeTransparent = Boolean(hasVideoLayer && nativeMode && !forceBlack);

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
            "clear" -> requestClearNativeVideo(json.optString("ownerId"))
            "setMarquee" -> marqueeOverlayController.setMarquee(json)
            "clearMarquee" -> marqueeOverlayController.clearMarquee(json.optString("ownerId"))
            else -> {
                // no-op
            }
        }

        // SPA can switch between web-rendered and native video layers without page reload.
        // Re-sync transparency on every bridge message so visual updates apply immediately.
        syncPageTransparencyForNativeVideo(webView)
    }

    // A "clear" from an unmounting scene must not kill the playlist a newer
    // scene already owns, and same-owner clears are deferred so the setPlaylist
    // arriving within the same switch cancels them (last-frame handover).
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
        playbackGuardHandler.postDelayed(runnable, CLEAR_HANDOVER_GRACE_MS)
    }

    private fun cancelPendingClear() {
        pendingClearRunnable?.let { playbackGuardHandler.removeCallbacks(it) }
        pendingClearRunnable = null
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
        val prewarm = json.optBoolean("prewarm", false)
        val nextPlaylistKey = nextPlaylist.joinToString("\u0001")
        val samePlaylist = ownerId == currentOwnerId &&
            nextPlaylistKey == currentPlaylistKey &&
            playlist.isNotEmpty() &&
            (player?.mediaItemCount ?: 0) > 0

        // Keep scene transitions enabled; low-performance mode should reduce
        // heavy visual effects (blur/backdrop) but not remove transitions.
        transitionMs = json.optInt("transitionMs", 0).coerceIn(0, 1200)
        currentDimAlpha = json.optDouble("dimAlpha", 0.0).toFloat().coerceIn(0f, 1f)
        applyPlacement(json.optJSONObject("rect"), currentDimAlpha)
        if (samePlaylist) {
            Log.d(TAG, "setPlaylist skipped restart (same owner/playlist), owner=$ownerId")
            notifyNativeVideoReady(ownerId)
            return
        }

        val hadVisibleVideo = videoLayer.visibility == View.VISIBLE &&
            videoPlayerView.alpha == 1f &&
            (player?.mediaItemCount ?: 0) > 0

        knownSources.addAll(nextPlaylist)
        when {
            prewarm -> hideUntilFirstFrameQuietly()
            hadVisibleVideo -> keepLastFrameForHandover()
            else -> hideUntilFirstFrame()
        }
        Log.d(TAG, "setPlaylist owner=$ownerId tracks=${nextPlaylist.size} transitionMs=$transitionMs prewarm=$prewarm")

        currentOwnerId = ownerId
        playlist = nextPlaylist
        currentPlaylistKey = nextPlaylistKey
        refillQueue(avoidCurrent = false)
        startPlaybackPipeline()
        val currentSource = playlist.getOrNull(currentIndex)
        scheduleVideoPrefetch(playlist, currentSource)
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
        currentPlacement = null
        isTransitionRunning = false
        waitingForFirstFrame = false
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = false
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoPlayerView.alpha = 0f
        dimOverlayView.alpha = 0f
        videoLayer.visibility = View.GONE
        resetPlaybackGuardState()
        player?.stop()
    }

    private fun scheduleVideoPrefetch(playlistSnapshot: List<String>, excludeSource: String?) {
        // Prefetch the whole playlist (not just the next clip) as complete files, so the
        // rotation keeps playing from local cache when the network drops. The current
        // clip is excluded — it is already streaming into the player.
        val targets = playlistSnapshot
            .asSequence()
            .filter { it.isNotBlank() && it != excludeSource }
            .distinct()
            .take(VIDEO_PREFETCH_MAX_ITEMS)
            .toList()

        cancelVideoPrefetch()
        if (targets.isEmpty() || videoCacheMaxBytes <= 0L) {
            return
        }

        val token = ++prefetchToken
        val fillLimit = (videoCacheMaxBytes.toDouble() * VIDEO_PREFETCH_CACHE_FILL_FRACTION).toLong()
        prefetchFuture = prefetchExecutor.submit {
            for (source in targets) {
                if (Thread.currentThread().isInterrupted || token != prefetchToken) {
                    return@submit
                }
                // The LRU evictor hard-caps the cache on disk; stopping here just avoids
                // downloading clips that would immediately evict ones cached this pass.
                if (currentCacheBytes() >= fillLimit) {
                    Log.d(TAG, "Prefetch budget reached (${fillLimit / (1024L * 1024L)}MB), stopping")
                    return@submit
                }
                prefetchVideoToCache(source, token)
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

    private fun currentCacheBytes(): Long {
        return try {
            videoCache.cacheSpace
        } catch (_: Throwable) {
            0L
        }
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

    private fun tryPlayRandomCachedFallback(): Boolean {
        val instance = player ?: return false
        val currentMediaId = instance.currentMediaItem?.mediaId.orEmpty()
        if (currentMediaId.startsWith("fallback-")) {
            return false
        }

        val currentSource = playlist.getOrNull(currentIndex)
        val candidates = knownSources
            .asSequence()
            .filter { it.isNotBlank() && it != currentSource }
            .filter { hasCachedDataForSource(it) }
            .toList()
        if (candidates.isEmpty()) {
            return false
        }

        val fallbackSource = candidates[Random.nextInt(candidates.size)]
        val mediaItem = createFallbackMediaItem(fallbackSource)
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
            videoCache.getCachedSpans(key).isNotEmpty()
        } catch (_: Throwable) {
            false
        }
    }

    private fun createFallbackMediaItem(source: String): MediaItem {
        val mediaId = "fallback-${mediaIdSerial++}"
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

        val indices = playlist.indices.toMutableList()
        indices.shuffle()
        if (avoidCurrent && currentIndex >= 0 && indices.size > 1 && indices[0] == currentIndex) {
            val swapAt = indices.indexOfFirst { it != currentIndex }
            if (swapAt > 0) {
                val first = indices[0]
                indices[0] = indices[swapAt]
                indices[swapAt] = first
            }
        }
        playQueue.addAll(indices)
    }

    private fun nextIndex(): Int {
        if (playlist.isEmpty()) {
            return -1
        }
        if (playlist.size == 1) {
            return 0
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
        isTransitionRunning = false

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
        waitingForFirstFrame = true
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = false
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 1f
        videoPlayerView.alpha = 0f
        webView.setBackgroundColor(Color.BLACK)
        syncPageTransparencyForNativeVideo(webView)
    }

    // Prewarm: the current scene's opaque page keeps covering the screen, so
    // the next clip prepares behind it without the cold-start blackout.
    private fun hideUntilFirstFrameQuietly() {
        waitingForFirstFrame = true
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = true
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoPlayerView.alpha = 0f
    }

    // Video-to-video switch: keepContentOnPlayerReset holds the last decoded
    // frame on screen until the next clip renders, so there is no black gap.
    private fun keepLastFrameForHandover() {
        waitingForFirstFrame = false
        pendingRevealAfterTransform = false
        suppressWaitingBlackout = false
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoPlayerView.alpha = 1f
    }

    private fun maybeRevealVideoAfterFirstFrame() {
        if (!waitingForFirstFrame || !pendingRevealAfterTransform) {
            return
        }
        if (!applyVideoCenterCropTransform()) {
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
        val targetQueueDepth = if (playlist.size <= 1) 1 else 2
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
        val index = nextIndex()
        if (index < 0 || index >= playlist.size) {
            return
        }

        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        isTransitionRunning = false
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
        if (playlist.isEmpty() || videoLayer.visibility != View.VISIBLE || waitingForFirstFrame) {
            return
        }

        markPlaybackProgressIfAdvanced()

        val now = SystemClock.elapsedRealtime()
        val playbackState = instance.playbackState
        val stallDurationMs = if (lastPlaybackProgressRealtimeMs <= 0L) 0L else now - lastPlaybackProgressRealtimeMs

        if (!instance.playWhenReady) {
            recoverPlayback("playWhenReady=false")
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
            Player.STATE_IDLE -> instance.prepare()
            else -> Unit
        }

        instance.playWhenReady = true
        instance.play()
        markPlaybackProgressIfAdvanced(forceRefresh = true)
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

    private fun runSmartFade() {
        if (isTransitionRunning || transitionMs <= 0) {
            return
        }
        isTransitionRunning = true
        val half = (transitionMs / 2).coerceIn(50, 220)

        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        transitionOverlayView.animate()
            .alpha(1f)
            .setDuration(half.toLong())
            .withEndAction {
                transitionOverlayView.animate()
                    .alpha(0f)
                    .setDuration(half.toLong())
                    .withEndAction {
                        isTransitionRunning = false
                    }
                    .start()
            }
            .start()
    }

    private fun applyPlacement(rect: JSONObject?, dimAlpha: Float) {
        val placement = VideoPlacement(
            x = rect?.optDouble("x", 0.0)?.toFloat() ?: 0f,
            y = rect?.optDouble("y", 0.0)?.toFloat() ?: 0f,
            width = rect?.optDouble("width", 100.0)?.toFloat() ?: 100f,
            height = rect?.optDouble("height", 100.0)?.toFloat() ?: 100f,
        )
        currentPlacement = placement
        applyPlacement(placement, dimAlpha)
    }

    private fun applyStoredPlacement() {
        val placement = currentPlacement ?: return
        applyPlacement(placement, currentDimAlpha)
    }

    private fun applyPlacement(placement: VideoPlacement, dimAlpha: Float) {
        rootLayout.post {
            val rootW = rootLayout.width.coerceAtLeast(1)
            val rootH = rootLayout.height.coerceAtLeast(1)
            val isFullBleed = isPlacementFullBleed(placement)
            resolveSceneViewportRect { viewport ->
                val useViewport = !isFullBleed && viewport != null
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
        }
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
        fun getCapabilities(): String = """{"nativeVideo":true,"nativeMarquee":true,"scenePrewarm":true}"""

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
}
