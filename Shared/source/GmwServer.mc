import Toybox.Lang;

using Toybox.Application.Properties;
using Toybox.Application.Storage;

module Shared {
class GmwServer {
  private const TAG = "GmwServer";
  const url = "http://127.0.0.1:28891/";
  // Last msg["timestamp"] (epoch sec) successfully applied via onData().
  // Used to detect and discard stale/out-of-order HTTP responses.
  private var lastAppliedTimestampSec as Number = 0;
  private var lastStorageSavedTimestampSec as Number = 0;

  (:background, :glance)
  function initialize() {
    // Restore persisted timestamp from Storage so the stale-response guard is
    // effective immediately after an app restart. Storage persists across restarts
    // and does not require an XML definition in properties.xml.
    var stored = Storage.getValue("LastAppliedTimestampSec");
    if (stored instanceof Number) {
      lastAppliedTimestampSec = stored as Number;
      lastStorageSavedTimestampSec = lastAppliedTimestampSec;
    }
  }

  public function createServiceDelegate() as GlucoseServiceDelegate {
    return new GlucoseServiceDelegate(url);
  }

  function init2() {
    // Ask the next background run to clear waiting phone app
    // messages (GlucoseServiceDelegate.drainPhoneAppMessagesOnce). Not done here:
    // Toybox.Communications is not available to a watch face in the foreground
    // (Permission Required, which cannot be caught).
    Storage.setValue("DrainPhoneMessages", true);
    // Fetch as soon as Garmin's 5-minute limit allows - see
    // BackgroundScheduler.registerAsSoonAsAllowed().
    BackgroundScheduler.registerAsSoonAsAllowed();
    BackgroundScheduler.schedule = true;
  }

  private function valueOrNull(msg as Dictionary<String, Object>, key as String) {
    return msg.hasKey(key) ? msg[key] : null;
  }

  function onData(msg as Dictionary<String, Object>, data as Data) as Void{
    var values = Shared.DeltaVarEncoder.decodeBase64(2, msg["encodedGlucose"] as String);
    var newCount = values.size() / 2;

    // Use msg["timestamp"] (epoch sec) as the primary freshness signal,
    // independent of newCount: a guard that only ran when newCount>0 would let an
    // empty/delayed response bypass it and overwrite a valid buffer.
    // "Older strictly less than" is the gate: equal timestamp re-applies the same
    // response, which is safe (IOB/COB etc. may still be updated).
    var msgTimestampSec = valueOrNull(msg, "timestamp") as Number?;
    // A stored time far ahead of the watch's own clock comes from a phone clock that
    // was wrong and has since been corrected. Without this reset every answer would
    // be skipped as stale until real time caught up with the stored value.
    if (lastAppliedTimestampSec - Util.nowSec() > 10 * 60) {
      Log.i(TAG, "Stored timestamp " + lastAppliedTimestampSec + " is in the future, reset");
      lastAppliedTimestampSec = 0;
      lastStorageSavedTimestampSec = 0;
    }
    if (msgTimestampSec != null) {
      if (msgTimestampSec < lastAppliedTimestampSec) {
        Log.i(TAG, "Skipping stale response (ts=" + msgTimestampSec + " < last=" + lastAppliedTimestampSec + ")");
        return;
      }
      if (msgTimestampSec > lastAppliedTimestampSec) {
        lastAppliedTimestampSec = msgTimestampSec;
        // Throttle Storage (flash) writes to at most once every 300 seconds (5 min)
        if (lastAppliedTimestampSec - lastStorageSavedTimestampSec >= 300) {
          lastStorageSavedTimestampSec = lastAppliedTimestampSec;
          Storage.setValue("LastAppliedTimestampSec", lastAppliedTimestampSec);
        }
      }
    }

    var isNewGlucose = true;
    // Secondary glucose timestamp guard: if we already have data and the new
    // glucose timestamps are not newer, skip only the glucose update - the rest
    // (IOB/COB/basal/TT) is still applied since those may be fresher.
    if (newCount > 0 && data.glucoseBuffer != null && data.glucoseBuffer.size() > 0) {
      var newLatestTime = values[values.size() - 2] as Number;
      var oldLatestTime = data.glucoseBuffer.getDateSec(data.glucoseBuffer.size() - 1);
      if (newLatestTime <= oldLatestTime) {
        // Glucose data is identical to (or older than) what we already have.
        isNewGlucose = false;
      }
    }

    if (isNewGlucose) {
      data.updateGlucose(new DateValues(values, newCount));
    }
    data.setRemainingInsulin(msg["remainingInsulin"] as Float?, msg["remainingBasalInsulin"] as Float?);
    // AAPS leaves COB out while it is recalculating it; keep the last value then.
    if (msg.hasKey("carbsOnBoard")) {
      data.setCarbsOnBoard(msg["carbsOnBoard"]);
    }
    data.setTemporaryBasalRate(msg["temporaryBasalRate"] as Float?);
    data.setTemporaryTarget(
      valueOrNull(msg, "temporaryTargetActive"),
      valueOrNull(msg, "temporaryTargetLow"),
      valueOrNull(msg, "temporaryTargetHigh"),
      valueOrNull(msg, "temporaryTargetReason"),
      valueOrNull(msg, "temporaryTargetEndSec"),
      valueOrNull(msg, "temporaryTargetDurationMin"));
    // "profile" is also sent by AAPS (for older watch faces); not shown here.
    if (msg["glucoseUnit"] != null && "mmoll".equals(msg["glucoseUnit"])) {
      data.setGlucoseUnit(Data.mmoll);
    } else {
      data.setGlucoseUnit(Data.mgdl);
    }

    if (msg["connected"] instanceof Boolean) {
      data.connected = msg["connected"] as Boolean;
    }

    // Loop status. Left untouched when the field is absent, so an older AAPS that
    // does not send it keeps the default (true) and never shows the warning icon.
    if (msg["loopEnabled"] instanceof Boolean) {
      data.loopEnabled = msg["loopEnabled"] as Boolean;
    }
  }


