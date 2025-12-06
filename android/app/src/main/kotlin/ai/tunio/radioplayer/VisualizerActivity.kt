package ai.tunio.radioplayer

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowInsets
import android.view.WindowManager
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import kotlin.math.roundToInt

class VisualizerActivity : Activity() {

    companion object {
        const val EXTRA_URL = "visualizer_url"
    }

    private lateinit var webView: WebView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupWindow()

        webView = createWebView()
        setContentView(createLayout())

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

    private fun createWebView(): WebView {
        return WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.loadsImagesAutomatically = true
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            setBackgroundColor(Color.TRANSPARENT)
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) {
                    VisualizerController.notifyReady()
                }
            }
        }
    }

    private fun createLayout(): FrameLayout {
        val layout = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        layout.addView(
            webView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        val closeButton = ImageButton(this).apply {
            contentDescription = getString(android.R.string.cancel)
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            background = null
            setColorFilter(Color.WHITE)
            isFocusable = true
            isFocusableInTouchMode = true
            setOnClickListener { finish() }
        }

        val closeParams = FrameLayout.LayoutParams(dp(52), dp(52)).apply {
            gravity = Gravity.BOTTOM or Gravity.END
            marginEnd = dp(24)
            bottomMargin = dp(24)
        }
        layout.addView(closeButton, closeParams)

        return layout
    }

    private fun loadUrl(url: String) {
        webView.loadUrl(url)
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).roundToInt()
    }
}
