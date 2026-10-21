function onEvent(event, api) {
    var agents = event.agents;
    var parts = [];
    if (agents.working > 0) parts.push(agents.working + " working");
    if (agents.waiting > 0) parts.push(agents.waiting + " waiting");
    if (agents.unknown > 0) parts.push(agents.unknown + " unavailable");
    api.setStatus(parts.length > 0 ? parts.join(" · ") : "No active agents");

    if (event.type === "command" && event.command === "detectionHelp") {
        api.openURL("https://github.com/myurtsev/wakeguard#agent-detection");
    }
}
