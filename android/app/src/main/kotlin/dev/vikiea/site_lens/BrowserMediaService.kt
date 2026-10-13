package dev.vikiea.site_lens

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.IBinder

/** Controls only the selected WebView. Process death never restarts playback. */
class BrowserMediaService : Service() {
    private var session: MediaSession? = null
    private var token: String? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "浏览器媒体", NotificationManager.IMPORTANCE_LOW))
        session = MediaSession(this, "site-lens-browser:$packageName").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { dispatch("resume") }
                override fun onPause() { dispatch("pause") }
                override fun onStop() { dispatch("stop") }
                override fun onCustomAction(action: String, extras: android.os.Bundle?) {
                    if (action == "stop") dispatch("stop")
                }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val next = owner
        // Stale PendingIntents cannot control a newly selected tab or host.
        if (next == null) { stopSelf(); return START_NOT_STICKY }
        if (intent?.getStringExtra("owner") != next.token) return START_NOT_STICKY
        token = next.token
        if (intent.action in listOf("resume", "pause", "stop")) {
            dispatch(intent.action!!)
            if (intent.action == "stop") return START_NOT_STICKY
        }
        render()
        return START_NOT_STICKY
    }

    private fun render() {
        val active = owner?.takeIf { it.token == token } ?: return
        session?.setMetadata(MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, active.title).build())
        session?.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_STOP)
            .addCustomAction(PlaybackState.CustomAction.Builder("stop", "停止", android.R.drawable.ic_menu_close_clear_cancel).build())
            .setState(if (active.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                PlaybackState.PLAYBACK_POSITION_UNKNOWN, if (active.playing) 1f else 0f).build())
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun action(name: String, icon: Int, label: String): Notification.Action {
            val command = Intent(this, BrowserMediaService::class.java).setAction(name)
                .setData(Uri.parse("site-lens-media://${active.token}/$name"))
                .putExtra("owner", active.token)
            val pending = PendingIntent.getService(this, 0, command,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            return Notification.Action.Builder(icon, label, pending).build()
        }
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play).setContentTitle(active.title)
            .setContentText("择站 · 当前标签").setContentIntent(open).setOnlyAlertOnce(true)
            .setOngoing(active.playing)
            .setStyle(Notification.MediaStyle().setMediaSession(session?.sessionToken).setShowActionsInCompactView(0, 1))
            .addAction(if (active.playing) action("pause", android.R.drawable.ic_media_pause, "暂停")
                else action("resume", android.R.drawable.ic_media_play, "继续"))
            .addAction(action("stop", android.R.drawable.ic_menu_close_clear_cancel, "停止")).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(ID, notification)
    }

    private fun dispatch(action: String) {
        owner?.takeIf { it.token == token }?.command?.invoke(action)
        if (action == "stop") stopSelf() else render()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onTaskRemoved(rootIntent: Intent?) { dispatch("stop"); stopSelf() }
    override fun onDestroy() {
        val active = owner?.takeIf { it.token == token }
        if (active != null) { owner = null; active.command("stop") }
        session?.isActive = false; session?.release(); session = null
        getSystemService(NotificationManager::class.java).cancel(ID)
        super.onDestroy()
    }

    private data class Owner(val token: String, var title: String, var playing: Boolean, val command: (String) -> Unit)
    companion object {
        private const val CHANNEL = "site-lens-browser-media"
        private const val ID = 24001
        private var owner: Owner? = null
        fun owns(token: String) = owner?.token == token
        fun update(context: Context, token: String, title: String, playing: Boolean, foreground: Boolean,
                   command: (String) -> Unit): Boolean {
            if (!foreground && !owns(token)) return false
            if (!playing && !owns(token)) return true
            val previous = owner
            owner = Owner(token, title.take(512), playing, command)
            try {
                context.startForegroundService(Intent(context, BrowserMediaService::class.java).putExtra("owner", token))
                return true
            } catch (_: IllegalStateException) { owner = previous; return false }
              catch (_: SecurityException) { owner = previous; return false }
        }
        fun stop(context: Context, token: String) {
            if (!owns(token)) return
            owner = null
            context.stopService(Intent(context, BrowserMediaService::class.java))
        }
    }
}
