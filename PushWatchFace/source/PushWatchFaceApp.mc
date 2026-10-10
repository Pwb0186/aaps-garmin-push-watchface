import Toybox.Lang;

using Shared;
using Shared.BackgroundScheduler;
using Shared.Log;
using Shared.Util;
using Toybox.Application;
using Toybox.Application.Properties;
using Toybox.Background;
using Toybox.System;
using Toybox.WatchUi as Ui;

/**
 * PushWatchFaceApp - reference implementation of AAPS V2 Push-to-Pull
 *
 * ============================================================================
 * ARCHITECTURE OVERVIEW (V2 Push-to-Pull):
 * ============================================================================
 * 1. REGISTRATION:
 *    During getInitialView(), the app calls:
 *       Background.deletePhoneAppMessageEvent();      // clear any stale record
 *       Background.registerForPhoneAppMessageEvent(); // then create a fresh one
 *    This registers this watchface with the Connect IQ OS so that messages sent
 *    from the Android phone (AAPS GarminPlugin) wake up our background delegate.
 *    The delete step matters: a plain register appears to be a no-op while a
 *    registration record already exists, and that record survives even after the
 *    channel behind it is dead (see the note in getInitialView below).
 *
 * 2. PUSH TRIGGER (Phone -> Watch):
 *    When AAPS calculates a new loop cycle or receives a CGM reading, it pushes
 *    a lightweight CIQ message via GarminDeviceClient.sendMessage().
 *    This contains: {"key": "<deviceKey>", "command": "updateWatch"}.
 *
 * 3. BACKGROUND WAKEUP & HTTP PULL (Watch ServiceDelegate):
 *    The watch wakes up in the background and calls:
 *       GlucoseServiceDelegate.onPhoneAppMessage() -> onPhoneAppMessage2()
 *    The delegate updates the AAPSKey and immediately fires an HTTP GET
 *    request to http://127.0.0.1:28891/get (routed via Garmin Connect Mobile).
 *    No "wait" parameter is sent - the data is already fresh on the phone.
 *
 * 4. DATA DELIVERY & REDRAW:
 *    When the HTTP pull completes, the background process returns the JSON payload
 *    to onBackgroundData(). The Shared.Data model parses IOB, COB, BG, DELTA,
 *    AGE, TT (Temporary Target), BR (Basal Rate), and glucose history.
 *    The view is requested to update immediately.
 * ============================================================================
 */
(:background)
class PushWatchFaceApp extends Application.AppBase {
  private var TAG = "PushWatchFaceApp";
  private var data;
  private var server;
  private var view;

  function initialize() {
    Log.i(TAG, "initialize");
    AppBase.initialize();

    // Initialize GmwServer (AAPS always returns the last ~2 h of glucose values)
    server = new Shared.GmwServer();
  }

  /**
   * Provides the background ServiceDelegate to the Connect IQ runtime.
   * This delegate receives both phone app push messages and temporal fallback events.
   */
  function getServiceDelegate() as [ System.ServiceDelegate ] {
    return [ server.createServiceDelegate() ];
  }

  /**
   * Called on the UI thread when the background process exits with fresh data.
   */
  function onBackgroundData(result) as Void {
    try {
      Log.i(TAG, "onBackgroundData received payload");
      if (data == null) {
        data = new Shared.Data();
      }

      // Delegate payload parsing to GmwServer and Data model
      server.onBackgroundData(result, data);

      if (result instanceof Dictionary && "http".equals(result["channel"])) {
        BackgroundScheduler.backgroundComplete(data.glucoseBuffer.getLastDateSec());
      }

      // Notify the view to refresh graph readings and repaint
      if (view != null) {
        view.onDataUpdated();
      }
    } catch (e) {
      e.printStackTrace();
      Log.i(TAG, "onBackgroundData error: " + Util.ifNull(e.getErrorMessage(), "NULL"));
    }
  }

  function onStart(state) as Void {
    Log.i(TAG, "onStart");
  }

  function onStop(state) as Void {
    Log.i(TAG, "onStop");
  }

  /**
   * Main entry point for the watchface UI.
   */
  function getInitialView() as [ Ui.Views ] or [ Ui.Views, Ui.InputDelegates ] {
    Properties.setValue("Device", System.getDeviceSettings().partNumber + "_PUSH");
    Properties.setValue("AppVersion", "push_v1");
    // KEEP IN SYNC with manifest.xml <iq:application id="...">
    Properties.setValue("AppId", "D0B1C2D3E4F54A6B8C7D9E0F1A2B3C4D");
    server.init2();

    // KEY STEP: Register for push notifications from the phone app (AAPS).
    //
    // Delete before register, instead of a plain register.
    // When another watch face takes over, this app's background process is torn
    // down after roughly an hour, and the phone app message channel can stay dead
    // afterwards. A plain registerForPhoneAppMessageEvent() here did not revive it
    // (polling resumed at once, push stayed dead) - only a full uninstall +
    // reinstall did, which suggests register is a no-op while a stale registration
    // record exists. Deleting first forces a fresh one - the same effect as
    // reinstalling.
    //
    // Runs on foreground start only (watch face switch, watch reboot, end of an
    // activity, install) - never in the 5-minute background cycle.
    try {
      Background.deletePhoneAppMessageEvent();
    } catch (e) {
      // Nothing registered to delete, or the call is unsupported - not an error.
    }
    Background.registerForPhoneAppMessageEvent();
    Log.i(TAG, "getInitialView: registered for PhoneAppMessageEvent (Push) - " +
        (Background.getPhoneAppMessageEventRegistered() ? "REGISTERED" : "NOT REGISTERED"));

    if (data == null) {
      data = new Shared.Data();
    }
    view = new PushWatchFaceView(data);
    return [view];
  }

  // On-watch settings: low and high BG mark (PushWatchFaceSettings).
  function getSettingsView() as [ Ui.Views ] or [ Ui.Views, Ui.InputDelegates ] or Null {
    return new PushWatchFaceSettings().get();
  }

  function onSettingsChanged() as Void {
    if (view != null) {
      view.onSettingsChanged();
      Ui.requestUpdate();
    }
  }
}
