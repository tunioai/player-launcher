package ai.tunio.radioplayer

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.TextView
import org.json.JSONObject
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * Renders marquee blocks natively on top of the WebView. On weak boxes a CSS
 * transform animation forces the WebView to composite every frame; a TextView
 * translated by ViewPropertyAnimator runs on the RenderThread and stays smooth
 * regardless of web-content load. The SPA sends measured CSS-pixel geometry via
 * the TunioNativeVideo bridge ("setMarquee"/"clearMarquee") and suppresses its
 * own DOM marquee.
 */
class MarqueeOverlayController(private val context: Context) {

    companion object {
        private const val TAG = "MarqueeOverlay"
        // Visual parity with the web marquee: 42px base font with
        // text-shadow 0 2px 8px rgba(0,0,0,0.55), scaled with the font.
        private const val BASE_FONT_PX = 42f
        private const val SHADOW_RADIUS_FACTOR = 8f / BASE_FONT_PX
        private const val SHADOW_DY_FACTOR = 2f / BASE_FONT_PX
        private const val SHADOW_COLOR = 0x8C000000.toInt()
        private const val MIN_TRAVEL_DURATION_MS = 2500L
        private const val LAYOUT_RETRY_DELAY_MS = 16L
        private const val LAYOUT_RETRY_LIMIT = 120
    }

    private data class MarqueeSpec(
        val text: String,
        val color: Int,
        val fontWeight: Int,
        val fontSizePx: Float,
        val speedPxPerSecond: Float,
        val pauseMs: Long,
        val alpha: Float,
    )

    private class Overlay(
        val container: FrameLayout,
        val textView: TextView,
    ) {
        var spec: MarqueeSpec? = null
        var cycleToken: Int = 0
    }

    val layer: FrameLayout = FrameLayout(context)

    private val overlays = mutableMapOf<String, Overlay>()

    fun setMarquee(json: JSONObject) {
        val ownerId = json.optString("ownerId")
        if (ownerId.isEmpty()) {
            return
        }

        val text = json.optString("text").trim()
        val rect = json.optJSONObject("rect")
        if (text.isEmpty() || rect == null) {
            clearMarquee(ownerId)
            return
        }

        val dpr = json.optDouble("dpr", 1.0).toFloat().coerceAtLeast(0.1f)
        val width = (rect.optDouble("width", 0.0) * dpr).roundToInt()
        val height = (rect.optDouble("height", 0.0) * dpr).roundToInt()
        if (width <= 0 || height <= 0) {
            return
        }

        val params = FrameLayout.LayoutParams(width, height).apply {
            leftMargin = (rect.optDouble("left", 0.0) * dpr).roundToInt()
            topMargin = (rect.optDouble("top", 0.0) * dpr).roundToInt()
        }
        val spec = MarqueeSpec(
            text = text,
            color = parseColor(json.optString("color")),
            fontWeight = json.optInt("fontWeight", 700),
            fontSizePx = (json.optDouble("fontSizePx", BASE_FONT_PX.toDouble()) * dpr).toFloat().coerceAtLeast(1f),
            speedPxPerSecond = (json.optDouble("speedPxPerSecond", 200.0) * dpr).toFloat().coerceAtLeast(1f),
            pauseMs = (json.optDouble("pauseSeconds", 0.0) * 1000.0).roundToLong().coerceIn(0L, 10_000L),
            alpha = json.optDouble("opacity", 1.0).toFloat().coerceIn(0f, 1f),
        )

        val existing = overlays[ownerId]
        if (existing == null) {
            val overlay = createOverlay(params)
            overlays[ownerId] = overlay
            overlay.spec = spec
            applySpec(overlay, spec)
            restartCycle(overlay)
            Log.d(TAG, "setMarquee owner=$ownerId rect=${params.leftMargin},${params.topMargin},$width,$height")
            return
        }

        existing.container.layoutParams = params
        if (existing.spec != spec) {
            existing.spec = spec
            applySpec(existing, spec)
            restartCycle(existing)
        }
    }

    fun clearMarquee(ownerId: String?) {
        if (ownerId.isNullOrEmpty()) {
            return
        }
        val overlay = overlays.remove(ownerId) ?: return
        releaseOverlay(overlay)
        Log.d(TAG, "clearMarquee owner=$ownerId")
    }

    fun clearAll() {
        if (overlays.isEmpty()) {
            return
        }
        overlays.values.forEach(::releaseOverlay)
        overlays.clear()
        Log.d(TAG, "clearAll")
    }

