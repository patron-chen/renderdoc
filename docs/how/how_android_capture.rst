How do I use RenderDoc on Android?
==================================

RenderDoc contains support for Android for both Vulkan and OpenGL ES. It requires a couple of extra steps more than capturing on a desktop computer, but generally the workflow is very similar.

The Android device must be running at least Android 6.0.

RenderDoc requires some tools from the Android SDK to function. On windows these usually ship with the RenderDoc package, but if you are on Linux or you have trouble please see below in the Troubleshooting section about configuring your Android SDK.

.. caution::

  For RenderDoc's android support, your package must be installed and it **must be debuggable**.

Quick start
-----------

Android is supported by using :doc:`Remote Contexts <../how/how_network_capture_replay>` to debug applications on your device from a host computer. To begin, look at the bottom left of the normal RenderDoc UI to see the remote context selection dropdown:

.. figure:: ../imgs/Screenshots/android_remotecontext.png

By default when you start up, this is set to "Local" which means all capture and replay happens on the host computer. To switch to a connected android device, click the drop-down and select your device from the options:

.. note::

  If you don't see your android device listed, try waiting a few seconds as available devices are scanned every so often.

  If it still doesn't appear after 10 seconds, check that you have your SDK configured correctly - see below in the Troubleshooting section.

.. |cross| image:: ../imgs/icons/cross.png

Each device listed will likely have a |cross| next to it, indicating that RenderDoc's capture & replay app is not yet running on the device. Select a device, and RenderDoc will check that RenderDoc's app is installed and run it.

.. note::

  After the app is installed once, it will not need to be reinstalled until you update your version of RenderDoc.

Once RenderDoc's app is running, you are ready to capture and replay on android, and the drop-down will indicate the new active connection.

.. figure:: ../imgs/Screenshots/android_connected.png

You can now use the RenderDoc UI as normal, and the entire workflow is exactly the same as you are used to on desktop, except that the capture and replay will happen on the selected android device. For example, when you click browse for an executable to run, it will list the installed packages.

If your package is not debuggable, you will not generally be able to capture it with RenderDoc. Instead build a development copy of your package that has the debuggable flag. In UE4 this is done by unchecking "For Distribution" and in Unity this is done by building a "Development Mode" build.

.. figure:: ../imgs/Screenshots/android_browsepackages.png

Then once connected, you can trigger captures and open them as normal.

Avoiding timeouts on certain packages
-------------------------------------

If your package can take a long time to startup, you can go to the :doc:`settings window <../window/settings_window>` under the :guilabel:`Android` section and increase the :guilabel:`Max Connection Timeout`.

Troubleshooting
---------------

The Android remote server runs with a foreground service notification while capture and replay are available. This keeps the server process active when the game is in front and holds a CPU wake lock for the server session. Shutting down the remote server, or closing its task on the device, stops the service and releases the wake lock. A notification remains while the server is listening even if no desktop client is connected; use the remote context shutdown action to stop it when finished.

If a connection only recovers after bringing RenderDocCmd to the front, check that its remote server notification is present and that the Android APK matches your desktop build. Some device ROMs freeze background processes instead of killing them, including processes with a running foreground service. An existing PID or an active service alone does not prove that the server is responding. See `Android's foreground service documentation <https://developer.android.com/develop/background-work/services/fgs/launch>`_ for the service lifecycle.

