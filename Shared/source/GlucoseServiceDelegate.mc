import Toybox.Lang;

using Toybox.ActivityMonitor;
using Toybox.Application.Properties;
using Toybox.Background;
using Toybox.Communications as Comm;
using Toybox.System;

module Shared {

(:background, :glance)
class GlucoseServiceDelegate extends System.ServiceDelegate {
  private static const TAG = "GlucoseServiceDelegate";
  private var key = Properties.getValue("AAPSKey");
  private var httpClient as HttpClient;
  // Steps/HR are marked as sent only once AAPS has answered 200 (onGetResult), so a
  // request that never reaches the phone does not use up the 4-minute throttle.
  private var sentStepsSec as Number? = null;
  private var sentHrSec as Number? = null;
  private var staleMessageCount as Number = 0;
  // Diagnostics sent along with /get, so they show up in the phone's logcat
  // (AAPS logs the full request URL) - the watch's own log needs a USB cable.
  //   trig     what started this pull: "push" or "timer"
  //   drained  waiting phone app messages cleared by drainPhoneAppMessagesOnce()
  //   pusherr  last PhoneAppMessageError code; kept until AAPS has answered 200
  // AAPS ignores parameters it does not know.
  private var trigger as String = "timer";
  private var drainedCount as Number? = null;
  private var resultCallback as (Method(result as Dictionary<String, Object>) as Void)?;

  // Initializes a new instance.
  //
  // @Param url (String)
  //        URL of the request.
  function initialize(url as String) {
    System.ServiceDelegate.initialize();
    // Same wording for 404 and "never reached the server": for this app the server is
    // AAPS on the phone, so both point at the same fix.
    me.httpClient = new HttpClient(
        url, "Enable Garmin in AAPS config", "Enable Garmin in AAPS config");
  }

  function onTemporalEvent() as Void {
    // Diagnostics only: REGISTERED does not prove the push channel works - only
    // "AAPS Push received" in onPhoneAppMessage2() does. The channel is renewed on
    // foreground start (getInitialView() in the watch face's app class).
    Log.i(TAG, "Phone app message registration status: " +
        (Background.getPhoneAppMessageEventRegistered() ? "REGISTERED" : "NOT REGISTERED"));
    drainPhoneAppMessagesOnce();
    key = Properties.getValue("AAPSKey");
    trigger = "timer";
    requestBloodGlucose(method(:exitWithResult));
  }

  // Clears phone app messages that are waiting for this app.
  //
  // The watch keeps messages for an app until the app takes them (SDK:
  // registerForPhoneAppMessages "... the callback will immediately be called once
  // for each waiting message"). A watch face that is not the active one never runs,
  // so AAPS pushes sent to it pile up, and the SDK lists
  // PHONE_APP_MESSAGE_ERROR_OUT_OF_STORAGE. Suspected cause of a watch face that
  // stops getting push until it is reinstalled.
  //
  // Runs once per foreground start: GmwServer.init2() sets the flag, the first
  // temporal event after it does the work. The flag is cleared BEFORE the attempt,
  // because a Permission Required error cannot be caught - a device that refuses
  // the call then loses one background run, not every one.
  private function drainPhoneAppMessagesOnce() as Void {
    if (Toybox.Application.Storage.getValue("DrainPhoneMessages") != true) {
      return;
    }
    Toybox.Application.Storage.setValue("DrainPhoneMessages", false);
    try {
      if (Comm has :registerForPhoneAppMessageErrors) {
        Comm.registerForPhoneAppMessageErrors(method(:onPhoneAppMessageError));
      }
    } catch (e) {
      Log.e(TAG, "registerForPhoneAppMessageErrors failed: " + e.getErrorMessage());
    }
    try {
      staleMessageCount = 0;
      Comm.registerForPhoneAppMessages(method(:onStalePhoneAppMessage));
      Comm.registerForPhoneAppMessages(null);
      Log.i(TAG, "Drained " + staleMessageCount + " waiting phone app messages");
      drainedCount = staleMessageCount;
    } catch (e) {
      Log.e(TAG, "Drain phone app messages failed: " + e.getErrorMessage());
    }
    try {
      if (Comm has :emptyMailbox) {
        Comm.emptyMailbox();
        Log.i(TAG, "emptyMailbox called");
      } else {
        Log.i(TAG, "emptyMailbox not available");
      }
    } catch (e) {
      Log.e(TAG, "emptyMailbox failed: " + e.getErrorMessage());
    }
  }

