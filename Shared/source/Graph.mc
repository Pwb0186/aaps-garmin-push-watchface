import Toybox.Lang;

using Shared.Log;
using Shared.Util;
using Toybox.Graphics as Gfx;
using Toybox.System as Sys;
using Toybox.WatchUi as Ui;

module Shared {
(:graph)
class Graph extends Ui.Drawable {
  private const TAG = "Graph";
  private const TIME_RANGE_SEC = 120 * 60;
  private const MIN_GLUCOSE = 40;

  private var glucoseBarWidthSec as Number = 5 * 60;
  private var glucoseBarPadding as Number = 2;
  private var initialXOffset as Number;
  private var initialWidth as Number;
  private var glucoseBarWidth as Number = 3;
  private var firstValueIdx as Number = 0;
  private var xOffset as Number = 3;
  private var yOffset as Number = 120;
  var height as Number = 86;
  private var glucoseBuffer as Shared.DateValues = new Shared.DateValues(null, 2);
  private var maxGlucose as Number = 0;
  private var circular as Boolean;

  function initialize(params as  {
        :x as Number, :identifier as Object,
        :locX as Numeric, :locY as Numeric,
        :width as Numeric, :height as Numeric,
        :roundEdgeOffset as Boolean,
        :visible as Boolean }) {
    Drawable.initialize(params);
    // On a round screen the graph normally ends early on the right so the newest
    // value clears the curved edge (getBorderOffset). A graph that sits well inside
    // the circle can pass :roundEdgeOffset => false to keep its full, centred width.
    me.circular = Sys.getDeviceSettings().screenShape == Sys.SCREEN_SHAPE_ROUND
        && params.get(:roundEdgeOffset) != false;
    me.initialXOffset = params.get(:x) as Number;
    me.yOffset = (params.get(:y) as Number) + 8;
    me.initialWidth = params.get(:width) as Number;
    me.width = initialWidth;
    me.height = (params.get(:height) as Number) - 8;
  }

  function valueCount() as Number {
    return TIME_RANGE_SEC / glucoseBarWidthSec;
  }

  private function computeFirstIndex(startSec as Number) as Void {
    firstValueIdx = 0;
    for (var i = 0; i < glucoseBuffer.size(); i++) {
      if (glucoseBuffer.getDateSec(i) < startSec) {
        firstValueIdx++;
      } else {
        return;
      }
    }
  }

  private function computeMaxGlucose() as Void {
    // At least the watch face's high mark, so its line (drawTargetLines) is always
    // inside the graph. With a fixed 180 a high mark above 180 and no value above it
    // put the line above the graph, over the labels there.
    maxGlucose = Util.max(180, Data.getHighBgMarkMgdl()) as Number;
    for (var i = firstValueIdx; i < glucoseBuffer.size(); i++) {
      maxGlucose = Util.max(maxGlucose, glucoseBuffer.getValue(i)) as Number;
    }
  }

  private function computeOffsetAndWidth() as Void {
    var rightOffset = 0;
    if (firstValueIdx < glucoseBuffer.size()) {
      rightOffset = getBorderOffset(glucoseBuffer.getLastValue());
    }

    var w = initialWidth - rightOffset;
    var valueWidth = Math.ceil((w + glucoseBarPadding) / valueCount().toDouble()).toNumber();
    glucoseBarWidth = valueWidth - glucoseBarPadding;
    if (glucoseBarWidth <= glucoseBarPadding) {
      glucoseBarWidth += glucoseBarPadding;
      glucoseBarPadding = 0;
      glucoseBarWidth = Util.max(1, glucoseBarWidth);
    }
    var width = valueWidth * valueCount() - glucoseBarPadding;
    me.width = width;
    xOffset = initialXOffset + w - width - 1;

    Log.i(
        TAG,
        "graph: " + {
            "initialWidth" => initialWidth,
            "rightOffset" => rightOffset,
            "xOffset" => xOffset,
            "width" => width,
            "glucoseBarWidth" => glucoseBarWidth,
            "glucoseBarPadding" => glucoseBarPadding,
            "valueCount" => valueCount(),
            "height" => height});
  }

