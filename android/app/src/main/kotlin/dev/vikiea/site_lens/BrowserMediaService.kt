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
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { dispatch("resume") }
                override fun onPause() { dispatch("pause") }
                override fun onStop() { dispatch("stop") }
                override fun onSkipToNext() { dispatch("next") }
                override fun onSkipToPrevious() { dispatch("previous") }
                override fun onCustomAction(action: String, extras: android.os.Bundle?) {
                    if (action in listOf("stop", "next", "previous")) dispatch(action)
                }
            })
            isActive = true
        }
        // The owner is installed before the foreground service is started.
        // Seed the token so a media-button callback arriving between service
        // creation and the first onStartCommand is still routed safely.
        token = owner?.token
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val next = owner
        // Stale PendingIntents cannot control a newly selected tab or host.
        if (next == null) { stopSelf(); return START_NOT_STICKY }
        if (intent?.getStringExtra("owner") != next.token) return START_NOT_STICKY
        if (intent?.data?.host != null && intent.data?.host != next.token) return START_NOT_STICKY
        token = next.token
        if (intent.action in listOf("resume", "pause", "stop", "next", "previous")) {
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
            .setActions(
                PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
                    if (active.canSkip) PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS else 0L,
            )
            .apply {
                // Android 13+ derives the five media-control slots from this
                // state. Standard skip actions already occupy their own slots;
                // duplicate custom skips would consume the two custom slots
                // before the stop action can be displayed.
                addCustomAction(PlaybackState.CustomAction.Builder("stop", "停止", android.R.drawable.ic_menu_close_clear_cancel).build())
            }
            .setState(if (active.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                PlaybackState.PLAYBACK_POSITION_UNKNOWN, if (active.playing) 1f else 0f).build())
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun action(name: String, icon: Int, label: String): Notification.Action {
            val command = Intent(this, BrowserMediaService::class.java).setAction(name)
                .setPackage(packageName)
                .setData(Uri.parse("site-lens-media://${active.token}/$name"))
                .putExtra("owner", active.token)
            val requestCode = (active.token + name).hashCode()
            val pending = PendingIntent.getService(this, requestCode, command,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            return Notification.Action.Builder(icon, label, pending).build()
        }
        val compactActions = if (active.canSkip) intArrayOf(0, 1, 2) else intArrayOf(0, 1)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play).setContentTitle(active.title)
            .setContentText("择站 · 当前标签").setContentIntent(open).setOnlyAlertOnce(true)
            .setOngoing(active.playing)
            .setStyle(Notification.MediaStyle().setMediaSession(session?.sessionToken)
                .setShowActionsInCompactView(*compactActions))
            .apply {
                if (active.canSkip) {
                    addAction(action("previous", android.R.drawable.ic_media_previous, "上一集"))
                }
                addAction(if (active.playing) action("pause", android.R.drawable.ic_media_pause, "暂停")
                    else action("resume", android.R.drawable.ic_media_play, "继续"))
                if (active.canSkip) {
                    addAction(action("next", android.R.drawable.ic_media_next, "下一集"))
                }
                addAction(action("stop", android.R.drawable.ic_menu_close_clear_cancel, "停止"))
            }
            .build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(ID, notification)
    }

    private fun dispatch(action: String) {
        val active = owner ?: return
        // MediaSession callbacks do not carry the PendingIntent owner token.
        // Adopt the latest owner before dispatching so a handoff does not leave
        // the new tab's notification controls inert while onStartCommand is in flight.
        token = active.token
        active.command(action)
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

    private data class Owner(val token: String, var title: String, var playing: Boolean, var canSkip: Boolean, val command: (String) -> Unit)
    companion object {
        private const val CHANNEL = "site-lens-browser-media"
        private const val ID = 24001
        private var owner: Owner? = null
        fun owns(token: String) = owner?.token == token
        fun update(context: Context, token: String, title: String, playing: Boolean, foreground: Boolean,
                   canSkip: Boolean, command: (String) -> Unit): Boolean {
            if (!foreground && !owns(token)) return false
            if (!playing && !owns(token)) return true
            val previous = owner
            owner = Owner(token, title.take(512), playing, canSkip, command)
            try {
                val serviceIntent = Intent(context, BrowserMediaService::class.java).putExtra("owner", token)
                if (previous?.token == token) {
                    // Updating an existing foreground service from the
                    // background must use startService; Android 12+ rejects a
                    // second background foreground-service start.
                    context.startService(serviceIntent)
                } else {
                    context.startForegroundService(serviceIntent)
                }
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
