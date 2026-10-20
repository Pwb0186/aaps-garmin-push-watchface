import Toybox.Lang;

using Toybox.Application.Properties;
using Toybox.Application.Storage;
using Toybox.Background;
using Toybox.Math;
using Toybox.System;
using Toybox.Time;

module Shared {
module BackgroundScheduler {
  const TAG = "BackgroundScheduler";

  const IMMEDIATE_SCHEDULING_DELAY = 0;

  // How often are we allowed to schedule background events. 5 min.
  const MIN_SCHEDULE_DELAY = 5 * 60;

  // If next scheduled time is that much after next expected reading
  // skip one reading.
  const ACCEPTABLE_EXTRA_DELAY = 15;

  var registered = false;
  var nextScheduleTimeSec as Number?;
  var schedule = false;

  // While push works, the watch's own fetch is only a fallback and is planned
  // this long after the expected reading. AAPS normally pushes a new reading
  // 6-14 s after the CGM timestamp, so the push fetch comes first and
  // backgroundComplete() moves the fallback on to the next cycle. A fallback at
  // +5 s would run at the same moment as the push and fetch most readings twice.
  const PUSH_FALLBACK_DELAY_SEC = 60;

  // How long after the last push the watch still counts on push. Past this (push
  // channel dead, AAPS not sending) the fallback goes back to +5 s.
  const PUSH_ACTIVE_SEC = 15 * 60;

  // Storage key: time (epoch sec) of the last fetch started by an AAPS push.
  const LAST_PUSH_KEY = "LastPushSec";

  // The phone doesn't get new readings immediately, so add some
  // slack to avoid that we try to get it just before it's available.
  // While push works, wait PUSH_FALLBACK_DELAY_SEC so the push goes first.
  function extraReadingDelay() as Number {
    var wait = Util.ifNull(Properties.getValue("GlucoseValueWaitSec"), 5) as Number;
    return isPushActive() ? Util.max(wait, PUSH_FALLBACK_DELAY_SEC) : wait;
  }

  function isPushActive() as Boolean {
    var last = Storage.getValue(LAST_PUSH_KEY);
    return last instanceof Number && Util.nowSec() - (last as Number) < PUSH_ACTIVE_SEC;
  }

  // Called on the UI side when a fetch started by an AAPS push brought data
  // (GmwServer.onBackgroundData). Records the push and drops a fallback fetch
  // that is already registered - it would only fetch the same data again.
  // backgroundComplete(), called right after, plans the next one.
  //
  // Kept when a drain of waiting phone app messages is still due (set by init2):
  // only a temporal event does that (GlucoseServiceDelegate.drainPhoneAppMessagesOnce).
  function onPushData() as Void {
    // At most one Storage (flash) write a minute - a BG push and a loop push often
    // come within seconds of each other.
    var nowSec = Util.nowSec();
    var last = Storage.getValue(LAST_PUSH_KEY);
    if (!(last instanceof Number) || nowSec - (last as Number) >= 60) {
      Storage.setValue(LAST_PUSH_KEY, nowSec);
    }
    if (Storage.getValue("DrainPhoneMessages") == true) {
      return;
    }
    try {
      var regTime = Background.getTemporalEventRegisteredTime();
      if (regTime != null) {
        Background.deleteTemporalEvent();
        Log.i(TAG, "push data: dropped registered fallback event");
      }
    } catch (e) {
      Log.e(TAG, "push data ex: " + e.getErrorMessage());
    }
    registered = false;
    nextScheduleTimeSec = null;
  }

  // Frequency at which the CGM provides glucose readings. The default is 5 min.
  function readingFrequency() as Number {
    return Data.getGlucoseValueFrequencySeq();
  }

  // Computes when we expect the next value, usually 5 minutes plus a bit
  // after the last reading.
  function getNextValueTimeSec(nowSec, lastValueTimeSec) as Number? {
    if (lastValueTimeSec == null) { return null; }

    var missedReadings = (nowSec - lastValueTimeSec) / readingFrequency().toDouble();
    if (missedReadings > 6.0) {
      return null;
    } else {
      return (lastValueTimeSec
          + Math.ceil(missedReadings) * readingFrequency()).toNumber()
          + extraReadingDelay();
    }
  }

