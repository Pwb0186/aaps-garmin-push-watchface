import Toybox.Lang;

module Shared {
class DateValue {
  var dateSec as Number;
  var value as Number;

  (:glance)
  function initialize(dateSec as Number, value as Number) {
    me.dateSec = dateSec;
    me.value = value;
  }

  function toString() as String {
    return Util.epochToString(dateSec) + "@" + value.format("%d");
  }
}
}