On affected OnePlus/OPPO devices, open RenderDocCmd's app details, select its battery usage settings, and enable :guilabel:`Allow background activity` while keeping :guilabel:`Allow foreground activity` enabled. If available, set battery optimization to :guilabel:`Don't optimize`. Recheck these settings after uninstalling and reinstalling the APK; arm32 and arm64 are separate apps. If service diagnostics show an active foreground service but connections still time out, obtain its PID with ``adb shell pidof org.renderdoc.renderdoccmd.arm64`` and inspect ``adb shell run-as org.renderdoc.renderdoccmd.arm64 cat /proc/<pid>/task/<pid>/wchan``. A wait channel of ``do_freezer_trap`` indicates the kernel has frozen the process, even if ``dumpsys activity processes`` reports ``isFrozen=false``. Use the arm32 package name when diagnosing that APK.

If background activity is already allowed but the process still freezes when the game is in front, add the affected RenderDocCmd APK to the system battery optimization exemptions. This can also be configured from adb with ``adb shell dumpsys deviceidle whitelist +org.renderdoc.renderdoccmd.arm64`` (and ``+org.renderdoc.renderdoccmd.arm32`` for the other APK). Verify the package appears in ``adb shell dumpsys deviceidle whitelist``, then retest capture and replay with the game in front. To remove an exemption, use the same command with ``-`` instead of ``+``. These are device settings; reinstalling the APK or resetting app settings may require configuring them again.

RenderDoc assumes your device is already configured for debugging. Check that it appears in ``adb devices``. `See here <https://developer.android.com/studio/run/device.html>`_ for instructions on how to configure that.

If you have Android Studio open, it will interfere with RenderDoc's debugging by attaching to the package itself. Either close it or disable ``adb`` integration in :guilabel:`Tools → Android → Enable ADB integration`.

If launching reports that GPU debug layer configuration failed, inspect the failed setting, expected and actual values, and adb error in the dialog. RenderDoc also records the full command output and adb path in its diagnostic log. A later JDWP injection failure or startup timeout can occur after this configuration failure; the dialog retains both errors.

An error mentioning ``android.permission.WRITE_SECURE_SETTINGS`` means the device refused to change its GPU debug settings. On OnePlus/OPPO devices with this option, enable :guilabel:`Disable permission monitoring` in Developer options. On Xiaomi devices, enable :guilabel:`USB debugging (Security Settings)`. Reconnect the device, confirm USB debugging authorization, and retry. Enabling :guilabel:`Enable GPU debug layers` alone does not grant permission to write the other required settings.

For example, test the permission with ``adb shell settings put global enable_gpu_debug_layers 1`` and verify it with ``adb shell settings get global enable_gpu_debug_layers``. The write must complete without a permission error and the read must return ``1``. RenderDoc configures the remaining app and layer settings when launching. Developer options vary by device; `Arm's Android device setup guide <https://documentation-service.arm.com/static/6627b51c2f51dc4fe7263a0c>`_ also describes the permission monitoring option.

If adb reports ``device offline`` or ``unauthorized``, restore the connection before retrying. If it reports a server/client version mismatch, configure RenderDoc to use the same Android SDK as other tools. Close clients using another adb version, restart adb with that SDK's ``platform-tools/adb``, and reconnect the device. Older adb clients may automatically restart an incompatible server, disrupting existing connections.

On Android 11 and later, the RenderDoc layer APK must be visible to the target application. A ``GraphicsEnvironment`` logcat message saying ``Debug layer app ... not installed`` can mean package visibility is missing even though adb lists the APK as installed. RenderDoc checks this visibility when starting the remote server, repairs it by reinstalling in place, and retains ``--force-queryable`` and permission flags on installation retries. When installing the APK manually, use ``adb install -r -g --force-queryable <RenderDoc APK>`` from the matching RenderDoc build. Installing again without ``--force-queryable`` can remove the visibility override.

RenderDoc does its best to locate or provide necessary Android tools from the Android SDK. On Windows, these tools are shipped with the distributions and all that's required is java - either in your ``PATH`` or via the ``JAVA_HOME`` environment variable. If these tools aren't present then RenderDoc searches through ``PATH`` and other variables like ``ANDROID_HOME`` or ``ANDROID_SDK_ROOT`` to find the SDK. If you don't have those environment variables set, you can browse to the SDK and JDK folders in the :doc:`settings window <../window/settings_window>` under the :guilabel:`Android` section.

If something goes wrong with these steps, please `open an issue on GitHub <https://github.com/baldurk/renderdoc/issues/new/choose>`__! The process should be as smooth as possible given Android's platform limitations, so if you encounter problems then it may well be fixable.
