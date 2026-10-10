import Toybox.Lang;

using Toybox.Application.Properties;
using Toybox.Time;

module Shared {
(:background, :glance)
module Util {
  function nowSec() as Number {
    return Time.now().value();
  }

  // True/false from a boolean property. A missing property (the key is not in the
  // app's properties.xml - getValue throws then) gives dflt, so watch faces without
  // the setting keep their old behaviour.
  function settingOn(key as String, dflt as Boolean) as Boolean {
    try {
      var v = Properties.getValue(key);
      if (v instanceof Boolean) {
        return v;
      }
    } catch (e) {
    }
    return dflt;
  }

  function max(a as Number, b as Number) as Number {
    return a < b ? b : a;
  }

  function min(a as Number, b as Number) as Number {
    return a < b ? a : b;
  }

  function abs(a as Number) as Number {
    return a < 0 ? -a : a;
  }

  function epochToString(sec as Number) as String {
    return momentToString(new Toybox.Time.Moment(sec));
  }

  function ifNull(a as Object?, b as Object) as Object {
    return a == null ? b : a;
  }

  function ifNullFloat(a as Float?, b as Float) as Float {
    return a == null ? b : a;
  }

  function timeSecToString(sec as Number?) as String {
    return sec == null ? "NULL" : momentToString(new Time.Moment(sec));
  }

  function momentToString(m as Time.Moment?) as String {
    if (m == null) {
      return "NULL";
    }
    var info = Time.Gregorian.info(m, Time.FORMAT_SHORT);
    return info.year.format("%04d") + "-" + (info.month as Number).format("%02d") + "-" +
           info.day.format("%02d") + "T" +
           info.hour.format("%02d") + ":" + info.min.format("%02d") + ":" +
           info.sec.format("%02d");
  }
}
}
