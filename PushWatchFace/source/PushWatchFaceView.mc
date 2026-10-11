import Toybox.Lang;

using Shared;
using Shared.BackgroundScheduler;
using Shared.Log;
using Shared.Util;
using Toybox.ActivityMonitor;
using Toybox.Application.Properties;
using Toybox.Graphics as Gfx;
using Toybox.Math;
using Toybox.SensorHistory;
using Toybox.System;
using Toybox.Time as TimeModule;
using Toybox.Time.Gregorian as Calendar;
using Toybox.WatchUi as Ui;

/**
 * PushWatchFaceView - reference view for the AAPS V2 push-to-pull watch face.
 *
 * From the top:
 *
 *   date
 *   status icons | time | notifications
 *   age + TT     | GLUCOSE (range colour) | delta + trend arrow
 *   IOB | COB | basal (coloured captions over the values; LOOP OFF in red)
 *   graph (Shared.Graph), or AAPS's error message
 *   battery | heart rate (setting "Show heart rate") | steps
 *
 * Everything is drawn in code - no layout, no bitmaps - and placed from the real
 * font metrics, not fixed pixel positions: system fonts do not grow in step with
 * the screen, so a design scaled from one watch overlaps on others. onLayout()
 * stacks the rows from their font heights, keeps every row inside the circle at
 * its height, and gives the graph what is left. Where the large fonts do not fit
 * (narrow AMOLED fonts, small screens) it falls back to a smaller font set.
 *
 * Text is drawn by its baseline (drawTextAt). Row heights use the visible height
 * of digits and capitals: the font ascent less an estimate of the internal
 * leading, which Connect IQ does not report.
 *
 * Heart rate for AAPS is read by the background service (Shared
 * GlucoseServiceDelegate), not here.
 */
class PushWatchFaceView extends Ui.WatchFace {
  private static const TAG = "PushWatchFaceView";
  private const HR_SAMPLING_PERIOD_SEC = 300;

  private const GRAY = 0xAAAAAA;
  private const IOB_COLOR = 0x67DFE8;
  private const COB_COLOR = 0xFFAE01;
  private const BASAL_COLOR = 0xCF8BFE;

  // A graph lower than this (Shared.Graph uses 8 px of it as top margin) is too
  // small to read; the font set is made smaller instead.
  private const MIN_GRAPH_HEIGHT = 30;
  // The graph shows 2 hours of 5-minute values; Shared.Graph keeps 2 px between bars.
  private const GRAPH_VALUES = 24;
  private const GRAPH_BAR_PADDING = 2;

  private var data as Shared.Data;
  private var graph as Shared.Graph?;

  private var screenWidth as Number = 0;
  private var screenHeight as Number = 0;
  private var centerX as Number = 0;

  // Layout, computed in onLayout() (fitLayout).
  private var timeFont = Gfx.FONT_SYSTEM_NUMBER_MILD;
  private var glucoseFont = Gfx.FONT_SYSTEM_NUMBER_MEDIUM;
  private var smallFont = Gfx.FONT_SYSTEM_TINY;
  private var gap as Number = 0;
  private var iconSize as Number = 0;
  private var yDate as Number = 0;
  private var yTime as Number = 0;
  private var yGlucose as Number = 0;
  private var yColumnTop as Number = 0;
  private var yColumnBottom as Number = 0;
  private var columnMaxWidth as Number = 0;
  private var glucoseLeftExtent as Number = 0;
  private var glucoseRightExtent as Number = 0;
  private var columnGap as Number = 0;
  private var yLabel as Number = 0;
  private var yValue as Number = 0;
  private var loopSpacing as Number = 0;
  private var yGraphTop as Number = 0;
  private var graphHeight as Number = 0;
  private var yBottom as Number = 0;
  private var bottomSpacing as Number = 0;
  private var stepsMaxWidth as Number = 0;

  function initialize(data as Shared.Data) {
    WatchFace.initialize();
    me.data = data;
  }

