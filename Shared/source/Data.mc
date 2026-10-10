import Toybox.Lang;

using Shared.Util;
using Toybox.Application.Properties;

module Shared {
class Data {
  private static const TAG = "Data";
  var glucoseBuffer as Shared.DateValues = new Shared.DateValues(null, 36);
  var glucoseUnit as GlucoseUnit = mgdl;
  var errorMessage as String?;
  var remainingInsulin as Float?;
  var remainingBasalInsulin as Float?;
  var carbsOnBoard as String?;
  var temporaryBasalRate as Float?;
  var temporaryTargetActive as Boolean = false;
  var temporaryTargetLow as Number?;
  var temporaryTargetHigh as Number?;
  var temporaryTargetReason as String?;
  var temporaryTargetEndSec as Number?;
  var temporaryTargetDurationMin as Number?;
  var connected as Boolean = true;
  // Epoch sec of the last answer from AAPS (0 = none since this app started).
  // Only kept in memory: it says whether the phone is reachable right now, which
  // is meaningless after a restart.
  var lastAapsContactSec as Number = 0;
  // True when the AAPS loop is enabled and running. Defaults to true so that an
  // older AAPS that does not send "loopEnabled" never shows the warning icon.
  var loopEnabled as Boolean = true;
   enum GlucoseUnit {
     mgdl = 1,
     mmoll = 2,
   }

  // Returns the frequency of glucose values in seconds from the
  // "GlucoseValueFrequencySec" property.
  static function getGlucoseValueFrequencySeq() as Number {
    var val = Properties.getValue("GlucoseValueFrequencySec");
    if (val == null || val <= 0 || val > 300) {
      return 300;
    } else {
      return val as Number;
    }
  }

  static function getLowBgMarkMgdl() as Number {
    var value = Properties.getValue("LowBgMarkMgdl");
    return value == null ? 74 : value.toNumber();
  }

  static function getHighBgMarkMgdl() as Number {
    var value = Properties.getValue("HighBgMarkMgdl");
    return value == null ? 180 : value.toNumber();
  }

  (:glance)
  function initialize() {
    try {
      restoreValues();
    } catch (e) {
      Log.i(TAG, "restored failed: " + e.getErrorMessage());
      clearRuntimeValues();
      errorMessage = "no value";
    }
  }

  private function clearRuntimeValues() as Void {
    glucoseBuffer.clear();
    remainingInsulin = null;
    remainingBasalInsulin = null;
    carbsOnBoard = null;
    temporaryBasalRate = null;
    clearTemporaryTarget();
    connected = true;
    loopEnabled = true;
    Properties.setValue("GlucoseValues", "");
    Properties.setValue("RemainingInsulin", 0);
    Properties.setValue("RemainingBasalInsulin", 0);
    Properties.setValue("CarbsOnBoard", "");
    Properties.setValue("TemporaryBasalRate", 1.0);
  }

  private function restoreValues() {
    var glucoseBufferStr = Util.ifNull(Properties.getValue("GlucoseValues"), "") as String;
    if (glucoseBufferStr.length() > 0) {
      glucoseBuffer.fromHexString(glucoseBufferStr);
      var dateSec = glucoseBuffer.getDateSec(glucoseBuffer.size()-1);
      if (Util.abs(Util.nowSec() - dateSec) > 3600) {
        Log.i(TAG, "stored value too old " + Util.timeSecToString(dateSec));
        glucoseBuffer.clear();
      } else {
        remainingInsulin = Properties.getValue("RemainingInsulin");
        remainingBasalInsulin = Properties.getValue("RemainingBasalInsulin");
        carbsOnBoard = Properties.getValue("CarbsOnBoard");
        temporaryBasalRate = Properties.getValue("TemporaryBasalRate");
        restoreTemporaryTarget();
        Log.i(TAG, "restored "+ glucoseBuffer.size() + " " + glucoseBuffer.get(glucoseBuffer.size() - 1));
      }
    }
    if (!hasValue()) {
      Log.i(TAG, "no glucose stored");
      errorMessage = "no value";
    }
    var glucoseUnitStr = Properties.getValue("GlucoseUnit");
    glucoseUnit = "mmoll".equals(glucoseUnitStr) ? mmoll : mgdl;
    Properties.setValue("GlucoseValueFrequencySec", getGlucoseValueFrequencySeq());
  }

  // Called on every answer from AAPS (GmwServer.onHttpData).
  function onAapsContact() as Void {
    lastAapsContactSec = Util.nowSec();
  }

