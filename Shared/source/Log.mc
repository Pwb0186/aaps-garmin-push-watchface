import Toybox.Lang;

using Toybox.System as Sys;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;

// Logging to System.println - which only reaches a file when
// GARMIN\APPS\LOGS\<APP>.TXT exists on the watch.
//
// Debug builds (monkeyc without -r) log with a timestamp. Release builds (monkeyc -r)
// get the empty versions: no date formatting and no println on every call,
// which the watch otherwise does all day even when nobody reads the log.
// (The message string itself is still built by the caller.)
module Shared {
module Log {
  (:background, :glance, :debug)
  function log(severity as String, tag as String, message as String) as Void {
    var timeInfo = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
    Sys.println(Lang.format(
        "$1$ $2$-$3$-$4$T$5$:$6$:$7$ $8$ - $9$",
        [ severity,
          timeInfo.year.format("%02d"),
          (timeInfo.month as Number).format("%02d"),
          timeInfo.day.format("%02d"),
          timeInfo.hour.format("%02d"),
          timeInfo.min.format("%02d"),
          timeInfo.sec.format("%02d"),
          tag, message ]));
  }

  (:background, :glance, :release)
  function log(severity as String, tag as String, message as String) as Void {
  }

  (:background, :glance)
  public function i(tag as String, message as String) as Void {
    log("I", tag, message);
  }

  (:background, :glance)
  public function e(tag as String, message as String) as Void {
    log("E", tag, message);
  }
}}
