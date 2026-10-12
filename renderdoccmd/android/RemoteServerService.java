package @RENDERDOC_ANDROID_PACKAGE_NAME@;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

// The native server remains in Loader's process. Keep that process active while the game is on top.
public class RemoteServerService extends Service
{
    private static final String CHANNEL = "renderdoc_remote_server";
    private PowerManager.WakeLock wakeLock;

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager manager = (NotificationManager)getSystemService(NOTIFICATION_SERVICE);
        Notification.Builder notification;
        if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(new NotificationChannel(
                CHANNEL, "RenderDoc remote server", NotificationManager.IMPORTANCE_LOW));
            notification = new Notification.Builder(this, CHANNEL);
        } else {
            notification = new Notification.Builder(this);
        }

        Intent activity = new Intent(this, Loader.class);
        activity.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent content = PendingIntent.getActivity(this, 0, activity,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        startForeground(1, notification.setSmallIcon(R.drawable.icon)
            .setContentTitle("RenderDoc remote server")
            .setContentText("Ready for capture and replay")
            .setContentIntent(content)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
            .setOngoing(true)
            .build());

        PowerManager power = (PowerManager)getSystemService(POWER_SERVICE);
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "RenderDoc:RemoteServer");
        wakeLock.acquire();
        Log.i("renderdoccmd", "Remote server foreground service started");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Do not restart a service without its native server after the process has been killed.
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        if(wakeLock != null && wakeLock.isHeld())
            wakeLock.release();
        stopForeground(true);
        Log.i("renderdoccmd", "Remote server foreground service stopped");
        super.onDestroy();
    }
}