  // True when AAPS answers but has no fresh glucose value, i.e. the CGM is the
  // problem and not the connection between watch and phone. Both must hold:
  // AAPS was reached within the last 10 min, and its newest value is older than
  // two missed readings.
  function hasSensorIssue() as Boolean {
    if (lastAapsContactSec == 0) { return false; }
    if (Util.nowSec() - lastAapsContactSec > 10 * 60) { return false; }
    var ageSec = getGlucoseAgeSec();
    return ageSec == null || ageSec > 11 * 60;
  }

  // True when the numbers that come from AAPS itself (IOB, COB, basal) can be
  // trusted: AAPS answered within the last 10 min, or - before the first answer
  // after a restart - there is a fresh glucose value. Only BG, delta and the
  // trend arrow depend on the CGM, so they keep using hasValue().
  function hasFreshLoopData() as Boolean {
    if (lastAapsContactSec != 0 && Util.nowSec() - lastAapsContactSec <= 10 * 60) {
      return true;
    }
    return hasValue();
  }

  // Returns true iff we have a blood glucose reading.
  function hasValue() as Boolean {
    return glucoseBuffer.size() > 0 && (Util.nowSec() - glucoseBuffer.getLastDateSec()) < 16 * 60;
  }

  // Null-safe equality check, used by the setters below to avoid
  // unnecessary Properties.setValue() writes (flash storage is slower
  // than regular memory) when an incoming value is unchanged.
  private function valuesEqual(a, b) as Boolean {
    if (a == null || b == null) {
      return a == b;
    }
    return a.equals(b);
  }

  function setTemporaryBasalRate(tbr as Float?) as Void {
    // AAPS leaves "temporaryBasalRate" out when no temp basal runs, i.e. 100 %.
    // Stored as 1.0 rather than null: Properties.setValue() does not accept null
    // (Properties.ValueType has no Null), and 1.0 is what the watch face shows anyway.
    if (tbr == null) { tbr = 1.0; }
    if (valuesEqual(tbr, temporaryBasalRate)) { return; }
    temporaryBasalRate = tbr;
    Properties.setValue("TemporaryBasalRate", tbr);
  }

  function setTemporaryTarget(active, low, high, reason, endSec, durationMin) as Void {
    var newActive = active == true;
    if (newActive) {
      if (temporaryTargetActive
          && valuesEqual(low as Number?, temporaryTargetLow)
          && valuesEqual(high as Number?, temporaryTargetHigh)
          && valuesEqual(reason as String?, temporaryTargetReason)
          && valuesEqual(endSec as Number?, temporaryTargetEndSec)
          && valuesEqual(durationMin as Number?, temporaryTargetDurationMin)) {
        return; // active TT unchanged - nothing to write
      }
      temporaryTargetActive = true;
      Properties.setValue("TemporaryTargetActive", true);
      temporaryTargetLow = low as Number?;
      temporaryTargetHigh = high as Number?;
      temporaryTargetReason = reason as String?;
      temporaryTargetEndSec = endSec as Number?;
      temporaryTargetDurationMin = durationMin as Number?;

      var storedLow = 0;
      var storedHigh = 0;
      var storedReason = "";
      var storedEndSec = 0;
      var storedDurationMin = 0;
      if (temporaryTargetLow != null) { storedLow = temporaryTargetLow as Number; }
      if (temporaryTargetHigh != null) { storedHigh = temporaryTargetHigh as Number; }
      if (temporaryTargetReason != null) { storedReason = temporaryTargetReason as String; }
      if (temporaryTargetEndSec != null) { storedEndSec = temporaryTargetEndSec as Number; }
      if (temporaryTargetDurationMin != null) { storedDurationMin = temporaryTargetDurationMin as Number; }
      Properties.setValue("TemporaryTargetLow", storedLow);
      Properties.setValue("TemporaryTargetHigh", storedHigh);
      Properties.setValue("TemporaryTargetReason", storedReason);
      Properties.setValue("TemporaryTargetEndSec", storedEndSec);
      Properties.setValue("TemporaryTargetDurationMin", storedDurationMin);
    } else {
      if (!temporaryTargetActive) { return; } // already inactive - nothing to write
      clearTemporaryTarget();
    }
  }

  private function clearTemporaryTarget() as Void {
    temporaryTargetActive = false;
    temporaryTargetLow = null;
    temporaryTargetHigh = null;
    temporaryTargetReason = null;
    temporaryTargetEndSec = null;
    temporaryTargetDurationMin = null;
    Properties.setValue("TemporaryTargetActive", false);
    Properties.setValue("TemporaryTargetLow", 0);
    Properties.setValue("TemporaryTargetHigh", 0);
    Properties.setValue("TemporaryTargetReason", "");
    Properties.setValue("TemporaryTargetEndSec", 0);
    Properties.setValue("TemporaryTargetDurationMin", 0);
  }

