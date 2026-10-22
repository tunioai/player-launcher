package ai.tunio.radioplayer

import android.content.Context
import android.os.Build
import android.util.Log
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * Android before 7.1.1 does not carry ISRG Root X1, the root every Tunio host's
 * Let's Encrypt certificate chains to, so the native player (ExoPlayer over
 * HttpsURLConnection) could not open the station's stream there. On those
 * releases the bundled ISRG roots are added after the system ones: a chain the
 * system trusts is still checked by the system first.
 */
object LegacyRootTrust {
    private const val TAG = "LegacyRootTrust"
    private val bundledRoots = intArrayOf(R.raw.isrg_root_x1, R.raw.isrg_root_x2)

    fun installIfNeeded(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) return
        try {
            val trustManager = CombinedTrustManager(systemTrustManager(), bundledTrustManager(context))
            val sslContext = SSLContext.getInstance("TLS")
            sslContext.init(null, arrayOf(trustManager), null)
            HttpsURLConnection.setDefaultSSLSocketFactory(sslContext.socketFactory)
            Log.i(TAG, "bundled ISRG roots trusted after the system ones (SDK ${Build.VERSION.SDK_INT})")
        } catch (e: Exception) {
            Log.e(TAG, "could not add the bundled ISRG roots: ${e.message}")
        }
    }

    private fun systemTrustManager(): X509TrustManager = trustManagerFor(null)

    private fun bundledTrustManager(context: Context): X509TrustManager {
        val factory = CertificateFactory.getInstance("X.509")
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType())
        keyStore.load(null, null)
        bundledRoots.forEachIndexed { index, resource ->
            context.resources.openRawResource(resource).use { input ->
                keyStore.setCertificateEntry("isrg-root-$index", factory.generateCertificate(input))
            }
        }
        return trustManagerFor(keyStore)
    }

    private fun trustManagerFor(keyStore: KeyStore?): X509TrustManager {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(keyStore)
        return factory.trustManagers.filterIsInstance<X509TrustManager>().first()
    }

    private class CombinedTrustManager(
        private val system: X509TrustManager,
        private val bundled: X509TrustManager,
    ) : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
            system.checkClientTrusted(chain, authType)

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            try {
                system.checkServerTrusted(chain, authType)
            } catch (systemRejected: CertificateException) {
                try {
                    bundled.checkServerTrusted(chain, authType)
                } catch (bundledRejected: CertificateException) {
                    throw systemRejected
                }
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> =
            system.acceptedIssuers + bundled.acceptedIssuers
    }
}
