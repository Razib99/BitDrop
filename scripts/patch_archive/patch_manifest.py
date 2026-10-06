import re

with open("app/android/app/src/main/AndroidManifest.xml", "r") as f:
    content = f.read()

# Add permissions
permissions = """
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    
    <application"""
content = content.replace("<application", permissions)

# Add receiver and service
service = """
        <!-- audio_service setup -->
        <service android:name="com.ryanheise.audioservice.AudioService" android:foregroundServiceType="mediaPlayback" android:exported="true">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>
        <receiver android:name="androidx.media.session.MediaButtonReceiver" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON" />
            </intent-filter>
        </receiver>

        <activity"""
content = content.replace("<activity", service, 1)

with open("app/android/app/src/main/AndroidManifest.xml", "w") as f:
    f.write(content)