  private function restoreTemporaryTarget() as Void {
    var active = Properties.getValue("TemporaryTargetActive") == true;
    if (!active) {
      return;
    }

    var endSecValue = Properties.getValue("TemporaryTargetEndSec");
    var endSec = endSecValue == null ? 0 : endSecValue.toNumber();
    if (endSec > 0 && endSec <= Util.nowSec()) {
      clearTemporaryTarget();
      return;
    }

    temporaryTargetActive = true;
    temporaryTargetLow = Properties.getValue("TemporaryTargetLow") as Number?;
    temporaryTargetHigh = Properties.getValue("TemporaryTargetHigh") as Number?;
    temporaryTargetReason = Properties.getValue("TemporaryTargetReason") as String?;
    temporaryTargetEndSec = endSec;
    temporaryTargetDurationMin = Properties.getValue("TemporaryTargetDurationMin") as Number?;
  }

  function hasTemporaryTarget() as Boolean {
    if (!temporaryTargetActive) {
      return false;
    }
    // AAPS sends no push when a TT simply runs out (nothing changes in its
    // database), so without this check an expired TT stayed on the watch until
    // the next poll. Honour the end time locally; the next /get reply clears the
    // stored state. Only for TTs with a real duration - durationMin 0/null is
    // left alone, so a TT is never hidden on missing data.
    var endSec = temporaryTargetEndSec;
    var durationMin = temporaryTargetDurationMin;
    if (endSec != null && endSec > 0 &&
        durationMin != null && durationMin > 0 &&
        endSec <= Util.nowSec()) {
      return false;
    }
    return true;
  }

  private function getTemporaryTargetValueStr(value as Number?) as String {
    if (value == null) {
      return "";
    }
    if (glucoseUnit == mmoll) {
      return (value / 18.0).format("%0.1f");
    }
    return value.toString();
  }

  function getTemporaryTargetStr() as String {
    if (!temporaryTargetActive) {
      return "";
    }
    var low = getTemporaryTargetValueStr(temporaryTargetLow);
    var high = getTemporaryTargetValueStr(temporaryTargetHigh);
    if ("".equals(low) && "".equals(high)) {
      return "TT";
    }
    if ("".equals(high) || low.equals(high)) {
      return "TT " + low;
    }
    if ("".equals(low)) {
      return "TT " + high;
    }
    return "TT " + low + "-" + high;
  }

  function getBasalCorrectionStr() as String {
    if (!hasFreshLoopData()) { return "---"; }
    var tbr = Util.ifNullFloat(temporaryBasalRate, 1.0);
    return (tbr * 100).format("%0.0f") + "%";
  }

  function getBasalCorrectionState() as Number {
    var tbr = Util.ifNullFloat(temporaryBasalRate, 1.0);
    if (tbr < 1.0) {
      return -1;
    } else if (tbr > 1.0) {
      return 1;
    }
    return 0;
  }

  function setRemainingInsulin(remainingInsulin as Float?, remainingBasalInsulin as Float?) as Void {
    if (valuesEqual(remainingInsulin, me.remainingInsulin) && valuesEqual(remainingBasalInsulin, me.remainingBasalInsulin)) {
      return;
    }
    me.remainingInsulin = remainingInsulin;
    me.remainingBasalInsulin = remainingBasalInsulin;
    Properties.setValue("RemainingInsulin", remainingInsulin);
    Properties.setValue("RemainingBasalInsulin", remainingBasalInsulin);
  }

  function getRemainingInsulinStr() as String {
    if (remainingInsulin == null || !hasFreshLoopData()) {
      return "---";
    }
    var r = remainingInsulin;
    if (Properties.getValue("ShowTotalRemainingInsulin") and remainingBasalInsulin != null) {
      r += remainingBasalInsulin;
    }
    return r.format("%0.2f") + "U";
  }

  function setCarbsOnBoard(cob) as Void {
    var newValue;
    if (cob == null || "".equals(cob)) {
      newValue = null;
    } else if (cob instanceof Float || cob instanceof Double) {
      // Cut to whole grams, like the AAPS overview: CobInfo.displayText() uses
      // displayCob.toInt() (19.9 -> 19), so the watch shows the same number.
      newValue = cob.toNumber().toString();
    } else if (cob instanceof Number) {
      newValue = cob.toString();
    } else {
      newValue = cob.toString();
    }
    if (valuesEqual(newValue, carbsOnBoard)) { return; }
    carbsOnBoard = newValue;
    Properties.setValue("CarbsOnBoard", carbsOnBoard == null ? "" : carbsOnBoard);
  }

  function getCarbsOnBoardStr() as String {
    if (carbsOnBoard == null || "".equals(carbsOnBoard) || !hasFreshLoopData()) {
      return "---";
    }
    return carbsOnBoard;
  }