  function onLayout(dc as Gfx.Dc) as Void {
    try {
      screenWidth = dc.getWidth();
      screenHeight = dc.getHeight();
      centerX = screenWidth / 2;

      // Largest fonts first: time, glucose, and the small text beside and below
      // the glucose value. The first set that fits is used; if none does, the
      // last (smallest) one is.
      var fontSets = [
        [Gfx.FONT_SYSTEM_NUMBER_MILD, Gfx.FONT_SYSTEM_NUMBER_MEDIUM, Gfx.FONT_SYSTEM_TINY],
        [Gfx.FONT_SYSTEM_LARGE, Gfx.FONT_SYSTEM_NUMBER_MILD, Gfx.FONT_SYSTEM_TINY],
        [Gfx.FONT_SYSTEM_LARGE, Gfx.FONT_SYSTEM_NUMBER_MILD, Gfx.FONT_SYSTEM_XTINY],
        [Gfx.FONT_SYSTEM_LARGE, Gfx.FONT_SYSTEM_LARGE, Gfx.FONT_SYSTEM_XTINY]
      ];
      var failed = "";
      var set = 0;
      while (true) {
        failed = fitLayout(dc, fontSets[set][0], fontSets[set][1], fontSets[set][2]);
        if (failed.length() == 0 || set == fontSets.size() - 1) {
          break;
        }
        set++;
      }
      Log.i(TAG, "onLayout: " + screenWidth + "x" + screenHeight + " font set " + set +
          (failed.length() > 0 ? " (does not fit: " + failed + ")" : "") +
          ", graph height " + graphHeight);

      graph = null;
      if (graphHeight >= MIN_GRAPH_HEIGHT) {
        // As wide as the circle allows at the graph's bottom edge, in whole bars:
        // Shared.Graph rounds the bar width up and keeps the right edge, so any
        // other width would shift the graph off centre.
        var available = 2 * (halfWidthAt(yGraphTop, yGraphTop + graphHeight) - gap);
        var barWidth = (available + GRAPH_BAR_PADDING) / GRAPH_VALUES;
        var graphWidth = GRAPH_VALUES * barWidth - GRAPH_BAR_PADDING;
        graph = new Shared.Graph({
            :identifier => "DateValueGraph",
            :x => centerX - graphWidth / 2 + 1,
            :y => yGraphTop,
            :width => graphWidth,
            :height => graphHeight,
            // Already kept inside the circle here.
            :roundEdgeOffset => false,
            :visible => true
        });
        updateGraphReadings();
      }
    } catch (e) {
      Log.e(TAG, "layout exception: " + e.getErrorMessage());
      e.printStackTrace();
    }
  }

