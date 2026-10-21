function onEvent(event, api) {
    api.setStatus(event.session.active ? "Session active" : "Off");
}
