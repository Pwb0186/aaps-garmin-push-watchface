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
  private var sentHrEndSec as Number? = null;
  // Longest heart rate period sent to AAPS (the watch face used 5 minutes before).
  private static const HR_PERIOD_SEC = 300;
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

  // Sends the heart rate since the last one AAPS accepted (at most the last 5 min) as
  // "hr" (average), "hrStart" and "hrEnd" (epoch sec), at most every 4 minutes.
  // Read here, just before the request, from the watch's heart rate history (about one
  // sample a minute). The background process can read it - also while an activity
  // runs, when the watch face itself does not run - so the value is fresh and
  // hrStart follows on from the last hrEnd without overlap.
  private function populateHeartRateHistory(parameters as Dictionary<String, String>) as Void {
    if (!Util.settingOn("SendHeartRateToAaps", true)) {
      return;
    }
    // No heart rate while an activity is running, unless the user turns this off: a data
    // field in the activity (e.g. swissalpine's) usually sends it then. On by default.
    if (Util.settingOn("PauseHeartRateInActivity", true) && isActivityRunning()) {
      return;
    }
    try {
      var nowSec = Util.nowSec();
      var lastSentHR = Toybox.Application.Storage.getValue("LastSentHRSec");
      if (lastSentHR != null && nowSec - lastSentHR < 240) {
          Log.i(TAG, "Skipping HR, sent recently");
          return;
      }
      var fromSec = nowSec - HR_PERIOD_SEC;
      var lastEnd = Toybox.Application.Storage.getValue("LastSentHrEndSec");
      if (lastEnd instanceof Number && lastEnd > fromSec && lastEnd <= nowSec) {
        fromSec = lastEnd as Number;
      }
      var hr = readHeartRate(fromSec);
      if (hr != null) {
        Log.i(TAG, "HR " + hr[0]);
        parameters["hr"] = hr[0].toString();
        parameters["hrStart"] = fromSec.toString();
        parameters["hrEnd"] = hr[1].toString();
        sentHrSec = nowSec;
        sentHrEndSec = hr[1];
      }
    } catch (e) {
      Log.e(TAG, "populateHeartRateHistory err: " + (e == null ? "NULL" : e.getErrorMessage()));
    }
  }

  // Average heart rate of the samples after fromSec, and the time of the newest one:
  // [average, newestSec], or null without samples (e.g. watch not worn). Uses
  // SensorHistory, and ActivityMonitor's heart rate history if that is not available.
  private function readHeartRate(fromSec as Number) as Array<Number>? {
    var sum = 0;
    var count = 0;
    var newestSec = 0;
    var done = false;
    try {
      if ((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getHeartRateHistory)) {
        var it = Toybox.SensorHistory.getHeartRateHistory({
          :period => new Toybox.Time.Duration(HR_PERIOD_SEC),
          :order => Toybox.SensorHistory.ORDER_OLDEST_FIRST
        });
        if (it != null) {
          for (var s = it.next(); s != null; s = it.next()) {
            if (s.data == null || s.when == null || s.when.value() <= fromSec) {
              continue;
            }
            sum += s.data.toNumber();
            count += 1;
            if (s.when.value() > newestSec) { newestSec = s.when.value(); }
          }
          done = true;
        }
      }
    } catch (e) {
      Log.e(TAG, "SensorHistory HR err: " + (e == null ? "NULL" : e.getErrorMessage()));
    }
    if (!done) {
      try {
        if (Toybox.ActivityMonitor has :getHeartRateHistory) {
          var it2 = Toybox.ActivityMonitor.getHeartRateHistory(new Toybox.Time.Duration(HR_PERIOD_SEC), false);
          if (it2 != null) {
            for (var s2 = it2.next(); s2 != null; s2 = it2.next()) {
              var v = s2.heartRate;
              if (v == null || v == Toybox.ActivityMonitor.INVALID_HR_SAMPLE
                  || s2.when == null || s2.when.value() <= fromSec) {
                continue;
              }
              sum += v;
              count += 1;
              if (s2.when.value() > newestSec) { newestSec = s2.when.value(); }
            }
          }
        }
      } catch (e) {
        Log.e(TAG, "ActivityMonitor HR err: " + (e == null ? "NULL" : e.getErrorMessage()));
      }
    }
    if (count == 0 || newestSec <= fromSec) {
      return null;
    }
    return [sum / count, newestSec];
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
    sentHrEndSec = null;
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
        Toybox.Application.Storage.setValue("LastSentHrEndSec", sentHrEndSec);
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