  // Places every row for one font set. Returns the parts that do not fit
  // (empty when all do). The reference strings are wide, common values; rarer
  // wider ones (a TT range) are shrunk when drawn.
  private function fitLayout(dc as Gfx.Dc, timeF, glucoseF, smallF) as String {
    timeFont = timeF;
    glucoseFont = glucoseF;
    smallFont = smallF;
    var xtiny = Gfx.FONT_SYSTEM_XTINY;
    var failed = "";
    gap = Util.max(2, screenHeight / 65);
    var smallGap = Util.max(1, screenHeight / 130);
    iconSize = Util.max(6, (visibleHeight(dc, xtiny) * 0.6).toNumber());

    // Top: date, then the time with the status icons beside it.
    var y = (screenHeight * 0.05).toNumber();
    yDate = y + visibleHeight(dc, xtiny);
    var dateEnd = yDate + Gfx.getFontDescent(xtiny);
    if (dc.getTextWidthInPixels("Wed 30 Sep", xtiny) / 2 > halfWidthAt(y, dateEnd)) {
      failed += "date ";
    }
    y = dateEnd + gap;
    yTime = y + visibleHeight(dc, timeF);
    if (dc.getTextWidthInPixels("23:59", timeF) / 2 + gap + 2 * iconSize +
        dc.getTextWidthInPixels("9", xtiny) > halfWidthAt(y, yTime)) {
      failed += "time ";
    }
    var topEnd = yTime + gap;

    // Bottom: battery | heart rate | steps, where the circle is narrow.
    yBottom = screenHeight - (screenHeight * 0.10).toNumber();
    var bottomTop = yBottom - visibleHeight(dc, xtiny);
    // Room for five-digit steps where it fits, else for the short form "12.3k"
    // (getStepsStr uses the full number whenever it fits in stepsMaxWidth).
    var heartRateWidth = 2 * iconSize + 3 + dc.getTextWidthInPixels("180", xtiny);
    var bottomHalfWidth = halfWidthAt(bottomTop, yBottom);
    var batteryWidth = dc.getTextWidthInPixels("100%", xtiny);
    var sideWidth = Util.max(batteryWidth, dc.getTextWidthInPixels("12345", xtiny));
    if (bottomHalfWidth - sideWidth / 2 < heartRateWidth / 2 + sideWidth / 2 + gap) {
      sideWidth = Util.max(batteryWidth, dc.getTextWidthInPixels("12.3k", xtiny));
    }
    stepsMaxWidth = sideWidth;
    bottomSpacing = bottomHalfWidth - sideWidth / 2;
    if (bottomSpacing < heartRateWidth / 2 + sideWidth / 2 + gap) {
      failed += "bottom ";
    }

    // Heights of the glucose row (value, or the two lines beside it) and of the
    // IOB/COB/basal captions and values (with room for the "g" in "45g").
    var glucoseHeight = visibleHeight(dc, glucoseF);
    var columnHeight = 2 * visibleHeight(dc, smallF) + smallGap;
    var rowHeight = Util.max(glucoseHeight, columnHeight);
    var loopHeight = visibleHeight(dc, xtiny) + smallGap + visibleHeight(dc, smallF) +
        (Gfx.getFontDescent(smallF) * 0.6).toNumber();

    // The graph gets a sixth of the screen; it gives up height before the fonts
    // shrink, down to MIN_GRAPH_HEIGHT.
    graphHeight = (screenHeight * 0.17).toNumber();
    var free = bottomTop - gap - graphHeight - gap - loopHeight - gap - rowHeight - gap - topEnd;
    if (free < 0) {
      graphHeight = Util.max(MIN_GRAPH_HEIGHT, graphHeight + free);
      free = bottomTop - gap - graphHeight - gap - loopHeight - gap - rowHeight - gap - topEnd;
    }
    if (free < 0) {
      failed += "height ";
      free = 0;
    }

    // From the bottom up: graph, then the IOB/COB/basal rows above it.
    yGraphTop = bottomTop - gap - graphHeight;
    var loopEnd = yGraphTop - gap;
    var labelTop = loopEnd - loopHeight;
    yLabel = labelTop + visibleHeight(dc, xtiny);
    yValue = yLabel + smallGap + visibleHeight(dc, smallF);
    var leftWidth = Util.max(dc.getTextWidthInPixels("IOB", xtiny),
        dc.getTextWidthInPixels("1.25U", smallF));
    var middleWidth = Util.max(dc.getTextWidthInPixels("COB", xtiny),
        dc.getTextWidthInPixels("45g", smallF));
    var rightWidth = Util.max(Util.max(dc.getTextWidthInPixels("BASAL", xtiny),
        dc.getTextWidthInPixels("100%", smallF)), dc.getTextWidthInPixels("LOOP OFF", xtiny));
    loopSpacing = Util.min(screenWidth / 4,
        halfWidthAt(labelTop, loopEnd) - Util.max(leftWidth, rightWidth) / 2);
    if (loopSpacing < Util.max(leftWidth + middleWidth, middleWidth + rightWidth) / 2 + gap) {
      failed += "loop ";
    }

    // The glucose row in the middle of the space that is left.
    var rowTop = topEnd + free / 2;
    yGlucose = rowTop + (rowHeight - glucoseHeight) / 2 + glucoseHeight;
    yColumnTop = rowTop + (rowHeight - columnHeight) / 2 + visibleHeight(dc, smallF);
    yColumnBottom = yColumnTop + smallGap + visibleHeight(dc, smallF);
    // Room for the widest common values either side of the decimal point (mmol/l)
    // or the centre (mg/dl), so the columns do not move with the value.
    var halfDot = dc.getTextWidthInPixels(".", glucoseF) / 2;
    var halfMgdl = dc.getTextWidthInPixels("388", glucoseF) / 2;
    glucoseLeftExtent = Util.max(dc.getTextWidthInPixels("22", glucoseF) + halfDot, halfMgdl);
    glucoseRightExtent = Util.max(dc.getTextWidthInPixels("2", glucoseF) + halfDot, halfMgdl);
    columnGap = Util.max(4, screenWidth / 40);
    var rowHalfWidth = halfWidthAt(rowTop, rowTop + rowHeight);
    columnMaxWidth = rowHalfWidth - Util.max(glucoseLeftExtent, glucoseRightExtent) - columnGap;
    var leftColumn = Util.max(Util.max(dc.getTextWidthInPixels("12m", smallF),
        dc.getTextWidthInPixels("OLD", smallF)), dc.getTextWidthInPixels("10.0", smallF));
    var rightColumn = Util.max(dc.getTextWidthInPixels("+0.3", smallF),
        dc.getTextWidthInPixels("+12", smallF));
    if (leftColumn > columnMaxWidth || rightColumn > columnMaxWidth) {
      failed += "glucose ";
    }
    return failed;
  }

