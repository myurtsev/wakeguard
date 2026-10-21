function onEvent(event, api) {
    var active = event.session.active;
    api.setStatus(active ? "Session active" : "Off");

    if (event.type !== "stateChanged" || !event.previousSession ||
        event.previousSession.active === active) {
        return;
    }

    if (active && api.settings.notifyOnStart === "true") {
        api.notify("WakeGuard started", "Your keep-awake session is active.");
    } else if (!active && api.settings.notifyOnStop === "true") {
        api.notify("WakeGuard stopped", "Your keep-awake session has ended.");
    }
}