  // Computes the next time we should schedule a server lookup.
  //
  // @Param nowSec: Toybox.Lang.Integer
  //        Current time in seconds since the epoch
  // @Param lastValueTimeSec: Toybox.Lang.Integer
  //        Time of last glucose reading in seconds since the epoch.
  // @Param lastRunTime: Toybox.Lang.Integer
  //        Last time the background task run in secdonds since the
  //        epoch.
  // @Returns Toybox.Lang.Integer
  //          Time we should run the background task next in seconds
  //          since the epoch.
  function getNextRunTime(
      nowSec as Number,
      lastValueTimeSec as Number?,
      lastRunTimeSec as Number?) as Number {
    var nextRunTimeSec = lastRunTimeSec == null
                       ? nowSec + IMMEDIATE_SCHEDULING_DELAY
                       : lastRunTimeSec + MIN_SCHEDULE_DELAY;

    if (lastValueTimeSec == null) {
      Log.i(TAG, "now: " + Util.timeSecToString(nowSec) +
                 " last run: " + Util.timeSecToString(lastRunTimeSec) +
                 " earliest run: " + Util.timeSecToString(nextRunTimeSec));
      return nextRunTimeSec;
    }

    var nextValueSec = getNextValueTimeSec(nowSec, lastValueTimeSec);
    Log.i(TAG, "now: " + Util.timeSecToString(nowSec) +
               " last run: " + Util.timeSecToString(lastRunTimeSec) +
               " earliest run: " + Util.timeSecToString(nextRunTimeSec) +
               " last value: " + Util.timeSecToString(lastValueTimeSec) +
               " expect value: " + Util.timeSecToString(nextValueSec));

    if (nextValueSec == null) {
      // We don't know when the next reading happens, so run as soon as
      // possible.
      return nextRunTimeSec;
    }

    if (nextValueSec < nextRunTimeSec) {
      // We expect next value before we can run background process.
      // Compute how much extra delay we get if we schedule at earliest
      // time.
      var extraDelaySec = nextRunTimeSec - nextValueSec;
      // We might miss several readings, e.g. if we get a reading per minute.
      // Compute the time of the most recent reading before nextRunTimeSec.
      var freq = readingFrequency().toDouble();
      extraDelaySec -= (Math.floor(extraDelaySec / freq) * freq).toNumber();
      if (extraDelaySec < ACCEPTABLE_EXTRA_DELAY) {
        // We would access the next value ACCEPTABLE_EXTRA_DELAY sec
        // after it's available. That should be acceptable.
        return nextRunTimeSec;
      } else {
        // Skip glucose readings and get the next immediately, so
        // that we're better synchronized with the CGM schedule. For 5 minute
        // frequency like Dexcom G6, this would be always another 5min.
        return nextValueSec +
            (Math.ceil((nextRunTimeSec - nextValueSec) / freq) * freq).toNumber();
      }

    } else {
      // We expect next value later than last run time, so we can simply
      // schedule at that time.
      return nextValueSec;
    }
  }

  function scheduleTime(nowSec as Number, lastValueTimeSec as Number?) as Number {
    var lastRunTime = Background.getLastTemporalEventTime();
    var nextRunTimeSec = getNextRunTime(
        nowSec,
        lastValueTimeSec,
        lastRunTime == null ? null : lastRunTime.value());
    Log.i(TAG, "last run " + Util.momentToString(lastRunTime) +
        ", run background at " + Util.timeSecToString(nextRunTimeSec));
    nextRunTimeSec = Util.max(nowSec+2, nextRunTimeSec);
    return nextRunTimeSec;
  }

  // After every background result. The background process has already planned a run
  // about 6 min ahead (GlucoseServiceDelegate.registerNextRun). While the phone is
  // connected that is replaced right away with the time computed here (the same time
  // schedule2 would otherwise register within the next minute), so the timing does not
  // change while the watch face is on the screen. Without the phone the background's
  // run is kept.
  function backgroundComplete(lastDateSec as Number?) as Void {
    registered = false;
    var nowSec = Util.nowSec();
    nextScheduleTimeSec = scheduleTime(nowSec, lastDateSec);
    try {
      if (System.getDeviceSettings().phoneConnected) {
        var atSec = Util.max(nextScheduleTimeSec as Number, nowSec + 1);
        Background.registerForTemporalEvent(new Time.Moment(atSec));
        registered = true;
        nextScheduleTimeSec = atSec;
        Log.i(TAG, "complete: registered event at " + Util.timeSecToString(atSec));
      }
    } catch (e) {
      Log.e(TAG, "complete ex: " + e.getErrorMessage());
    }
  }

