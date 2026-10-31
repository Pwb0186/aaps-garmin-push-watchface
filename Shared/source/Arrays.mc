import Toybox.Lang;

module Shared {
  (:glance)
  module Arrays {
    const TAG = "Arrays";

    function push(s as Array<Number>, scnt as Number, b as Number, e as Number) as Number {
      if (b < e) {
        // Grow array if needed
        if (s.size() == scnt) {
          s.addAll(new [scnt]);
        }
        s[scnt] = b + e << 16;
        return scnt + 1;
      } else {
        return scnt;
      }
    }

    function qsort(a as Array) as Void {
      // Stack of begin/end pairs encoded into one integer.
      var s = new [10] as Array<Number>;
      var scnt = 0;  // stack size, since it's hard to remove from the end of an array
      scnt = push(s, scnt, 0, a.size() - 1);
      while (scnt > 0) {
        var b = 0xffff & s[scnt - 1];
        var e = 0xffff & (s[scnt - 1] >> 16); 
        scnt -= 1;

        var i = partition(a, b, e);
        scnt = push(s, scnt, b, i - 1);
        scnt = push(s, scnt, i + 1, e);
      }
    }

    function partition(
        a as Array, 
        b as Number, 
        e as Number) as Number {
      var piv = a[e];
      var i = b - 1;
      // Swaps written out instead of a swap() call: this runs at the bottom of
      // a deep call chain (GmwServer -> Data.updateGlucose -> medianDeltaSec),
      // and one call level less keeps it clear of the watch's stack limit.
      var z;
      for (var j = b; j < e; j++) {
        if (a[j] < piv) {
          i = i + 1;
          z = a[i];
          a[i] = a[j];
          a[j] = z;
        }
      }
      i = i + 1;
      z = a[i];
      a[i] = a[e];
      a[e] = z;
      return i;
    }
  }
}

