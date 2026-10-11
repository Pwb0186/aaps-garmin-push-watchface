import Toybox.Lang;

using Shared;
using Toybox.Application;
using Toybox.Application.Properties;
using Toybox.WatchUi as Ui;

// On-watch settings (hold the watch face > Customize): the low and high BG marks
// used for the colour of the BG value and the lines in the graph, whether the
// heart rate is shown, and whether steps and heart rate are sent to AAPS (both off
// by default: AAPS loops such as OpenAPS AIMI read them and can reduce SMB), and
// whether steps are held back while an activity runs. On the watch, because Garmin Connect on the phone
// shows no settings for a sideloaded app.
class PushWatchFaceSettings {
  private var menu as Ui.Menu2 = new Ui.Menu2({});
  private var input = new Input();

  // Shown in both units, e.g. "4.0/72".
  private function getBgMarkName(value as Number) as String {
    return (value / 18.0).format("%0.1f") + "/" + value.toString();
  }

  function initialize() {
    menu.setTitle(Rez.Strings.SettingsTitle);
    menu.addItem(new Ui.MenuItem(
        Rez.Strings.LowBgMarkTitle,
        getBgMarkName(Shared.Data.getLowBgMarkMgdl()),
        :menuLowBgMark,
        {}));
    menu.addItem(new Ui.MenuItem(
        Rez.Strings.HighBgMarkTitle,
        getBgMarkName(Shared.Data.getHighBgMarkMgdl()),
        :menuHighBgMark,
        {}));
    menu.addItem(new Ui.ToggleMenuItem(
        Rez.Strings.ShowHeartRateTitle,
        Rez.Strings.VisibleLabel,
        :menuShowHeartRate,
        Properties.getValue("ShowHeartRate") != false,
        {}));
    menu.addItem(new Ui.ToggleMenuItem(
        Rez.Strings.SendStepsTitle,
        Rez.Strings.SendLabel,
        :menuSendSteps,
        Shared.Util.settingOn("SendStepsToAaps", false),
        {}));
    menu.addItem(new Ui.ToggleMenuItem(
        Rez.Strings.PauseStepsTitle,
        Rez.Strings.PauseLabel,
        :menuPauseSteps,
        Shared.Util.settingOn("PauseStepsInActivity", false),
        {}));
    menu.addItem(new Ui.ToggleMenuItem(
        Rez.Strings.SendHeartRateTitle,
        Rez.Strings.SendLabel,
        :menuSendHeartRate,
        Shared.Util.settingOn("SendHeartRateToAaps", false),
        {}));
    menu.addItem(new Ui.ToggleMenuItem(
        Rez.Strings.PauseHrTitle,
        Rez.Strings.PauseLabel,
        :menuPauseHeartRate,
        Shared.Util.settingOn("PauseHeartRateInActivity", true),
        {}));
  }

  function get() as [ Ui.Views, Ui.InputDelegates ] {
    return [menu, input];
  }

  class Input extends Ui.Menu2InputDelegate {
    function initialize() {
      Ui.Menu2InputDelegate.initialize();
    }

    // Each press moves to the next mark (mg/dL; 3.5, 4.0, 4.1, 4.5, 5.0 mmol/L).
    private function nextLowBgMark() as Number {
      var current = Shared.Data.getLowBgMarkMgdl();
      if (current < 68) { return 72; }
      if (current < 73) { return 74; }
      if (current < 78) { return 81; }
      if (current < 86) { return 90; }
      return 63;
    }

    // 9.0, 10.0, 10.5, 11.0, 12.0 mmol/L.
    private function nextHighBgMark() as Number {
      var current = Shared.Data.getHighBgMarkMgdl();
      if (current < 171) { return 180; }
      if (current < 185) { return 189; }
      if (current < 194) { return 198; }
      if (current < 207) { return 216; }
      return 162;
    }

    // The menu is closed after a change, so the new value shows when it is opened again.
    function onSelect(item as Ui.MenuItem) as Void {
      switch (item.getId()) {
        case :menuLowBgMark:
          Properties.setValue("LowBgMarkMgdl", nextLowBgMark());
          Application.getApp().onSettingsChanged();
          Ui.popView(Ui.SLIDE_IMMEDIATE);
          return;
        case :menuHighBgMark:
          Properties.setValue("HighBgMarkMgdl", nextHighBgMark());
          Application.getApp().onSettingsChanged();
          Ui.popView(Ui.SLIDE_IMMEDIATE);
          return;
        case :menuShowHeartRate:
          Properties.setValue("ShowHeartRate", (item as Ui.ToggleMenuItem).isEnabled());
          Application.getApp().onSettingsChanged();
          return;
        case :menuSendSteps:
          Properties.setValue("SendStepsToAaps", (item as Ui.ToggleMenuItem).isEnabled());
          Application.getApp().onSettingsChanged();
          return;
        case :menuPauseSteps:
          Properties.setValue("PauseStepsInActivity", (item as Ui.ToggleMenuItem).isEnabled());
          Application.getApp().onSettingsChanged();
          return;
        case :menuSendHeartRate:
          Properties.setValue("SendHeartRateToAaps", (item as Ui.ToggleMenuItem).isEnabled());
          Application.getApp().onSettingsChanged();
          return;
        case :menuPauseHeartRate:
          Properties.setValue("PauseHeartRateInActivity", (item as Ui.ToggleMenuItem).isEnabled());
          Application.getApp().onSettingsChanged();
          return;
      }
    }

    function onBack() as Void {
      Ui.popView(Ui.SLIDE_IMMEDIATE);
    }
  }
}