  function onStalePhoneAppMessage(msg as Comm.PhoneAppMessage) as Void {
    staleMessageCount++;
    Log.i(TAG, "Stale phone app message dropped (" + staleMessageCount + ")");
  }

  function onPhoneAppMessageError(err as Comm.PhoneAppMessageError) as Void {
    Log.e(TAG, "Phone app message error: " + err);
    Toybox.Application.Storage.setValue("PushErr", err as Number);
  }

  function exitWithResult(result as Dictionary<String, Object>) as Void {
    Background.exit(result);
  }

  // Sends today's total step count to AAPS as "steps", at most every 4 minutes.
  private function populateSteps(parameters as Dictionary<String, String>) as Void {
    // Off unless the watch face enables it (SendStepsToAaps). AAPS loops such as
    // OpenAPS AIMI read the steps and can reduce SMB, so a user must choose this.
    if (!Util.settingOn("SendStepsToAaps", true)) {
      return;
    }
    // Optional: no steps while an activity is running. AAPS then never sees the steps
    // of the activity (SMB-reducing loops react to them).
    if (Util.settingOn("PauseStepsInActivity", false) && isActivityRunning()) {
      return;
    }
    try {
      var nowSec = Util.nowSec();
      var lastSentSteps = Toybox.Application.Storage.getValue("LastSentStepsSec");
      // Throttle to at most once every 4 minutes (240 sec) to avoid unnecessary polling
      if (lastSentSteps != null && nowSec - lastSentSteps < 240) {
          Log.i(TAG, "Skipping steps, sent recently");
          return;
      }
      var info = Toybox.ActivityMonitor.getInfo();
      if (info != null && info.steps != null) {
        Log.i(TAG, "Steps " + info.steps);
        parameters["steps"] = info.steps.toString();
        sentStepsSec = nowSec;
      }
    } catch (e) {
      Log.e(TAG, "populateSteps err: " + (e == null ? "NULL" : e.getErrorMessage()));
    }
  }

  // True while an activity is started, paused or stopped but not yet saved
  // (Activity timerState 1-3; 0 = none). The background process can read it while an
  // activity runs, which the watch face itself cannot (the activity has the screen).
  // Every step is checked and caught: a device that refuses the call gives false, so
  // the steps are sent as usual.
  private function isActivityRunning() as Boolean {
    try {
      if (!(Toybox has :Activity) || !(Toybox.Activity has :getActivityInfo)) {
        return false;
      }
      var info = Toybox.Activity.getActivityInfo();
      if (info == null || !(info has :timerState)) {
        return false;
      }
      var state = info.timerState;
      return state != null && state > 0;
    } catch (e) {
      return false;
    }
  }

  private function populateHeartRateHistory(parameters as Dictionary<String, String>) as Void {
    if (!Util.settingOn("SendHeartRateToAaps", true)) {
      return;
    }
    try {
      var nowSec = Util.nowSec();
      var lastSentHR = Toybox.Application.Storage.getValue("LastSentHRSec");
      if (lastSentHR != null && nowSec - lastSentHR < 240) {
          Log.i(TAG, "Skipping HR, sent recently");
          return;
      }

      var startSec = Toybox.Application.Storage.getValue("HeartRateStartSec");
      var lastSec = Toybox.Application.Storage.getValue("HeartRateLastSec");
      var avg = Toybox.Application.Storage.getValue("HeartRateAvg");

      if (startSec != null && lastSec != null && avg != null &&
          avg > 0 && nowSec - lastSec < 600) {
        Log.i(TAG, "HR " + avg);
        parameters["hr"] = avg.toString();
        parameters["hrStart"] = startSec.toString();
        parameters["hrEnd"] = lastSec.toString();
        sentHrSec = nowSec;
      }
    } catch (e) {
      e.printStackTrace();
    }
  }