  // Height of digits and capitals above the baseline: the ascent less an estimate
  // of the internal leading (a tenth of the font height - on the safe side, the
  // real share is 10-25 %).
  private function visibleHeight(dc as Gfx.Dc, font) as Number {
    return Gfx.getFontAscent(font) - dc.getFontHeight(font) / 10;
  }

  // Half the usable width between y0 and y1: on a round screen the circle is
  // narrowest at the edge of the band farthest from the centre.
  private function halfWidthAt(y0 as Number, y1 as Number) as Number {
    if (System.getDeviceSettings().screenShape != System.SCREEN_SHAPE_ROUND) {
      return centerX - 2;
    }
    return Util.min(halfChord(y0), halfChord(y1)) - 2;
  }

  private function halfChord(y as Number) as Number {
    var r = screenWidth / 2.0;
    var dy = y - screenHeight / 2.0;
    if (dy < 0) { dy = -dy; }
    if (dy >= r) { return 0; }
    return Math.sqrt(r * r - dy * dy).toNumber();
  }

  function updateGraphReadings() as Void {
    try {
      if (graph != null && data != null) {
        graph.setReadings(data.glucoseBuffer);
      }
    } catch (e) {
      Log.e(TAG, "updateGraphReadings ex: " + e.getErrorMessage());
    }
  }

  /** Called by PushWatchFaceApp when fresh background data is delivered. */
  function onDataUpdated() as Void {
    updateGraphReadings();
    Ui.requestUpdate();
  }

  function onSettingsChanged() as Void {
    updateGraphReadings();
    Ui.requestUpdate();
  }

  function onEnterSleep() as Void {
    Ui.requestUpdate();
  }

  function onExitSleep() as Void {
    Ui.requestUpdate();
  }

  function onUpdate(dc as Gfx.Dc) as Void {
    try {
      onUpdateImpl(dc);
    } catch (e) {
      Log.e(TAG, "onUpdate error: " + e.getErrorMessage());
      e.printStackTrace();
      drawUpdateError(dc, e.getErrorMessage());
    }
  }

