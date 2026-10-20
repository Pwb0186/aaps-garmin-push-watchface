# AAPS Push Watch Face (V2 Push-to-Pull)

> **Use it at your own risk.** This is not a medical device. Never make a medical decision
> based on a value you see on your watch - always check AAPS or your CGM.

A minimal Connect IQ watch face that shows AndroidAPS (AAPS) data and gets it with
**V2 Push-to-Pull**: AAPS sends a tiny "new data" signal to the watch, and the watch
fetches the data itself over HTTP. Use it as a starting point for your own watch face, or
copy a ready-built `.prg` from the `prg/` folder to your watch to try it.

**Send steps (and heart rate) to AAPS:** hold the watch face → *Customize* → turn on
*Send steps to AAPS* (and *Send heart rate to AAPS*). Both are off by default. AAPS only
stores the steps with the Steps or Push+Steps branch of the fork (below). Only one watch
should send steps to an AAPS.

It shows BG with delta and trend, age of the reading, temporary target, IOB, COB,
basal / temp basal (LOOP OFF when the loop is off), time/date, a 2-hour BG graph, and
battery, heart rate and steps. The layout is computed from the watch's own font sizes, so
the same code fits every watch in the manifest (round 208 to 466 px, and the square
Venu Sq and Venu X1).

> **Push and steps need an AAPS build from the fork
> [Pwb0186/AndroidAPS](https://github.com/Pwb0186/AndroidAPS).** Three branches on AAPS
> `4.0.0-beta1`:
>
> - [`GarminPush+Steps-V4.0.0-beta1`](https://github.com/Pwb0186/AndroidAPS/tree/GarminPush+Steps-V4.0.0-beta1):
>   push (V2), steps and the extra `/get` fields.
> - [`GarminSteps-V4.0.0-beta1`](https://github.com/Pwb0186/AndroidAPS/tree/GarminSteps-V4.0.0-beta1):
>   steps only, no push.
> - [`GarminPush-V4.0.0-beta1`](https://github.com/Pwb0186/AndroidAPS/tree/GarminPush-V4.0.0-beta1):
>   push (V2) and the extra `/get` fields, no steps.
>
> The same three exist on AAPS `dev`, with the same Garmin code:
> [`GarminPush+Steps-dev`](https://github.com/Pwb0186/AndroidAPS/tree/GarminPush+Steps-dev),
> [`GarminSteps-dev`](https://github.com/Pwb0186/AndroidAPS/tree/GarminSteps-dev) and
> [`GarminPush-dev`](https://github.com/Pwb0186/AndroidAPS/tree/GarminPush-dev).
>
> With stock AAPS the watch face still runs, but without push:
>
> | | Stock AAPS | Steps branch | Push branch | Push+Steps branch |
> |---|---|---|---|---|
> | BG, delta, trend, graph, IOB, basal | yes - fetched on the watch's own timer, planned for the next expected reading (about every 5 min, a few seconds after AAPS has it) | yes, same as stock | yes | yes |
> | Update after a bolus, carbs, temp target or temp basal | at the next timer fetch (up to 5 min) | same as stock | a few seconds (push) | a few seconds (push) |
> | COB | from `/sgv.json`, one extra request per fetch | same as stock | yes | yes |
> | Temporary target, loop status (LOOP OFF) | not sent, so no TT and no loop on/off info | same as stock | yes | yes |
> | Steps to AAPS | ignored | yes | ignored | yes |
> | Heart rate to AAPS | yes | yes | yes | yes |
>
> The fields an AAPS does not send are simply missing from the answer, and the watch face
> copes with that - nothing breaks.

`Shared/` is based on Robert Buessow's [AAPS Glucose Applications](https://github.com/buessow/garmin).

---

## Folder layout

```
PushWatchFace/   the watch face itself (app, view, manifest, resources)
Shared/          AAPS communication, data model, graph, scheduling - based on Buessow's
                 code and changed for V2; your own watch face uses it unchanged
prg/             ready-built release .prg for every watch in the manifest, to try it
```

`PushWatchFace/monkey.jungle` pulls in `../Shared/source` and `../Shared/resources`, so
keep the two folders next to each other. Your own watch face goes in a new folder
beside them and uses the same `monkey.jungle` lines.

---

## How it works

```
AAPS (phone)                                     Watch
    |  new BG, or the loop changed something         |
    |--- CIQ message {key, "updateWatch"} ---------->|  wakes the background process
    |                                                |  GlucoseServiceDelegate.onPhoneAppMessage()
    |                                                |  (routed by Garmin Connect on the phone)
    |<-- HTTP GET 127.0.0.1:28891/get?appId=... -----|  
    |                                                |
    |--- JSON: BG history, IOB, COB, TBR, TT ... --->|
    |                                                |  App.onBackgroundData() -> redraw
```

- **AAPS pushes** on a new BG reading, and on boluses, carbs, temp basal,
  temp target and running-mode changes (debounced 3.5 s, so one loop cycle gives one
  push). The push is sent at once. If AAPS has no COB value yet (for example just after
  AAPS starts, before its first calculation), it leaves `carbsOnBoard` out of the answer
  and the watch keeps the value it has.
- **AAPS only pushes to apps it has heard from.** Every `/get` carries the app's
  `appId`; AAPS keeps a registry of up to 10 app ids and pushes to those that fetched
  within the last 15 minutes. A new watch face is registered by its first fetch.
- **The watch has its own fallback fetch.** Garmin allows one background run per 5
  minutes. While push works, the fallback is planned 60 s after the next expected BG and
  is cancelled when a push delivers the data first - so normally it never runs. If the
  pushes stop, the fallback still runs at +60 s, about every 5 minutes. When no push has
  come for 15 minutes (about three readings), it moves to 5 s after the expected BG, i.e.
  plain polling every 5 minutes.
- **The background plans its next fetch itself.** The timer is a one-shot event, and the
  watch face plans it only while it is on the screen and the phone is connected. So every
  background run (timer and push) also plans the next one, about 6 minutes ahead. The
  watch face then keeps fetching during an activity (the activity has the screen) and
  keeps trying without the phone. While the watch face is on the screen and the phone is
  connected, its own time replaces that one. Garmin only runs the background of the
  selected watch face, so a watch face that is switched away does not fetch.

---

## Checklist for your own watch face

Copy `PushWatchFace` to a new folder and go through this list. Items 1-5 are required;
without them push will not work, or will go to the wrong watch face.

### 1. A new, unique App ID - in two places

Generate a new UUID and write it **without dashes** (32 hex characters). It must be
identical in:

- `manifest.xml`: `<iq:application id="...">`
- `PushWatchFaceApp.mc` (the app class), in `getInitialView()`: `Properties.setValue("AppId", "...")`

AAPS pushes to the `appId` the watch sends with `/get`, and Connect IQ delivers the push
to the app whose manifest id matches. If the two differ, the watch fetches fine but never
receives a push. Never reuse this watch face's id: AAPS pushes and Connect IQ delivers by id, so
two watch faces with the same id get in each other's way.
AAPS only accepts ids of exactly 32 hex characters.

Also give the app its own name in `resources/strings/strings.xml` (`AppName`).

### 2. Identify the app to AAPS (`getInitialView()`)

```monkeyc
Properties.setValue("Device", System.getDeviceSettings().partNumber + "_MYFACE");
Properties.setValue("AppVersion", "myface_v1");      // free text, shows in the AAPS log
Properties.setValue("AppId", "YOUR_APP_ID");         // the id from manifest.xml, 32 hex characters
server.init2();
```

`HttpClient` sends `device`, `version` and `appId` with every request.
`server.init2()` does two things: it schedules the first background fetch as soon as
Garmin allows (that fetch registers the app in AAPS), and it sets the **drain** flag
(item 4).

### 3. Register for push - delete first, then register

```monkeyc
try {
  Background.deletePhoneAppMessageEvent();
} catch (e) {
  // nothing registered - not an error
}
Background.registerForPhoneAppMessageEvent();
```

Do this in `getInitialView()`, i.e. on every foreground start (watch face selected,
watch restarted, after an activity). A plain `register` was seen to be a no-op when a
stale registration existed after the watch face had been inactive for a while: fetching
resumed, but push stayed dead until the app was reinstalled. Deleting first gives a fresh
registration.

### 4. Drain waiting phone messages (handled by `Shared`)

The watch keeps phone messages for an app until the app takes them. A watch face that is
not active never takes them, so pushes AAPS sent to it before it went out of the 15-minute
window pile up, and the watch can run out of message storage for it. After a foreground
start, the first background run (`GlucoseServiceDelegate.drainPhoneAppMessagesOnce()`)
takes and drops everything waiting, once.

You get this for free by calling `server.init2()` (item 2). The number of drained
messages is sent to AAPS as `drained=N` on that fetch. Don't try to drain from the
foreground - `Toybox.Communications` is not available to a watch face there and the
error can't be caught.

### 5. The app class: background annotation, service delegate, background data

```monkeyc
(:background)
class MyWatchFaceApp extends Application.AppBase {
  function initialize() {
    AppBase.initialize();
    server = new Shared.GmwServer();
  }

  function getServiceDelegate() as [ System.ServiceDelegate ] {
    return [ server.createServiceDelegate() ];
  }

  function onBackgroundData(result) as Void {
    if (data == null) { data = new Shared.Data(); }
    server.onBackgroundData(result, data);           // parse; marks push as working
    if (result instanceof Dictionary && "http".equals(result["channel"])) {
      BackgroundScheduler.backgroundComplete(data.glucoseBuffer.getLastDateSec());
    }
    if (view != null) { view.onDataUpdated(); }
  }
}
```

- The class must be `(:background)`, otherwise the background process can't start it.
- Call `server.onBackgroundData()` **before** `BackgroundScheduler.backgroundComplete()`:
  the first records that push delivered data (so the fallback moves out of the way), the
  second plans the next fallback.

### 6. Manifest permissions

```xml
<iq:uses-permission id="Background"/>      <!-- push and background fetch -->
<iq:uses-permission id="Communications"/>  <!-- HTTP to AAPS -->
<iq:uses-permission id="SensorHistory"/>   <!-- only if you send heart rate -->
```

### 7. `monkey.jungle`

```
project.manifest = manifest.xml
base.sourcePath = source;../Shared/source
base.resourcePath = resources;../Shared/resources
```

`Shared/resources` adds the `AAPSKey` setting and the properties `Shared` uses. Your own
`resources/settings/properties.xml` is merged with it.

### 8. Optional: heart rate and steps to AAPS

Both are **off by default** in PushWatchFace, and the user switches them on in the watch menu
(item 9). Some AAPS loops read them - OpenAPS AIMI, for example, can reduce SMB when the
steps are high - so a user must choose to send them.

- **Steps** (`steps=`, today's total, at most every 4 minutes) are sent when
  `SendStepsToAaps` is true. With `PauseStepsInActivity` they are held back while an
  activity is started, paused or not yet saved (`Activity.getActivityInfo().timerState`
  above 0, read in the background process - the watch face itself does not run during an
  activity). The activity's steps are then never sent.
- **Heart rate** is sent when `SendHeartRateToAaps` is true. The background process reads
  it just before each request from the watch's heart rate history (about one sample a
  minute) - `populateHeartRateHistory()` in `Shared/source/GlucoseServiceDelegate.mc`. It
  sends the average since the last value AAPS accepted (up to 10 minutes, else the last 5) as `hr`, with
  `hrStart` (the last `hrEnd`) and `hrEnd` (time of the newest sample), so the periods
  follow on without overlap. The background can read it while an activity runs, when the
  watch face itself does not run. `PauseHeartRateInActivity` (on by default) holds the
  heart rate back while an activity is started, paused or not yet saved - a data field in
  the activity usually sends it then. Turn it off in the watch menu to send it anyway.

AAPS only stores the steps with a fork branch that has steps (Steps or Push+Steps); stock AAPS and
the Push branch ignore them.
**Only one watch should send steps to an AAPS.** AAPS keeps one last total, so a second
watch with a higher total is counted as steps. When you switch watch, wait at least
12 minutes after the last steps were sent, or turn off "Send steps to AAPS" on one of them.

`Shared` reads both with `Util.settingOn(key, default)`, which gives the default when the
property does not exist, so a watch face without these properties keeps working. PushWatchFace
defines both as `false` in `properties.xml`.

#### How the steps code works

Everything is in `Shared/source/GlucoseServiceDelegate.mc` and runs in the background
process, just before each `/get` request (`populateSteps()`, called while the request
parameters are built):

1. **Switched on?** `Util.settingOn("SendStepsToAaps", true)` reads the property. A missing
   property gives the default, so a watch face without it keeps working. PushWatchFace sets
   it to `false` in `resources/settings/properties.xml`, and the watch menu
   (`PushWatchFaceSettings.mc`) switches it on.
2. **Activity running?** If `PauseStepsInActivity` is on, `isActivityRunning()` reads
   `Activity.getActivityInfo().timerState`. Above 0 (activity started, paused or not yet
   saved) no steps are sent. Every call is guarded with `has` checks and `try/catch`; on a
   device that refuses the call it returns `false`, and the steps are sent as usual.
3. **At most every 4 minutes:** the time of the last accepted send is kept in `Storage`
   (`LastSentStepsSec`). Within 240 s nothing is sent.
4. **Read and send:** `ActivityMonitor.getInfo().steps` (today's total, reset by the watch
   at midnight) is added as `steps=<total>`.
5. **Only after AAPS accepted it:** `LastSentStepsSec` is saved only when the answer is
   HTTP 200, so a failed request is tried again at the next fetch.
6. **Kept while AAPS can't be reached:** when a `/get` with steps gets no HTTP 200 (no
   phone, AAPS or its Garmin plugin off), the total and its time are kept in `Storage`
   (`StepSamples`, at most 36, at least 240 s apart - about 3 hours). The next `/get`
   with steps also sends them as `stepsPrev=<sec>:<total>,<sec>:<total>,...` (oldest
   first), and they are deleted when that request gets HTTP 200. They are also deleted
   when *Send steps to AAPS* is off. Only an AAPS from the fork's steps branches with this
   change uses `stepsPrev`, so the steps in the gap get their own time; an older AAPS
   ignores the field.

The watch sends only the day's total. AAPS (`GarminSteps` in the fork) turns the difference
from the last total into the 5/10/15/30/60/180-minute windows, handles midnight and a
counter that drops, and stores nothing over a gap of more than 12 minutes (only a new
starting point), unless `stepsPrev` fills the gap (item 6).

To send steps from your own watch face: use `Shared` as it is, add a boolean property
`SendStepsToAaps` (and optionally `PauseStepsInActivity`) to your `properties.xml`, and give
the user a way to change it (a watch menu or Connect IQ settings).

### 9. Optional: settings on the watch

Garmin Connect shows no settings page for a sideloaded `.prg`, so PushWatchFace has an
on-watch menu (hold the watch face > Customize) for the low and high BG marks used for
the BG colour and the graph lines, for showing or hiding the heart rate, and for sending
steps and heart rate to AAPS and for holding them back during an activity. See
`getSettingsView()` in the app class and
`PushWatchFaceSettings.mc`.

---

## AAPS settings

In AAPS: *Configuration -> Communication -> Garmin*, enable it, and in its settings
enable the **local HTTP server** (port 28891 by default - the watch uses that port).

**AAPS key** (optional, set in the same AAPS settings):

- **No key in AAPS:** everything works, also with a sideloaded `.prg`.
- **With a key:** enter the same key in the watch face's settings in the Garmin Connect
  app on the phone. That settings page only exists when the watch face is installed from
  the Connect IQ Store (a beta upload is enough). A sideloaded `.prg` has no settings
  page, so leave the key empty in AAPS. With a missing or wrong key AAPS answers 401, and
  the watch face is never registered for push.
- **Key changed in AAPS later:** with the Push+Steps branch the key does not have to be
  entered again on the watch. AAPS sends the new key with a push at once (and with every
  new BG), and the watch face saves it when a fetch with it is accepted. This only works
  if the watch face fetched data within the 15 minutes before the change. With the steps
  branch or stock AAPS there is no push, so the key must be entered again.

---

## The HTTP interface

Request - `GET http://127.0.0.1:28891/get?...`

| Parameter | Sent by | Meaning |
|---|---|---|
| `appId` | always | 32 hex chars; registers the app for push |
| `key` | always | AAPS key (empty if none set) |
| `device`, `version`, `manufacturer` | always | shows in the AAPS log |
| `trig` | always | `push` or `timer` - what started this fetch |
| `drained` | first fetch after foreground start | number of waiting messages dropped |
| `pusherr` | after an error | last `PhoneAppMessageError` code |
| `steps` | max every 4 min, only if enabled in the watch menu | today's total steps |
| `stepsPrev` | with `steps`, only after requests that failed | totals kept on the watch while AAPS could not be reached, `<sec>:<total>,...` oldest first (epoch sec); ignored by an AAPS without this change |
| `hr`, `hrStart`, `hrEnd` | max every 4 min, only if enabled in the watch menu | average heart rate since the last one sent (max 10 min) and its period (epoch sec) |

Response (JSON):

| Field | Meaning |
|---|---|
| `encodedGlucose` | last ~2 h of BG, delta-var encoded pairs (epoch sec, mg/dL) - `Shared.DeltaVarEncoder` |
| `remainingInsulin`, `remainingBasalInsulin` | bolus IOB and basal IOB (U); total IOB is the sum of the two |
| `carbsOnBoard` | COB (g). **Left out while AAPS recalculates** - keep the last value then. Sent by the push branches only: when the answer has no `loopEnabled` (stock AAPS, steps branch), `Shared` asks `/sgv.json?count=1&brief_mode=true` for `cob` in a second request (`onGetResult` in `GlucoseServiceDelegate.mc`) |
| `temporaryBasalRate` | running temp basal as a fraction of the profile basal (`1.0` = 100 %, `0.0` = zero temp). Left out when no temp basal runs |
| `temporaryTargetActive` | `true`/`false`; when true also `temporaryTargetLow`, `temporaryTargetHigh` (mg/dL), `temporaryTargetReason`, `temporaryTargetEndSec`, `temporaryTargetDurationMin` |
| `lowGlucoseMark`, `highGlucoseMark` | low and high mark from the AAPS Overview settings (mg/dL); left out when 0. PushWatchFace does not use them - it has its own marks (item 9) |
| `glucoseUnit` | `mmoll` or `mgdl` - display unit chosen in AAPS |
| `connected`, `loopEnabled` | pump connected, loop running |
| `timestamp` | server time (epoch sec); `Shared.GmwServer` drops responses older than the last one (a stored time more than 10 min ahead of the watch's clock is reset) |
| `profile` | active profile name |

---

## Build and install

**To try it without building:** `prg/` has a release build for every watch in the
manifest (`PushWatchFace-<device>.prg`). Copy the one for your watch to `GARMIN\APPS`
(see below) and pick "AAPS Push" as the watch face. To change anything, build it
yourself.

Requirements: Connect IQ SDK (built with 9.2.0; `minSdkVersion` 3.3.1) and a developer
key (SDK Manager / VS Code: "Generate a Developer Key").

```
monkeyc -o PushWatchFace/bin/PushWatchFace.prg -f PushWatchFace/monkey.jungle -y developer_key -d fr955 -w -r
```

`-r` makes a release build without the log output from `Shared/Log.mc`. Leave it out
when you want to read the log: create an empty `GARMIN\APPS\LOGS\PushWatchFace.TXT`
on the watch, and the log is written there.

Install by connecting the watch by USB and copying the `.prg` to `GARMIN\APPS`, then
pick the watch face on the watch. A sideloaded `.prg` can't use an AAPS key (see
AAPS settings).

The supported devices are listed in `manifest.xml`: most round Garmin watches with
Connect IQ 3.3.1 or newer, plus the square Venu Sq and Venu X1. The layout is built from
system fonts and screen size, not fixed pixel positions. It has been tested on a real
Forerunner 955; the other watches build, but have only been checked in the simulator,
or not at all.

---

## Troubleshooting

Filter the phone's logcat on the Garmin tag:

```
adb logcat -v time -s GARMIN:V
```

| You see | Meaning |
|---|---|
| `get from ... req: /get?...appId=<your id>...&trig=push` | push works |
| only `trig=timer`, every 5 min | the watch fetches but gets no push: check the App ID in both places (item 1), then switch to another watch face and back (item 3) |
| only `trig=timer` after a sideloaded `.prg` was replaced by the store version (same App ID) | switch to another watch face and back once; push starts after that foreground start. A fresh store install or a store update gets push right away (the face's name in the watch list only changes at the next switch - cosmetic) |
| `Ignoring malformed appId` | the App ID is not 32 hex characters |
| `Invalid AAPS Key` | key in the watch face differs from the one in AAPS |
| `no answer for ... after 20s, resending` | the watch did not fetch after a push; AAPS sends once more. Occasional is normal |
| no `/get` at all | local HTTP server off in AAPS, or Garmin Connect not running on the phone |
| watch shows `--` after the Garmin plugin or AAPS was off for more than 15 min | AAPS only pushes to watch faces that fetched in the last 15 min. The watch fetches again on its own within about 5 min, which re-registers it and restarts push; switch watch face and back to fetch at once |