  // Adds the AAPS key to a request.
  private function withKey(parameters as Dictionary) as Dictionary {
    parameters["key"] = key;
    return parameters;
  }

  function requestBloodGlucose(callback as Method(result as Dictionary<String, Object>) as Void) as Void {
    var parameters = {};
    // No "from" parameter: AAPS (GarminPlugin.onGetBloodGlucose) ignores it and
    // always returns the last 2 h 9 min, which the 120-min graph needs anyway.

    sentStepsSec = null;
    sentHrSec = null;
    populateSteps(parameters);
    populateHeartRateHistory(parameters);
    parameters["trig"] = trigger;
    if (drainedCount != null) {
      parameters["drained"] = drainedCount.toString();
    }
    var pushErr = Toybox.Application.Storage.getValue("PushErr");
    if (pushErr != null) {
      parameters["pusherr"] = pushErr.toString();
    }

    resultCallback = callback;
    httpClient.get("get", method(:onGetResult), withKey(parameters));
  }

  function onGetResult(result as Dictionary<String, Object>) as Void {
    // Tells the UI side what started this fetch (GmwServer.onBackgroundData ->
    // BackgroundScheduler.onPushData), so a pending fallback fetch can be dropped.
    result["trig"] = trigger;
    // The key this fetch used, for GmwServer.onBackgroundData to save: a background
    // process cannot write Properties, so a key that came with a push would
    // otherwise be forgotten and the next timer fetch would get 401.
    if (key != null) {
      result["aapsKey"] = key;
    }
    if (result["httpCode"] == 200) {
      if (sentStepsSec != null) {
        Toybox.Application.Storage.setValue("LastSentStepsSec", sentStepsSec);
      }
      if (sentHrSec != null) {
        Toybox.Application.Storage.setValue("LastSentHRSec", sentHrSec);
      }
      Toybox.Application.Storage.deleteValue("PushErr");
    }
    if (resultCallback != null) {
      resultCallback.invoke(result);
    }
  }

  function onPhoneAppMessage(msg as Comm.PhoneAppMessage) as Void {
    onPhoneAppMessage2(msg, method(:exitWithResult));
  }

  // Handles a V2 wake-up signal from AAPS (GarminPlugin.sendPhoneAppMessageV2).
  // The payload only contains the key and "updateWatch" command - the watch
  // ignores the content and immediately fetches full data via HTTP GET (/get).
  // This eliminates the 30-second long-poll connection of the old V1 pull model.
  function onPhoneAppMessage2(
    msg as Comm.PhoneAppMessage,
    callback as Method(result as Dictionary<String, Object>) as Void) as Void {
    try {
      var msgData = msg.data instanceof Dictionary
          ? (msg.data as Dictionary<Object, Object>)
          : { "message" => msg.data };

      // Used for this fetch; saved by the foreground once AAPS has accepted it
      // (see onGetResult).
      var newKey = msgData["key"];
      if (newKey != null) {
        key = newKey;
      }

      Log.i(TAG, "AAPS Push received, fetching data from HTTP");
      trigger = "push";
      requestBloodGlucose(callback);
    } catch (e) {
      Log.e(TAG, "onPhoneAppMessage ex: " + (e == null ? "NULL" : e.getErrorMessage()));
      if (e != null) {
        e.printStackTrace();
      }
      // Always invoke callback so Background.exit() is called even on failure.
      // Without this, the OS times out the background context with no controlled
      // error report - more likely now that push is the primary trigger.
      callback.invoke({"errorMessage" => e == null ? "unknown error" : e.getErrorMessage(), "channel" => "http"});
    }
  }
}}
