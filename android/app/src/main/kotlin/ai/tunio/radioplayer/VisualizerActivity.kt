package ai.tunio.radioplayer

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.TextureView
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
import androidx.media3.exoplayer.ExoPlayer
import org.json.JSONObject
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
        private const val TAG = "VisualizerActivity"
    }

    private lateinit var rootLayout: FrameLayout
    private lateinit var videoLayer: FrameLayout
    private lateinit var videoTextureView: TextureView
    private lateinit var dimOverlayView: View
    private lateinit var transitionOverlayView: View
    private lateinit var webView: WebView

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
    private var transitionMs: Int = 0
    private var isTransitionRunning = false
    private var waitingForFirstFrame = false
    private val closeTapSlop by lazy { ViewConfiguration.get(this).scaledTouchSlop.toFloat() }
    private var closeTapDownX: Float = 0f
    private var closeTapDownY: Float = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupWindow()
        initPlayer()

        webView = createWebView()
        setContentView(createLayout())

        player?.setVideoTextureView(videoTextureView)
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
        intent?.getStringExtra(EXTRA_URL)?.let { loadUrl(it) }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (VisualizerController.currentActivity == this) {
            VisualizerController.currentActivity = null
        }
        clearNativeVideo()
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
        val silentVideoAttrs = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .build()

        val noAudioTracks = TrackSelectionParameters.Builder(this)
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
            .build()

        player = ExoPlayer.Builder(this).build().apply {
            repeatMode = Player.REPEAT_MODE_OFF
            playWhenReady = true
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

                        // Overlay fade is intentionally disabled because it can become
                        // visibly desynced from the actual frame switch on weak devices.
                    }

                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_READY && waitingForFirstFrame) {
                            revealVideoAfterFirstFrame()
                        }
                        if (playbackState == Player.STATE_ENDED) {
                            hardCutToNext()
                        }
                    }

                    override fun onRenderedFirstFrame() {
                        if (waitingForFirstFrame) {
                            revealVideoAfterFirstFrame()
                        }
                    }

                    override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                        Log.w(TAG, "player error, hard cut fallback: ${error.message}")
                        waitingForFirstFrame = false
                        transitionOverlayView.alpha = 0f
                        hardCutToNext()
                    }
                },
            )
        }
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
                    enforceWebViewMediaMuted(view)
                    syncPageTransparencyForNativeVideo(view)
                    rootLayout.postDelayed({ enforceWebViewMediaMuted(view) }, 350L)
                    rootLayout.postDelayed({ syncPageTransparencyForNativeVideo(view) }, 350L)
                    rootLayout.postDelayed({ enforceWebViewMediaMuted(view) }, 1200L)
                    rootLayout.postDelayed({ syncPageTransparencyForNativeVideo(view) }, 1200L)
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

    private fun createLayout(): FrameLayout {
        rootLayout = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        videoLayer = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            visibility = View.GONE
        }

        videoTextureView = TextureView(this).apply {
            setOpaque(true)
            alpha = 0f
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

        videoLayer.addView(videoTextureView, FrameLayout.LayoutParams(matchParent))
        videoLayer.addView(dimOverlayView, FrameLayout.LayoutParams(matchParent))
        videoLayer.addView(transitionOverlayView, FrameLayout.LayoutParams(matchParent))

        rootLayout.addView(videoLayer, FrameLayout.LayoutParams(matchParent))
        rootLayout.addView(webView, FrameLayout.LayoutParams(matchParent))

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
        webView.loadUrl(url)
    }

    private fun syncPageTransparencyForNativeVideo(view: WebView?) {
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
                var shouldBeTransparent = Boolean(hasVideoLayer && nativeMode);

                var styleId = '__tunio_native_video_transparency';
                var style = document.getElementById(styleId);

                if (shouldBeTransparent) {
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
                  if (document.documentElement) {
                    document.documentElement.style.removeProperty('background');
                  }
                  if (document.body) {
                    document.body.style.removeProperty('background');
                  }
                }

                return JSON.stringify({
                  hasVideoLayer: Boolean(hasVideoLayer),
                  nativeMode: Boolean(nativeMode),
                  shouldBeTransparent: shouldBeTransparent
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
            "clear" -> {
                // Always clear on explicit request from SPA. This prevents stale
                // tail frames from previous scenes when returning to video scenes.
                clearNativeVideo()
            }
            else -> {
                // no-op
            }
        }

        // SPA can switch between web-rendered and native video layers without page reload.
        // Re-sync transparency on every bridge message so visual updates apply immediately.
        syncPageTransparencyForNativeVideo(webView)
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

        // Force hard cuts in native mode to avoid delayed fade-in/out artifacts.
        transitionMs = 0
        currentDimAlpha = json.optDouble("dimAlpha", 0.0).toFloat().coerceIn(0f, 1f)
        hideUntilFirstFrame()
        applyPlacement(json.optJSONObject("rect"), currentDimAlpha)
        Log.d(TAG, "setPlaylist owner=$ownerId tracks=${nextPlaylist.size} transitionMs=$transitionMs")

        currentOwnerId = ownerId
        playlist = nextPlaylist
        currentPlaylistKey = nextPlaylist.joinToString("\u0001")
        refillQueue(avoidCurrent = false)
        startPlaybackPipeline()
    }

    private fun clearNativeVideo() {
        Log.d(TAG, "clearNativeVideo")
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
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoTextureView.alpha = 0f
        dimOverlayView.alpha = 0f
        videoLayer.visibility = View.GONE
        player?.stop()
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
        }
    }

    private fun hideUntilFirstFrame() {
        waitingForFirstFrame = true
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 1f
        videoTextureView.alpha = 0f
    }

    private fun revealVideoAfterFirstFrame() {
        waitingForFirstFrame = false
        transitionOverlayView.animate().cancel()
        transitionOverlayView.alpha = 0f
        videoTextureView.alpha = 1f
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
        }
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

            val left = (rootW * (placement.x / 100f)).roundToInt().coerceAtLeast(0)
            val top = (rootH * (placement.y / 100f)).roundToInt().coerceAtLeast(0)
            val w = (rootW * (placement.width / 100f)).roundToInt().coerceAtLeast(1)
            val h = (rootH * (placement.height / 100f)).roundToInt().coerceAtLeast(1)

            val params = FrameLayout.LayoutParams(w, h).apply {
                leftMargin = left
                topMargin = top
            }

            videoLayer.layoutParams = params
            videoLayer.visibility = View.VISIBLE
            dimOverlayView.alpha = dimAlpha.coerceIn(0f, 1f)
        }
    }

    private inner class NativeVideoJsBridge {
        @JavascriptInterface
        fun isAvailable(): Boolean = true

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
