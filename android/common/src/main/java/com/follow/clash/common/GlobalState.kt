package com.follow.clash.common


import android.app.Application
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.crashlytics.FirebaseCrashlytics
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers

object GlobalState : CoroutineScope by CoroutineScope(Dispatchers.Default) {

    const val NOTIFICATION_CHANNEL = "FlClash"

    const val NOTIFICATION_ID = 1

    val packageName: String
        get() = application.packageName

    val RECEIVE_BROADCASTS_PERMISSIONS: String
        get() = "${packageName}.permission.RECEIVE_BROADCASTS"


    private var _application: Application? = null

    val application: Application
        get() = _application!!


    fun log(text: String) {
        Log.d("[FlClash]", text)
    }

    fun init(application: Application) {
        _application = application
    }

    fun setCrashlytics(enable: Boolean) {
        val application = _application ?: return
        if (!isFirebaseConfigured(application)) {
            log("skip crashlytics: google-services is not configured")
            return
        }
        FirebaseApp.initializeApp(application)
        FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = enable
        if (enable) {
            log("init crashlytics ${application.processName}")
        }
    }

    private fun isFirebaseConfigured(application: Application): Boolean {
        return application.resources.getIdentifier(
            "google_app_id",
            "string",
            application.packageName,
        ) != 0
    }
}