    private fun createOverlay(params: FrameLayout.LayoutParams): Overlay {
        val textView = TextView(context).apply {
            isSingleLine = true
            maxLines = 1
            ellipsize = null
            includeFontPadding = false
            gravity = Gravity.CENTER_VERTICAL
            visibility = View.INVISIBLE
        }
        val container = FrameLayout(context).apply {
            clipChildren = true
            addView(
                textView,
                FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.MATCH_PARENT),
            )
        }
        layer.addView(container, params)
        return Overlay(container, textView)
    }

    private fun applySpec(overlay: Overlay, spec: MarqueeSpec) {
        overlay.textView.apply {
            text = spec.text
            setTextColor(spec.color)
            setTextSize(TypedValue.COMPLEX_UNIT_PX, spec.fontSizePx)
            typeface = resolveTypeface(spec.fontWeight)
            letterSpacing = -0.01f
            alpha = spec.alpha
            setShadowLayer(
                spec.fontSizePx * SHADOW_RADIUS_FACTOR,
                0f,
                spec.fontSizePx * SHADOW_DY_FACTOR,
                SHADOW_COLOR,
            )
        }
        // FrameLayout caps WRAP_CONTENT children at its own width, so the text
        // width is measured manually and set as an exact size to let the view
        // extend past the clipping container.
        val textWidth = ceil(overlay.textView.paint.measureText(spec.text)).toInt().coerceAtLeast(1)
        overlay.textView.layoutParams = FrameLayout.LayoutParams(textWidth, FrameLayout.LayoutParams.MATCH_PARENT)
    }

    private fun restartCycle(overlay: Overlay) {
        overlay.cycleToken += 1
        overlay.textView.animate().cancel()
        overlay.textView.visibility = View.INVISIBLE
        scheduleCycleAfterLayout(overlay, overlay.cycleToken)
    }

    private fun scheduleCycleAfterLayout(overlay: Overlay, token: Int) {
        val textView = overlay.textView
        textView.post(object : Runnable {
            private var attempts = 0

            override fun run() {
                if (token != overlay.cycleToken || !textView.isAttachedToWindow) {
                    return
                }
                if (overlay.container.width <= 0 || textView.width <= 0) {
                    attempts += 1
                    if (attempts >= LAYOUT_RETRY_LIMIT) {
                        Log.w(TAG, "marquee layout never settled, giving up")
                        return
                    }
                    textView.postDelayed(this, LAYOUT_RETRY_DELAY_MS)
                    return
                }
                runCycle(overlay, token)
            }
        })
    }

    private fun runCycle(overlay: Overlay, token: Int) {
        val spec = overlay.spec ?: return
        val containerWidth = overlay.container.width
        val textWidth = overlay.textView.width
        if (containerWidth <= 0 || textWidth <= 0) {
            return
        }

        val startX = containerWidth.toFloat()
        val endX = -textWidth.toFloat()
        val durationMs = max(
            MIN_TRAVEL_DURATION_MS,
            ((startX - endX) / spec.speedPxPerSecond * 1000f).roundToLong(),
        )

        overlay.textView.translationX = startX
        overlay.textView.visibility = View.VISIBLE
        overlay.textView.animate()
            .translationX(endX)
            .setDuration(durationMs)
            .setInterpolator(LinearInterpolator())
            .withEndAction {
                if (token != overlay.cycleToken) {
                    return@withEndAction
                }
                if (spec.pauseMs > 0) {
                    overlay.textView.postDelayed(
                        {
                            if (token == overlay.cycleToken) {
                                runCycle(overlay, token)
                            }
                        },
                        spec.pauseMs,
                    )
                } else {
                    runCycle(overlay, token)
                }
            }
            .start()
    }

    private fun releaseOverlay(overlay: Overlay) {
        overlay.cycleToken += 1
        overlay.textView.animate().cancel()
        layer.removeView(overlay.container)
    }

    private fun parseColor(raw: String?): Int {
        if (raw.isNullOrBlank()) {
            return Color.WHITE
        }
        return try {
            Color.parseColor(raw.trim())
        } catch (_: Throwable) {
            Color.WHITE
        }
    }

    private fun resolveTypeface(weight: Int): Typeface {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return Typeface.create(Typeface.SANS_SERIF, weight.coerceIn(100, 1000), false)
        }
        return if (weight >= 600) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
    }
}
