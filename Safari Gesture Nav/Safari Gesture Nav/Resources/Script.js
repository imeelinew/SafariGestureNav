function show(enabled, useSettingsInsteadOfPreferences) {
    if (useSettingsInsteadOfPreferences) {
        document.getElementsByClassName("state-on")[0].innerText = "扩展已启用。请授予辅助功能与输入监控权限，并让本程序保持运行。";
        document.getElementsByClassName("state-off")[0].innerText = "扩展尚未启用，请前往 Safari 扩展设置开启。";
        document.getElementsByClassName("state-unknown")[0].innerText = "请在 Safari 的“设置 → 扩展”中启用 Safari Gesture Nav。";
        document.getElementsByClassName("open-preferences")[0].innerText = "打开 Safari 扩展设置…";
    }

    if (typeof enabled === "boolean") {
        document.body.classList.toggle("state-on", enabled);
        document.body.classList.toggle("state-off", !enabled);
    } else {
        document.body.classList.remove("state-on");
        document.body.classList.remove("state-off");
    }
}

function openPreferences() {
    webkit.messageHandlers.controller.postMessage("open-preferences");
}

document.querySelector("button.open-preferences").addEventListener("click", openPreferences);