  function setReadings(glucoseBuffer as Shared.DateValues) as Void {
    glucoseBarWidthSec = Data.getGlucoseValueFrequencySeq();
    glucoseBarPadding = glucoseBarWidthSec < 300 ? 0 : 2;
    me.glucoseBuffer = glucoseBuffer;

    var startSec = glucoseBuffer.size() > 0 ? glucoseBuffer.getLastDateSec() : Util.nowSec();
    startSec += glucoseBarWidthSec * ((Util.nowSec() - startSec) / glucoseBarWidthSec);
    startSec -= TIME_RANGE_SEC;
    computeFirstIndex(startSec);
    computeMaxGlucose();
    computeOffsetAndWidth();
  }

  private function getBorderOffset(value as Number) as Number {
    if (!circular) { return 0; }
    var y = Util.min(height, getYForGlucose(value));
    var r = initialWidth / 2;
    var o = r - Math.sqrt(r*r - y*y);  // Pythagoras' theorem
    Log.i(TAG, "gbo " + {"y" => y, "r" => r, "o" => o});
    return Math.ceil(o).toNumber() + glucoseBarWidth / 2;
  }

  private function getX(startSec as Number, dateSec as Number) as Number {
    var rel = (dateSec - startSec) / glucoseBarWidthSec * (glucoseBarPadding + glucoseBarWidth);
    return rel;
  }

  private function getYForGlucose(glucose as Number) as Number {
    return height * (maxGlucose - glucose) / (maxGlucose - MIN_GLUCOSE);
  }

  private function drawGlucoseDot(
      dc as Gfx.Dc, color as Number,
      x as Number, y as Number) as Void {
    dc.setColor(color, Gfx.COLOR_TRANSPARENT);
    dc.fillCircle(xOffset + x + glucoseBarWidth / 2, yOffset + y, 3);
  }

  private function getGlucoseDotColor(glucose as Number) as Number {
    if (glucose < Data.getLowBgMarkMgdl()) {
      return Gfx.COLOR_RED;
    } else if (glucose > Data.getHighBgMarkMgdl()) {
      return Gfx.COLOR_YELLOW;
    }
    return Gfx.COLOR_GREEN;
  }

  private function drawGlucose(dc as Gfx.Dc, startSec as Number) as Void {
    if (glucoseBuffer == null) {
      return;
    }
    // Draw all glucose dots, after drawTargetLines() so the dots are on top.
    for (var i = firstValueIdx; i < glucoseBuffer.size(); i++) {
      // firstValueIdx is from the last setReadings(), but startSec is "now - 2 h" at
      // every redraw. Without new data (phone out of reach) the oldest dots got a
      // negative x and were drawn left of the graph's frame.
      if (glucoseBuffer.getDateSec(i) < startSec) { continue; }
      var gl = glucoseBuffer.getValue(i);
      var x = getX(startSec, glucoseBuffer.getDateSec(i));
      var y = getYForGlucose(gl);
      drawGlucoseDot(dc, getGlucoseDotColor(gl), x, y);
    }
  }

  // Low/high lines at the watch face's own BG limits.
  private function drawTargetLines(dc as Gfx.Dc) as Void {
    var yLow = getYForGlucose(Data.getLowBgMarkMgdl());
    var yHigh = getYForGlucose(Data.getHighBgMarkMgdl());
    dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
    dc.setPenWidth(1);
    // Only lines that fall inside the graph (e.g. a low mark under 40 mg/dL would not).
    if (yLow >= 0 && yLow <= height) {
      dc.drawLine(xOffset, yOffset + yLow, xOffset + width, yOffset + yLow);
    }
    if (yHigh >= 0 && yHigh <= height) {
      dc.drawLine(xOffset, yOffset + yHigh, xOffset + width, yOffset + yHigh);
    }
  }

  private function drawBorder(dc as Gfx.Dc) as Void {
    dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
    dc.setPenWidth(1);
    dc.drawRectangle(xOffset, yOffset, width, height);
  }

  function draw(dc as Gfx.Dc) as Void {
    if (!isVisible) { return; }
    glucoseBarWidthSec = Data.getGlucoseValueFrequencySeq();
    glucoseBarPadding = glucoseBarWidthSec < 300 ? 0 : 2;
    if (glucoseBuffer.size() == 0) {
      return;
    }
    var nowSec = Util.nowSec();
    var startSec = nowSec - TIME_RANGE_SEC;

    drawBorder(dc);
    drawTargetLines(dc);
    drawGlucose(dc, startSec);
  }
}}