  function onBackgroundData(
      result as Dictionary<String, Object> or Null,
      data as Data) as Void {
    if (result == null) {
      Log.e(TAG, "onBackgroundData NULL result");
      data.onError("null result");
      return;
    }
    if (!(result instanceof Dictionary)) {
      Log.e(TAG, "onBackgroundData bad result type " +  result.toString());
      data.onError("bad result type");
      return;
    }
    var channel = result["channel"];
    // Only the "http" channel is possible in V2: onPhoneAppMessage2 always calls
    // requestBloodGlucose(), which routes through HttpClient (channel="http").
    if ("http".equals(channel)) {
      saveAapsKey(result);
      onHttpData(result, data);
      // Push worked: the watch's own fetch this cycle is not needed.
      if ("push".equals(result["trig"]) && result["httpCode"] == 200) {
        BackgroundScheduler.onPushData();
      }
    } else {
      Log.e(TAG, "onBackgroundData unknown channel: " + channel);
    }
    Log.i(TAG, "onBackgroundData done " + channel);
  }

  // Saves the key a fetch used once AAPS has accepted it (HTTP 200). The background
  // process cannot write Properties, so a key that came with a push is saved here.
  private function saveAapsKey(result as Dictionary<String, Object>) as Void {
    var newKey = result["aapsKey"];
    if (result["httpCode"] == 200 && newKey instanceof String
        && !newKey.equals(Properties.getValue("AAPSKey"))) {
      Properties.setValue("AAPSKey", newKey);
      Log.i(TAG, "AAPS key from push saved");
    }
  }

  function onHttpData(
      result as Dictionary<String, Object> or Null,
      data as Data) as Void {
    var code = result["httpCode"];
    Log.i(TAG, "onBackgroundData " + Util.ifNull(code, -1).toString());
    try {
      if (code == 200) {
       data.onAapsContact();
       // AAPS answered, so an error from an earlier failed fetch no longer applies.
       // Otherwise it would stay (and hide the graph) until a fetch brought a new BG value -
       // up to 5 min, and for hours during a CGM gap. updateGlucose() may set it
       // again ("no value").
       data.onError(null);
       onData(result, data);
      } else {
        data.onError(result["errorMessage"]);
      }
    } catch (e) {
      Log.e(TAG, "ex ");
      e.printStackTrace();
      data.onError(e.getErrorMessage());
    }
  }
}
}