  // Returns the last glucose reading formatted in the selected
  // unit.
  //
  // @Returns Toybox.Lang.String
  function getGlucoseStr() as String {
    if (!hasValue()) { return "---"; }
    var glucose = glucoseBuffer.getLastValue();
    switch (glucoseUnit) {
      case mgdl:
        return glucose.toString();
      case mmoll:
        glucose = glucose / 18.0;
        return glucose.format("%0.1f");
    }
    return "";  // unreachable
  }

  function getGlucoseUnitStr() as String {
    return glucoseUnit == mmoll ? "mmoll" : "mgdl";
  }

  function setGlucoseUnit(glucoseUnit as GlucoseUnit) as Void {
    if (glucoseUnit == me.glucoseUnit) { return; }
    me.glucoseUnit = glucoseUnit;
    Properties.setValue("GlucoseUnit", getGlucoseUnitStr());
  }

  // Gets how old the last blood glucose reading is as a formatted
  // string of the form min:sec or only min if it's longer than
  // 10min ago.
  //
  // @Returns Toybox.Lang.String
  function getGlucoseAgeStr() as String {
    if (!hasValue() || getGlucoseAgeSec() > 26 * 60) {
      return "OLD";
    }
    var t = getGlucoseAgeSec();
    return (t / 60).toString() + "m";
  }

  function getGlucoseAgeSec() {
    return !hasValue() ? null : (Util.nowSec() - glucoseBuffer.getLastDateSec());
  }

  // Change between the latest two readings (a 5-min delta with a 5-min CGM),
  // not a per-minute rate - hence the name.
  function getGlucoseDelta() {
    if (glucoseBuffer.size() > 1) {
      var last = glucoseBuffer.get(glucoseBuffer.size() - 1);
      var previous = glucoseBuffer.get(glucoseBuffer.size() - 2);
      // AAPS shows the change between the latest two CGM values.
      return last.value - previous.value;
    } else {
      return null;
    }
  }

  function getTrendArrow(deltaMmoll as Float) as String {
    if (deltaMmoll >= 1.0) {
      return " ↑↑";
    } else if (deltaMmoll >= 0.6) {
      return " ↑";
    } else if (deltaMmoll >= 0.2) {
      return " ↗";
    } else if (deltaMmoll <= -1.0) {
      return " ↓↓";
    } else if (deltaMmoll <= -0.6) {
      return " ↓";
    } else if (deltaMmoll <= -0.2) {
      return " ↘";
    }
    return " →";
  }

  // Gets the AAPS-style glucose change between the latest two readings.
  //
  // @Returns Toybox.Lang.String
  function getGlucoseDeltaStr() as String {
    if (!hasValue()) {
      return "+_.__";
    }
    var delta = getGlucoseDelta();
    if (delta != null) {
      var deltaMmoll = delta / 18.0;
      switch (glucoseUnit) {
        case mmoll: return deltaMmoll.format("%+0.1f");
        case mgdl: return delta.format("%+0.0f");
      }
      return "";
    } else {
      return "+_.__";
    }
  }

  function getGlucoseTrendArrowStr() as String {
    if (!hasValue()) {
      return "";
    }
    var delta = getGlucoseDelta();
    if (delta == null) {
      return "";
    }
    return getTrendArrow(delta / 18.0);
  }

  // Notify that glucoseBuffer was updated.
  function updateGlucose(glucoseBuffer as DateValues) as Void {
    me.glucoseBuffer = glucoseBuffer;
    var hex = glucoseBuffer.toHexString();
    var last = glucoseBuffer.getLastValue();
    Properties.setValue("GlucoseValues", hex);
    var glucoseFrequencySec = Properties.getValue("GlucoseValueFrequencyOverrideSec");
    if (glucoseFrequencySec == 0) {
      glucoseFrequencySec = 60 * (Util.ifNull(glucoseBuffer.medianDeltaMinute(), 300) as Number);
    }
    if (glucoseFrequencySec == null || glucoseFrequencySec <= 0 || glucoseFrequencySec > 300) {
      glucoseFrequencySec = 300;
    }
    Log.i(TAG,
      "updateGlucose " + glucoseBuffer.size() + " values, " +
      "last " + (last==null?"NULL":last) + " freq " + glucoseFrequencySec);
    if (glucoseFrequencySec != null && glucoseFrequencySec > 0) {
      Properties.setValue("GlucoseValueFrequencySec", glucoseFrequencySec);
    }
    onError(last == null ? "no value" : null);
  }

  function onError(errorMessage as String?) as Void {
    me.errorMessage = errorMessage;
  }
}}
