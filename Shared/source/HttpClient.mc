import Toybox.Lang;

using Toybox.Application.Properties;
using Toybox.Communications as Comm;
using Toybox.System;

module Shared {

(:background, :glance)
class HttpClient {
  private static const TAG = "HttpClient";
  private var url as String;
  private var methodName as String?;
  private var callback as (Method(result as Dictionary<String, Object>) as Void)?;
  var makeWebRequest = new Method(Comm, :makeWebRequest);
  private var httpCode404 as String;
  private var noServerConnection as String;

  private function getErrorMessage(code as Number) as String {
    switch (code) {
      // Communications.UNKNOWN_ERROR. Garmin reports it when the request failed without a more
      // specific reason, which in practice means the phone never reached the server - so it needs
      // a message the user can act on rather than the "error 0" the default branch produced.
      case 0: return noServerConnection;
      case -1: return "BLE error";
      case -2: return "BLE timeout/h";
      case -3: return "BLE timeout/s";
      case -4: return "BLE no data";
      case -5: return "BLE cancel";
      case -101: return "BLE queue full";
      case -102: return "BLE too large";
      case -103: return "BLE send error";
      case -104: return "BLE no conn";
      case -200: return "inv req header";
      case -201: return "inv req body";
      case -202: return "inv req method";
      // NETWORK_REQUEST_TIMED_OUT - also "we never got through", so it shares the message.
      case -300: return noServerConnection;
      case -400: return "inv resp body";
      case -401: return "inv resp header";
      case -402: return "resp too large";
      case -403: return "resp oom";
      case -1000: return "storage full";
      case -1001: return "sec conn req";
      case -1002: return "bad content type";
      case -1003: return "req cancelled";
      case -1004: return "conn dropped";
      case 404: return httpCode404;
      default:
        if (code > 0) {
          return "HTTP" + code;
        } else {
          return "error " + code;
        }
    }
  }

  // Initializes a new instance.
  //
  // @Param url (String)
  //        Base URL of the request.
  // @Param httpCode404 (String)
  //        Shown on HTTP 404 - the server answered but the path was not there.
  // @Param noServerConnection (String)
  //        Shown when the request never reached the server (UNKNOWN_ERROR, timeout). Per-app,
  //        because what the user should do about it depends on which server that is.
  function initialize(url as String, httpCode404 as String, noServerConnection as String) {
    me.url = url;
    me.httpCode404 = httpCode404;
    me.noServerConnection = noServerConnection;
  }

  private function putIfNotNull(d as Dictionary<String, String>, k as String, v as String?) as Void {
    if (v == null) {
      d.remove(k);
    } else {
      d.put(k, v);
    }
  }

  public function get(
      methodName as String,
      callback as Method(result as Dictionary<String, Object>) as Void,
      parameters as Dictionary<String, String>) as Void {
    me.methodName = methodName;
    me.callback = callback;
    var url = me.url + methodName;
    putIfNotNull(parameters, "device", Properties.getValue("Device"));
    var appId = Properties.getValue("AppId");
    if (appId != null && !appId.equals("")) {
      parameters["appId"] = appId;
    }
    parameters["manufacturer"] = "garmin";
    parameters["version"] = Properties.getValue("AppVersion");
    logRequest(methodName, url, parameters);
    try {
      makeWebRequest.invoke(
          url,
          parameters,
          { :method => Comm.HTTP_REQUEST_METHOD_GET },
          method(:onResult));
    } catch (e) {
      e.printStackTrace();
      if (callback != null) {
        callback.invoke({"errorMessage" => e == null ? "webRequest error" : e.getErrorMessage(), "channel" => "http"});
      }
    }
  }

  // Debug builds only: builds a string of the whole request and reads memory stats
  // on every fetch. A release build (monkeyc -r) uses the empty version below.
  (:debug)
  private function logRequest(methodName as String, url as String, parameters as Dictionary) as Void {
    var stats = System.getSystemStats();
    Log.i(TAG,
        methodName + " url: " + url + " params: " + parameters
        + " mem avail: " + stats.freeMemory + " mem total: " + stats.totalMemory);
  }

  (:release)
  private function logRequest(methodName as String, url as String, parameters as Dictionary) as Void {
  }

  function onResult(code as Number, obj) as Void {
    code = code == null ? 0 : code;
    try {
      onResultImpl(code, obj, methodName, callback);
    } catch (e) {
      Log.e(TAG, "ex: " + (e == null ? "NULL" : e.getErrorMessage()));
      if (e != null) {
        e.printStackTrace();
      }
      // Hand an error on, so the background process still reaches Background.exit()
      // instead of being stopped by the system after its time limit. No httpCode, so
      // the callback does not treat it as a successful answer.
      if (callback != null) {
        try {
          callback.invoke({
              "errorMessage" => e == null ? "result error" : e.getErrorMessage(),
              "channel" => "http"});
        } catch (e2) {
          Log.e(TAG, "callback ex: " + (e2 == null ? "NULL" : e2.getErrorMessage()));
        }
      }
    }
  }

  private function onResultImpl(
      code as Number,
      obj,
      method as String,
      callback as Method(result as Dictionary<String, Object>) as Void) {
    var result = obj instanceof Dictionary ? obj : { "message" => obj };
    result["httpCode"] = code;
    result["channel"] = "http";
    if (code != 200) {
      Log.i(TAG, "set error " + getErrorMessage(code));
      result["errorMessage"] = getErrorMessage(code);
    }

    if (callback != null) {
      callback.invoke(result);
    }
  }
}}
