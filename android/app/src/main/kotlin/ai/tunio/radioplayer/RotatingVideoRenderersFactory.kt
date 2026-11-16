package ai.tunio.radioplayer

import android.content.Context
import android.os.Handler
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.FormatHolder
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener

// A SurfaceView does not follow its parent's View.rotation: its picture is a
// separate layer placed by the system. To show video on a rotated screen
// without TextureView (GPU composition on weak Mali boxes), the decoder is
// told to rotate its output (MediaFormat.KEY_ROTATION, from Format.rotationDegrees).
// The extra rotation is read when a clip's format arrives, so a change applies
// from the next clip.
@OptIn(UnstableApi::class)
class RotatingVideoRenderersFactory(
    context: Context,
    private val extraRotation: () -> Int,
) : DefaultRenderersFactory(context) {
    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
    ) {
        val built = ArrayList<Renderer>()
        super.buildVideoRenderers(
            context,
            extensionRendererMode,
            mediaCodecSelector,
            enableDecoderFallback,
            eventHandler,
            eventListener,
            allowedVideoJoiningTimeMs,
            built,
        )
        for (renderer in built) {
            if (renderer is MediaCodecVideoRenderer) {
                out.add(
                    RotatingVideoRenderer(
                        context,
                        mediaCodecSelector,
                        allowedVideoJoiningTimeMs,
                        enableDecoderFallback,
                        eventHandler,
                        eventListener,
                        extraRotation,
                    ),
                )
            } else {
                out.add(renderer)
            }
        }
    }
}

@OptIn(UnstableApi::class)
private class RotatingVideoRenderer(
    context: Context,
    mediaCodecSelector: MediaCodecSelector,
    allowedJoiningTimeMs: Long,
    enableDecoderFallback: Boolean,
    eventHandler: Handler,
    eventListener: VideoRendererEventListener,
    private val extraRotation: () -> Int,
) : MediaCodecVideoRenderer(
    context,
    mediaCodecSelector,
    allowedJoiningTimeMs,
    enableDecoderFallback,
    eventHandler,
    eventListener,
    DefaultRenderersFactory.MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY,
) {
    override fun onInputFormatChanged(formatHolder: FormatHolder): DecoderReuseEvaluation? {
        val format = formatHolder.format
        val extra = extraRotation()
        if (format != null && extra != 0) {
            formatHolder.format = format.buildUpon()
                .setRotationDegrees((format.rotationDegrees + extra) % 360)
                .build()
        }
        return super.onInputFormatChanged(formatHolder)
    }
}