  function schedule2(lastDateSec, scheduleWithinSec) {
    var nowSec = Util.nowSec();
    if (!schedule) {
      if (lastDateSec == null || nowSec - lastDateSec > 660) {
        tryRegisterTemporalEventIn(new Time.Duration(2));
      }
      return;
    }
    if (registered && nextScheduleTimeSec != null && nowSec - nextScheduleTimeSec < 10) {
      return;
    }
    if (nextScheduleTimeSec == null) {
      nextScheduleTimeSec = scheduleTime(nowSec, lastDateSec);
    }
    // Only within scheduleWithinSec of the planned time: schedule2() can run every
    // second (onPartialUpdate on MIP displays), and the answer is only used here.
    // The window must be longer than the time between two calls - 65 s for a view
    // that only has onUpdate(), which runs once a minute in low power.
    if (nextScheduleTimeSec <= nowSec + scheduleWithinSec) {
      var regTime = Background.getTemporalEventRegisteredTime();
      if(System.getDeviceSettings().phoneConnected && regTime == null) {
        nextScheduleTimeSec = Util.max(nextScheduleTimeSec, nowSec + 1);
        Log.i(TAG, "schedule temporal event at " + Util.timeSecToString(nextScheduleTimeSec));
        try {
          Background.registerForTemporalEvent(new Time.Moment(nextScheduleTimeSec as Number));
          registered = true;
        } catch (e) {
          Log.e(TAG, e.getErrorMessage());
          e.printStackTrace();
          nextScheduleTimeSec += 5 * 60;
        }
      }
    }
  }

  function tryRegisterTemporalEventIn(d as Time.Duration) as Void {
    tryRegisterTemporalEventAt(Time.now().add(d));
  }

  function tryRegisterTemporalEventAt(t as Time.Moment) as Void {
    var nowSec = Util.nowSec();
    if (nowSec % 10 != 0) { return; }
    Log.i(TAG, "try schedule event at " + Util.momentToString(t));
    if (Background.getTemporalEventRegisteredTime() != null) { return; }
    // getLastTemporalEventTime() is null until the very first temporal event has
    // fired, and calling .value() on it then throws. Treat "never run" as "long
    // enough ago" so the first schedule after a fresh install works.
    var lastRunTime = Background.getLastTemporalEventTime();
    var lastSec = lastRunTime == null ? nowSec - (5 * 60 + 1) : lastRunTime.value();
    Log.i(TAG, "try schedule last " + Util.timeSecToString(lastSec));
    if (t.value() - lastSec < 5 * 60) { return; }
    try {
      Background.registerForTemporalEvent(t);
      nextScheduleTimeSec = t.value();
      Log.i(TAG, "scheduled event at " + Util.momentToString(t));
    } catch (e) {
      Log.e(TAG, e.getErrorMessage());
      e.printStackTrace();
    }
  }

  // Foreground start (GmwServer.init2 - watch face switch, reboot, install):
  // fetch as soon as Garmin allows, not when the next reading is expected.
  //
  // A temporal event may run at most once every 5 minutes. When the face is
  // started less than 5 minutes after its last run, a plain "run in 2 s" request
  // is not allowed, and the next expected reading would be computed from the
  // face's own last value, which after a switch is stale - so the first fetch
  // could come almost 5 minutes late. If AAPS has also dropped the face from its
  // push list, it gets no push in that time either, as its /get is what re-adds it.
  //
  // Schedules at now + 2 s, or right after the 5-minute limit when that is later.
  // A registration made here replaces any later one already registered.
  function registerAsSoonAsAllowed() as Void {
    try {
      if (!System.getDeviceSettings().phoneConnected) {
        Log.i(TAG, "start: phone not connected, left to schedule2");
        nextScheduleTimeSec = null;
        return;
      }
      var nowSec = Util.nowSec();
      var atSec = nowSec + 2;
      var lastRunTime = Background.getLastTemporalEventTime();
      if (lastRunTime != null && lastRunTime.value() + MIN_SCHEDULE_DELAY + 2 > atSec) {
        atSec = lastRunTime.value() + MIN_SCHEDULE_DELAY + 2;
      }
      Background.registerForTemporalEvent(new Time.Moment(atSec));
      registered = true;
      nextScheduleTimeSec = atSec;
      Log.i(TAG, "start: registered event at " + Util.timeSecToString(atSec) +
          " (last run " + Util.momentToString(lastRunTime) + ")");
    } catch (e) {
      Log.e(TAG, "start ex: " + e.getErrorMessage());
      e.printStackTrace();
      registered = false;
      nextScheduleTimeSec = null;
    }
  }
}
}