  private function drawUpdateError(dc as Gfx.Dc, errMsg as String?) as Void {
    try {
      dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
      dc.clear();
      dc.setColor(Gfx.COLOR_RED, Gfx.COLOR_TRANSPARENT);
      dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2 - 20,
          Gfx.FONT_SYSTEM_XTINY, "Render Error:", Gfx.TEXT_JUSTIFY_CENTER);
      dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2 + 5,
          Gfx.FONT_SYSTEM_XTINY, errMsg != null ? errMsg : "Unknown", Gfx.TEXT_JUSTIFY_CENTER);
    } catch (ignore) {
    }
  }

  private function onUpdateImpl(dc as Gfx.Dc) as Void {
    // The watch's own fallback fetch.
    // 65 s: this view has no onPartialUpdate, so outside the few seconds after a
    // wrist gesture onUpdate runs once a minute. With a shorter window the fetch was
    // only registered at the first update inside it - up to a minute late, which
    // matters when push is not working and the fallback is the only fetch.
    BackgroundScheduler.schedule2(data.glucoseBuffer.getLastDateSec(), 65);

    dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
    dc.clear();

    var sensorIssue = data.hasSensorIssue();
    drawTopRows(dc);
    drawGlucoseRow(dc, sensorIssue);
    drawLoopRow(dc);
    drawGraphOrMessage(dc);
    drawBottomRow(dc);
  }

  /** Draws text with its baseline at y. */
  private function drawTextAt(dc as Gfx.Dc, x as Number, y as Number, font, str as String,
      color as Number, justify as Number) as Void {
    dc.setColor(color, Gfx.COLOR_TRANSPARENT);
    dc.drawText(x, y - Gfx.getFontAscent(font), font, str, justify);
  }

  private function getGlucoseColor(sensorIssue as Boolean) as Number {
    if (sensorIssue || !data.hasValue()) {
      return GRAY;
    }
    var glucose = data.glucoseBuffer.getLastValue();
    if (glucose == null) {
      return GRAY;
    }
    if (glucose < Shared.Data.getLowBgMarkMgdl()) {
      return Gfx.COLOR_ORANGE;
    }
    if (glucose > Shared.Data.getHighBgMarkMgdl()) {
      return Gfx.COLOR_YELLOW;
    }
    return Gfx.COLOR_GREEN;
  }

  // ---------------------------------------------------------------------------
  // Date; status icons | time | notifications.
  // ---------------------------------------------------------------------------
  private function drawTopRows(dc as Gfx.Dc) as Void {
    var info = Calendar.info(TimeModule.now(), TimeModule.FORMAT_MEDIUM);
    drawTextAt(dc, centerX, yDate, Gfx.FONT_SYSTEM_XTINY,
        info.day_of_week.toString() + " " + info.day.toString() + " " + info.month.toString(),
        GRAY, Gfx.TEXT_JUSTIFY_CENTER);

    var clockTime = System.getClockTime();
    var hour = clockTime.hour;
    if (!System.getDeviceSettings().is24Hour) {
      hour = hour % 12;
      hour = (hour == 0) ? 12 : hour;
    }
    var timeStr = hour.format("%02d") + ":" + clockTime.min.format("%02d");
    drawTextAt(dc, centerX, yTime, timeFont, timeStr, Gfx.COLOR_WHITE, Gfx.TEXT_JUSTIFY_CENTER);

    // Icons beside the time, centred on its digits.
    var halfTime = dc.getTextWidthInPixels(timeStr, timeFont) / 2;
    var iconY = yTime - visibleHeight(dc, timeFont) / 2;
    var settings = System.getDeviceSettings();
    // Phone not connected, or AAPS reports the pump as disconnected.
    if (settings.phoneConnected != true || !data.connected) {
      drawBluetoothOff(dc, centerX - halfTime - gap - iconSize, iconY);
    }
    var count = settings.notificationCount;
    if (count != null && count > 0) {
      var envelopeX = centerX + halfTime + gap + iconSize;
      drawEnvelope(dc, envelopeX, iconY);
      dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
      dc.drawText(envelopeX + iconSize + 2, iconY, Gfx.FONT_SYSTEM_XTINY, count.toString(),
          Gfx.TEXT_JUSTIFY_LEFT | Gfx.TEXT_JUSTIFY_VCENTER);
    }
  }

  // Red Bluetooth rune with a slash, centred on (cx, cy), iconSize from the centre.
  private function drawBluetoothOff(dc as Gfx.Dc, cx as Number, cy as Number) as Void {
    var s = iconSize;
    var a = s / 2;      // half width of the rune
    var b = s * 7 / 8;  // half height of the rune
    dc.setColor(Gfx.COLOR_RED, Gfx.COLOR_TRANSPARENT);
    dc.setPenWidth(2);
    dc.drawLine(cx - a, cy - a, cx + a, cy + a * 3 / 4);
    dc.drawLine(cx + a, cy + a * 3 / 4, cx, cy + b);
    dc.drawLine(cx, cy + b, cx, cy - b);
    dc.drawLine(cx, cy - b, cx + a, cy - a * 3 / 4);
    dc.drawLine(cx + a, cy - a * 3 / 4, cx - a, cy + a);
    dc.drawLine(cx - s, cy - s, cx + s, cy + s);
    dc.setPenWidth(1);
  }

  // Small envelope, centred on (cx, cy), iconSize from the centre.
  private function drawEnvelope(dc as Gfx.Dc, cx as Number, cy as Number) as Void {
    var w = 2 * iconSize;
    var h = iconSize * 11 / 8;
    var left = cx - w / 2;
    var top = cy - h / 2;
    dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
    dc.setPenWidth(1);
    dc.drawRoundedRectangle(left, top, w, h, 2);
    dc.drawLine(left, top, cx, cy + 1);
    dc.drawLine(cx, cy + 1, left + w - 1, top);
  }

  // ---------------------------------------------------------------------------
  // Age + TT | glucose | delta + trend (or the sensor-issue triangle).
  // ---------------------------------------------------------------------------
  private function drawGlucoseRow(dc as Gfx.Dc, sensorIssue as Boolean) as Void {
    var glucoseStr = data.getGlucoseStr();
    drawCenteredOnDecimalPoint(dc, centerX, yGlucose, glucoseFont, glucoseStr,
        getGlucoseColor(sensorIssue));
    // With a sensor issue the last value is still shown, but struck through in
    // red alongside the warning triangle, so it is not read as a current value.
    if (sensorIssue) {
      drawStrikeThrough(dc, centerX, yGlucose - visibleHeight(dc, glucoseFont) / 2,
          glucoseFont, glucoseStr);
    }

    // Left column, right-aligned against the value: age, active TT below it.
    // The age is red with a sensor issue, orange when older than 10 minutes.
    var leftX = centerX - glucoseLeftExtent - columnGap;
    var ageSec = data.getGlucoseAgeSec();
    var ageColor = GRAY;
    if (sensorIssue) {
      ageColor = Gfx.COLOR_RED;
    } else if (ageSec != null && ageSec > 10 * 60) {
      ageColor = Gfx.COLOR_ORANGE;
    }
    drawTextAt(dc, leftX, yColumnTop, smallFont, ageSec != null ? data.getGlucoseAgeStr() : "---",
        ageColor, Gfx.TEXT_JUSTIFY_RIGHT);
    if (data.hasTemporaryTarget()) {
      var str = data.getTemporaryTargetStr(); // "TT", "TT 5.5" or "TT 5.0-6.0"
      var value = str.length() > 3 ? str.substring(3, str.length()) : "TT";
      if (value == null) {
        value = "TT";
      }
      // A TT range can be wider than the column: then in the smallest font.
      var font = dc.getTextWidthInPixels(value, smallFont) > columnMaxWidth
          ? Gfx.FONT_SYSTEM_XTINY : smallFont;
      drawTextAt(dc, leftX, yColumnBottom, font, value, Gfx.COLOR_YELLOW, Gfx.TEXT_JUSTIFY_RIGHT);
    }

    // Right column, left-aligned against the value: delta over trend arrow, or
    // the warning triangle.
    var rightX = centerX + glucoseRightExtent + columnGap;
    if (sensorIssue) {
      var halfHeight = Util.max(6, visibleHeight(dc, smallFont) * 6 / 10);
      drawWarningTriangle(dc, rightX + halfHeight * 115 / 100,
          (yColumnTop - visibleHeight(dc, smallFont) + yColumnBottom) / 2, halfHeight);
      return;
    }
    drawTextAt(dc, rightX, yColumnTop, smallFont, data.getGlucoseDeltaStr(),
        Gfx.COLOR_WHITE, Gfx.TEXT_JUSTIFY_LEFT);
    var arrowLength = visibleHeight(dc, smallFont) * 8 / 10;
    drawTrendArrow(dc, rightX + arrowLength / 2, yColumnBottom - visibleHeight(dc, smallFont) / 2,
        arrowLength, data.getGlucoseTrendArrowStr());
  }

  // Trend arrow drawn as a shape, centred on (cx, cy). The arrow characters from
  // Data.getGlucoseTrendArrowStr() are missing from some watch fonts - and from
  // the simulator's - which then show "?" instead.
  private function drawTrendArrow(dc as Gfx.Dc, cx as Number, cy as Number, length as Number,
      trend as String) as Void {
    var deg = null;
    var count = 1;
    if (trend.find("↑↑") != null) {
      deg = 90;
      count = 2;
    } else if (trend.find("↓↓") != null) {
      deg = -90;
      count = 2;
    } else if (trend.find("↑") != null) {
      deg = 90;
    } else if (trend.find("↓") != null) {
      deg = -90;
    } else if (trend.find("↗") != null) {
      deg = 45;
    } else if (trend.find("↘") != null) {
      deg = -45;
    } else if (trend.find("→") != null) {
      deg = 0;
    }
    if (deg == null) {
      return;
    }
    var head = length * 45 / 100;
    dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
    if (count == 1) {
      drawArrow(dc, cx, cy, deg, length, head);
    } else {
      // Double arrow: two side by side.
      var offset = head * 7 / 10 + 1;
      drawArrow(dc, cx - offset, cy, deg, length, head);
      drawArrow(dc, cx + offset, cy, deg, length, head);
    }
  }

  // One arrow of the given length, pointing at deg (0 = right, 90 = up), centred
  // on (cx, cy): a line for the shaft and a filled triangle for the head.
  private function drawArrow(dc as Gfx.Dc, cx as Number, cy as Number, deg as Number,
      length as Number, head as Number) as Void {
    var rad = Math.toRadians(deg);
    var dx = Math.cos(rad);
    var dy = -Math.sin(rad);
    var tipX = cx + dx * length / 2;
    var tipY = cy + dy * length / 2;
    var baseX = tipX - dx * head;
    var baseY = tipY - dy * head;
    dc.setPenWidth(Util.max(2, length / 8));
    dc.drawLine((cx - dx * length / 2).toNumber(), (cy - dy * length / 2).toNumber(),
        baseX.toNumber(), baseY.toNumber());
    dc.setPenWidth(1);
    var halfBase = head * 0.6;
    dc.fillPolygon([
      [tipX.toNumber(), tipY.toNumber()],
      [(baseX - dy * halfBase).toNumber(), (baseY + dx * halfBase).toNumber()],
      [(baseX + dy * halfBase).toNumber(), (baseY - dx * halfBase).toNumber()]
    ]);
  }

  // Draws a number so that its decimal point sits at x, so "9.6" and "12.4" keep
  // the point in the same place. Values without a point are centred on x.
  private function drawCenteredOnDecimalPoint(dc as Gfx.Dc, x as Number, y as Number,
      font, str as String, color as Number) as Void {
    var dot = str.find(".");
    if (dot == null) {
      drawTextAt(dc, x, y, font, str, color, Gfx.TEXT_JUSTIFY_CENTER);
      return;
    }
    var halfDot = dc.getTextWidthInPixels(".", font) / 2;
    var whole = str.substring(0, dot);
    var fraction = str.substring(dot + 1, str.length());
    drawTextAt(dc, x - halfDot, y, font, whole == null ? "" : whole, color, Gfx.TEXT_JUSTIFY_RIGHT);
    drawTextAt(dc, x, y, font, ".", color, Gfx.TEXT_JUSTIFY_CENTER);
    drawTextAt(dc, x + halfDot, y, font, fraction == null ? "" : fraction, color, Gfx.TEXT_JUSTIFY_LEFT);
  }

  // Red line at height y across a number drawn by drawCenteredOnDecimalPoint,
  // reaching 3 px past each end of the digits.
  private function drawStrikeThrough(dc as Gfx.Dc, x as Number, y as Number, font,
      str as String) as Void {
    var left = x;
    var right = x;
    var dot = str.find(".");
    if (dot == null) {
      var halfWidth = dc.getTextWidthInPixels(str, font) / 2;
      left = x - halfWidth;
      right = x + halfWidth;
    } else {
      var halfDot = dc.getTextWidthInPixels(".", font) / 2;
      var whole = str.substring(0, dot);
      var fraction = str.substring(dot + 1, str.length());
      left = x - halfDot - dc.getTextWidthInPixels(whole == null ? "" : whole, font);
      right = x + halfDot + dc.getTextWidthInPixels(fraction == null ? "" : fraction, font);
    }
    dc.setColor(Gfx.COLOR_RED, Gfx.COLOR_TRANSPARENT);
    dc.setPenWidth(3);
    dc.drawLine(left - 3, y, right + 3, y);
    dc.setPenWidth(1);
  }

  // Red triangle with a white exclamation mark, as in the Dexcom app.
  private function drawWarningTriangle(dc as Gfx.Dc, cx as Number, cy as Number,
      halfHeight as Number) as Void {
    var halfWidth = halfHeight * 115 / 100;
    dc.setColor(Gfx.COLOR_RED, Gfx.COLOR_TRANSPARENT);
    dc.fillPolygon([
      [cx - halfWidth, cy + halfHeight],
      [cx + halfWidth, cy + halfHeight],
      [cx, cy - halfHeight]
    ]);
    dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
    dc.drawText(cx, cy + halfHeight / 4, Gfx.FONT_SYSTEM_XTINY, "!",
        Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
  }

  // ---------------------------------------------------------------------------
  // IOB | COB | basal - coloured captions over white values.
  // ---------------------------------------------------------------------------
  private function drawLoopRow(dc as Gfx.Dc) as Void {
    var xtiny = Gfx.FONT_SYSTEM_XTINY;
    var left = centerX - loopSpacing;
    var right = centerX + loopSpacing;

    drawTextAt(dc, left, yLabel, xtiny, "IOB", IOB_COLOR, Gfx.TEXT_JUSTIFY_CENTER);
    drawTextAt(dc, centerX, yLabel, xtiny, "COB", COB_COLOR, Gfx.TEXT_JUSTIFY_CENTER);
    drawTextAt(dc, right, yLabel, xtiny, "BASAL", BASAL_COLOR, Gfx.TEXT_JUSTIFY_CENTER);

    drawTextAt(dc, left, yValue, smallFont, data.getRemainingInsulinStr(),
        Gfx.COLOR_WHITE, Gfx.TEXT_JUSTIFY_CENTER);
    var cob = data.getCarbsOnBoardStr();
    drawTextAt(dc, centerX, yValue, smallFont, "---".equals(cob) ? cob : cob + "g",
        Gfx.COLOR_WHITE, Gfx.TEXT_JUSTIFY_CENTER);
    // LOOP OFF only while the loop state is current; without an answer from AAPS
    // for 10 minutes the basal shows "---" instead.
    if (data.hasFreshLoopData() && !data.loopEnabled) {
      drawTextAt(dc, right, yValue, xtiny, "LOOP OFF", Gfx.COLOR_RED, Gfx.TEXT_JUSTIFY_CENTER);
    } else {
      drawTextAt(dc, right, yValue, smallFont, data.getBasalCorrectionStr(),
          Gfx.COLOR_WHITE, Gfx.TEXT_JUSTIFY_CENTER);
    }
  }

  // ---------------------------------------------------------------------------
  // Graph, or AAPS's error message in its place.
  // ---------------------------------------------------------------------------
  private function drawGraphOrMessage(dc as Gfx.Dc) as Void {
    if (data.errorMessage != null && data.errorMessage.length() > 0) {
      var xtiny = Gfx.FONT_SYSTEM_XTINY;
      drawTextAt(dc, centerX, yGraphTop + (graphHeight + visibleHeight(dc, xtiny)) / 2, xtiny,
          data.errorMessage, Gfx.COLOR_RED, Gfx.TEXT_JUSTIFY_CENTER);
      return;
    }
    if (graph != null && data.glucoseBuffer.size() > 0) {
      graph.draw(dc);
    }
  }

  // ---------------------------------------------------------------------------
  // Battery | heart rate | steps.
  // ---------------------------------------------------------------------------
  private function drawBottomRow(dc as Gfx.Dc) as Void {
    var xtiny = Gfx.FONT_SYSTEM_XTINY;
    var battery = System.getSystemStats().battery;
    drawTextAt(dc, centerX - bottomSpacing, yBottom, xtiny, battery.format("%0.0f") + "%",
        battery <= 20 ? Gfx.COLOR_ORANGE : GRAY, Gfx.TEXT_JUSTIFY_CENTER);

    // Heart + value centred as one group in the middle, unless turned off in the
    // settings (display only; sending it to AAPS is SendHeartRateToAaps).
    if (Properties.getValue("ShowHeartRate") != false) {
      var hr = getHeartRateStr();
      var groupWidth = 2 * iconSize + 3 + dc.getTextWidthInPixels(hr, xtiny);
      var left = centerX - groupWidth / 2;
      drawHeart(dc, left + iconSize, yBottom - visibleHeight(dc, xtiny) / 2);
      drawTextAt(dc, left + 2 * iconSize + 3, yBottom, xtiny, hr, Gfx.COLOR_WHITE,
          Gfx.TEXT_JUSTIFY_LEFT);
    }

    drawTextAt(dc, centerX + bottomSpacing, yBottom, xtiny, getStepsStr(dc), GRAY,
        Gfx.TEXT_JUSTIFY_CENTER);
  }

  // Red heart, centred on (cx, cy), iconSize from the centre.
  private function drawHeart(dc as Gfx.Dc, cx as Number, cy as Number) as Void {
    var r = Util.max(2, iconSize * 3 / 8);
    dc.setColor(Gfx.COLOR_RED, Gfx.COLOR_TRANSPARENT);
    dc.fillCircle(cx - r, cy - r * 2 / 3, r);
    dc.fillCircle(cx + r, cy - r * 2 / 3, r);
    dc.fillPolygon([[cx - 2 * r, cy - r / 3], [cx + 2 * r, cy - r / 3], [cx, cy + 2 * r]]);
  }

  private function getHeartRateStr() as String {
    if (!(Toybox has :SensorHistory) || !(Toybox.SensorHistory has :getHeartRateHistory)) {
      return "-";
    }
    try {
      var history = SensorHistory.getHeartRateHistory({
        :period => new TimeModule.Duration(HR_SAMPLING_PERIOD_SEC),
        :order => SensorHistory.ORDER_NEWEST_FIRST
      });
      var value = history == null ? null : history.next();
      return value == null || value.data == null ? "-" : value.data.toNumber().toString();
    } catch (e) {
      Log.e(TAG, "heart rate: " + e.getErrorMessage());
      return "-";
    }
  }

  // Today's steps in full, or as "12.3k" when the number is wider than the room
  // the layout has for it.
  private function getStepsStr(dc as Gfx.Dc) as String {
    try {
      var info = ActivityMonitor.getInfo();
      if (info == null || info.steps == null) {
        return "-";
      }
      var steps = info.steps as Number;
      var full = steps.toString();
      if (steps >= 10000 &&
          dc.getTextWidthInPixels(full, Gfx.FONT_SYSTEM_XTINY) > stepsMaxWidth) {
        return (steps / 1000.0).format("%0.1f") + "k";
      }
      return full;
    } catch (e) {
      Log.e(TAG, "steps: " + e.getErrorMessage());
      return "-";
    }
  }

  /**
   * Stores the average heart rate of the last 5 minutes in Storage, where the
   * background service (GlucoseServiceDelegate) picks it up and sends it to AAPS.
   */
}
