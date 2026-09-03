importPackage(Packages.com.ti.debug.engine.scripting);
importPackage(Packages.com.ti.ccstudio.scripting.environment);
importPackage(Packages.java.lang);

function parseArguments(args) {
    var options = {};
    for (var i = 0; i < args.length; i++) {
        var value = String(args[i]);
        if (value.indexOf("--") !== 0) continue;
        var separator = value.indexOf("=");
        if (separator < 0) options[value.substring(2)] = "true";
        else options[value.substring(2, separator)] = value.substring(separator + 1);
    }
    return options;
}

function requireOption(options, name) {
    if (!options[name] || options[name].length === 0) throw new Error("Missing required option --" + name);
    return options[name];
}

function writeText(path, value) {
    var writer = new java.io.FileWriter(path, false);
    try { writer.write(value); }
    finally { writer.close(); }
}

function appendEvent(path, value) {
    if (!path) return;
    var writer = new java.io.FileWriter(path, true);
    try { writer.write(new java.util.Date() + "\t" + value + java.lang.System.getProperty("line.separator")); }
    finally { writer.close(); }
}

function readCommandFile(file) {
    var reader = new java.io.BufferedReader(new java.io.FileReader(file));
    try { return String(reader.readLine() || "").replace(/^\s+|\s+$/g, ""); }
    finally { reader.close(); }
}

function readCommands(commandDirectory, legacyCommandPath) {
    var commandFiles = [];
    var result = [];
    var i;

    if (commandDirectory) {
        var directory = new java.io.File(commandDirectory);
        var files = directory.listFiles();
        if (files !== null) {
            for (i = 0; i < files.length; i++) {
                if (files[i].isFile() && /\.cmd$/i.test(String(files[i].getName()))) commandFiles.push(files[i]);
            }
            commandFiles.sort(function(left, right) {
                var leftName = String(left.getName());
                var rightName = String(right.getName());
                return leftName < rightName ? -1 : (leftName > rightName ? 1 : 0);
            });
        }
    }

    for (i = 0; i < commandFiles.length; i++) {
        try { result.push(readCommandFile(commandFiles[i])); }
        finally { commandFiles[i]["delete"](); }
    }

    if (legacyCommandPath) {
        var legacyFile = new java.io.File(legacyCommandPath);
        if (legacyFile.exists()) {
            try { result.push(readCommandFile(legacyFile)); }
            finally { legacyFile["delete"](); }
        }
    }
    return result;
}

function cleanError(error) {
    return String(error).replace(/[\r\n;]+/g, " ");
}

function safeEvaluate(session, expression) {
    try { return String(session.expression.evaluate(expression)); }
    catch (error) { return "ERROR(" + cleanError(error) + ")"; }
}

function snapshot(session, expressions) {
    var values = [];
    for (var i = 0; i < expressions.length; i++) {
        if (expressions[i].length > 0) values.push(expressions[i] + "=" + safeEvaluate(session, expressions[i]));
    }
    return values.join(";");
}

function addBreakpoint(session, specification) {
    if (specification.indexOf("@") === 0) {
        var addressText = specification.substring(1).replace(/^\s+|\s+$/g, "");
        var address = parseInt(addressText, 0);
        if (isNaN(address)) throw new Error("Invalid breakpoint address: " + specification);
        return session.breakpoint.add(address);
    }

    var separator = specification.lastIndexOf(":");
    if (separator <= 0) throw new Error("Invalid breakpoint specification: " + specification);
    var sourceFile = specification.substring(0, separator);
    var sourceLine = parseInt(specification.substring(separator + 1), 10);
    if (isNaN(sourceLine)) throw new Error("Invalid breakpoint line: " + specification);
    return session.breakpoint.add(sourceFile, sourceLine);
}

function clearBreakpoints(session, activeBreakpoints, eventsPath) {
    var ids = [];
    for (var id in activeBreakpoints) {
        if (activeBreakpoints.hasOwnProperty(id)) ids.push(id);
    }

    try {
        session.breakpoint.removeAll();
    }
    catch (removeAllError) {
        appendEvent(eventsPath, "BREAKPOINT_CLEAR_ERROR " + cleanError(removeAllError));
        for (var index = 0; index < ids.length; index++) {
            try { session.breakpoint.remove(parseInt(ids[index], 10)); }
            catch (removeError) { appendEvent(eventsPath, "BREAKPOINT_REMOVE_ERROR id=" + ids[index] + " " + cleanError(removeError)); }
        }
    }

    for (var removedIndex = 0; removedIndex < ids.length; removedIndex++) {
        appendEvent(eventsPath, "BREAKPOINT_REMOVED id=" + ids[removedIndex]);
    }
    appendEvent(eventsPath, "BREAKPOINTS_CLEARED count=" + ids.length);
    return {};
}

var options = parseArguments(arguments);
var configPath = requireOption(options, "config");
var programPath = requireOption(options, "program");
var statusPath = requireOption(options, "status");
var logPath = requireOption(options, "log");
var stylesheetPath = requireOption(options, "stylesheet");
var commandPath = String(options.command || "");
var commandDirectory = String(options.commanddir || "");
var eventsPath = String(options.events || "");
var breakpointText = String(options.breakpoints || "");
var breakpoints = breakpointText ? breakpointText.split(";") : [];
var watchExpressions = String(options.watch || "errPLC;ipstep").split(";");
var loadProgram = String(options.loadprogram || "true").toLowerCase() !== "false";
var restartTarget = String(options.restart || "true").toLowerCase() !== "false";
var environment = null;
var server = null;
var session = null;
var traceStarted = false;
var keepRunning = true;
var previousState = "";
var activeBreakpoints = {};
var manualHaltRequested = false;

try {
    writeText(statusPath, "STARTING");
    appendEvent(eventsPath, "STARTING");
    environment = ScriptingEnvironment.instance();
    environment.traceBegin(logPath, stylesheetPath);
    traceStarted = true;
    environment.traceSetConsoleLevel(TraceLevel.ALL);
    environment.traceSetFileLevel(TraceLevel.ALL);
    environment.setScriptTimeout(30000);
    server = environment.getServer("DebugServer.1");
    server.setConfig(configPath);
    session = server.openSession(".*");

    var connected = false;
    var connectError = null;
    for (var connectAttempt = 1; connectAttempt <= 5 && !connected; connectAttempt++) {
        try {
            session.target.connect();
            connected = session.target.isConnected();
        }
        catch (attemptError) {
            connectError = attemptError;
            appendEvent(eventsPath, "CONNECT_RETRY attempt=" + connectAttempt + " " + cleanError(attemptError));
            if (connectAttempt < 5) Thread.sleep(500);
        }
    }
    if (!connected) throw connectError || new Error("Unable to connect to target.");

    session.options.setBoolean("AllowInterruptsWhenHalted", true);
    session.options.setBoolean("PoliteRealtimeMode", true);

    if (loadProgram) {
        session.memory.loadProgram(programPath);
    }
    else {
        session.symbol.load(programPath);
        appendEvent(eventsPath, "LOADSYMBOL OK " + programPath);
    }

    for (var i = 0; i < breakpoints.length; i++) {
        if (!breakpoints[i]) continue;
        try {
            var initialId = addBreakpoint(session, breakpoints[i]);
            activeBreakpoints[String(initialId)] = breakpoints[i];
            appendEvent(eventsPath, "BREAKPOINT_ADDED id=" + initialId + " " + breakpoints[i]);
        }
        catch (initialBreakpointError) {
            appendEvent(eventsPath, "BREAKPOINT_ERROR spec=" + breakpoints[i] + " message=" + initialBreakpointError);
        }
    }

    if (restartTarget) {
        session.target.restart();
        session.target.runAsynch();
        Thread.sleep(250);
    }
    else if (loadProgram && !session.target.isHalted()) {
        session.target.halt();
    }

    if (loadProgram) appendEvent(eventsPath, "LOADPROGRAM OK " + programPath);

    while (keepRunning) {
        var commands = readCommands(commandDirectory, commandPath);
        for (var commandIndex = 0; commandIndex < commands.length; commandIndex++) {
            var command = commands[commandIndex];
            var upper = command.toUpperCase();
            if (!command) continue;

            try {
                if (upper === "RESUME") {
                    session.target.runAsynch();
                    Thread.sleep(100);
                    appendEvent(eventsPath, "RESUME OK");
                }
                else if (upper === "SUSPEND") {
                    manualHaltRequested = true;
                    session.target.halt();
                    appendEvent(eventsPath, "SUSPEND OK");
                }
                else if (upper === "SNAPSHOT") appendEvent(eventsPath, "SNAPSHOT " + snapshot(session, watchExpressions));
                else if (upper === "RECONNECT") {
                    if (session.target.isConnected()) {
                        appendEvent(eventsPath, "RECONNECT SKIPPED already-connected");
                    }
                    else {
                        var reconnectError = null;
                        var reconnected = false;
                        for (var reconnectAttempt = 1; reconnectAttempt <= 5 && !reconnected; reconnectAttempt++) {
                            try {
                                session.target.connect();
                                reconnected = session.target.isConnected();
                            }
                            catch (reconnectAttemptError) {
                                reconnectError = reconnectAttemptError;
                                appendEvent(eventsPath, "RECONNECT_RETRY attempt=" + reconnectAttempt + " " + cleanError(reconnectAttemptError));
                                if (reconnectAttempt < 5) Thread.sleep(500);
                            }
                        }
                        if (!reconnected) throw reconnectError || new Error("Unable to reconnect to target.");

                        session.symbol.load(programPath);
                        var restoreSpecs = [];
                        var oldIds = [];
                        for (var restoreId in activeBreakpoints) {
                            if (!activeBreakpoints.hasOwnProperty(restoreId)) continue;
                            oldIds.push(restoreId);
                            restoreSpecs.push(activeBreakpoints[restoreId]);
                        }
                        try { session.breakpoint.removeAll(); } catch (removeAllError) {}
                        activeBreakpoints = {};
                        for (var oldIndex = 0; oldIndex < oldIds.length; oldIndex++) {
                            appendEvent(eventsPath, "BREAKPOINT_REMOVED id=" + oldIds[oldIndex]);
                        }
                        var restoredCount = 0;
                        for (var restoreIndex = 0; restoreIndex < restoreSpecs.length; restoreIndex++) {
                            try {
                                var restoredId = addBreakpoint(session, restoreSpecs[restoreIndex]);
                                activeBreakpoints[String(restoredId)] = restoreSpecs[restoreIndex];
                                appendEvent(eventsPath, "BREAKPOINT_ADDED id=" + restoredId + " " + restoreSpecs[restoreIndex]);
                                restoredCount++;
                            }
                            catch (restoreBreakpointError) {
                                appendEvent(eventsPath, "BREAKPOINT_ERROR spec=" + restoreSpecs[restoreIndex] + " message=" + restoreBreakpointError);
                            }
                        }
                        appendEvent(eventsPath, "RECONNECT OK restoredBreakpoints=" + restoredCount + "/" + restoreSpecs.length);
                    }
                }
                else if (upper === "STOP") {
                    activeBreakpoints = clearBreakpoints(session, activeBreakpoints, eventsPath);
                    writeText(statusPath, "STOPPED");
                    appendEvent(eventsPath, "STOP");
                    keepRunning = false;
                }
                else if (upper.indexOf("SET ") === 0) {
                    var setExpression = command.substring(4).replace(/^\s+|\s+$/g, "");
                    if (!setExpression) throw new Error("SET command requires an expression.");
                    var equalsIndex = setExpression.indexOf("=");
                    var readbackExpression = equalsIndex > 0 ? setExpression.substring(0, equalsIndex).replace(/^\s+|\s+$/g, "") : setExpression;
                    session.expression.evaluate(setExpression);
                    appendEvent(eventsPath, "SET " + setExpression + " readback=" + safeEvaluate(session, readbackExpression));
                }
                else if (upper.indexOf("READ ") === 0) {
                    var readExpression = command.substring(5).replace(/^\s+|\s+$/g, "");
                    appendEvent(eventsPath, "READ " + readExpression + "=" + safeEvaluate(session, readExpression));
                }
                else if (upper.indexOf("WATCH ") === 0) {
                    var watchText = command.substring(6).replace(/^\s+|\s+$/g, "");
                    watchExpressions = watchText ? watchText.split(";") : [];
                    appendEvent(eventsPath, "WATCH " + watchText);
                }
                else if (upper.indexOf("BREAKADD ") === 0) {
                    if (!session.target.isConnected()) throw new Error("Target is disconnected. Click Reconnect first.");
                    var breakpointSpec = command.substring(9).replace(/^\s+|\s+$/g, "");
                    var breakpointId = addBreakpoint(session, breakpointSpec);
                    activeBreakpoints[String(breakpointId)] = breakpointSpec;
                    appendEvent(eventsPath, "BREAKPOINT_ADDED id=" + breakpointId + " " + breakpointSpec);
                }
                else if (upper.indexOf("BREAKREMOVE ") === 0) {
                    var removeId = parseInt(command.substring(12).replace(/^\s+|\s+$/g, ""), 10);
                    if (isNaN(removeId)) throw new Error("BREAKREMOVE requires a numeric breakpoint id.");
                    session.breakpoint.remove(removeId);
                    delete activeBreakpoints[String(removeId)];
                    appendEvent(eventsPath, "BREAKPOINT_REMOVED id=" + removeId);
                }
                else throw new Error("Unknown command: " + command);
            }
            catch (commandError) {
                if (upper.indexOf("BREAKADD ") === 0) {
                    appendEvent(eventsPath, "BREAKPOINT_ERROR spec=" + command.substring(9).replace(/^\s+|\s+$/g, "") + " message=" + cleanError(commandError));
                }
                appendEvent(eventsPath, "COMMAND_ERROR " + command + " " + cleanError(commandError));
                environment.traceWrite("COMMAND_ERROR " + command + ": " + String(commandError));
            }
            if (!keepRunning) break;
        }

        if (!keepRunning) break;
        connected = session.target.isConnected();
        var state = connected ? (session.target.isHalted() ? "HALTED" : "RUNNING") : "DISCONNECTED";
        var currentStatus = connected ? state + ";" + snapshot(session, watchExpressions) : "DISCONNECTED;message=Target connection lost. Click Reconnect.";
        if (state === "HALTED" && previousState === "RUNNING") {
            var haltedPcText = safeEvaluate(session, "PC");
            var haltedPc = parseInt(haltedPcText, 0);
            var matchedId = "";
            var matchedSpec = "";
            var activeIds = [];
            for (var activeId in activeBreakpoints) {
                if (!activeBreakpoints.hasOwnProperty(activeId)) continue;
                activeIds.push(activeId);
                var activeSpec = String(activeBreakpoints[activeId]);
                if (activeSpec.indexOf("@") === 0 && parseInt(activeSpec.substring(1), 0) === haltedPc) {
                    matchedId = activeId;
                    matchedSpec = activeSpec;
                }
            }

            if (manualHaltRequested) {
                appendEvent(eventsPath, "TARGET_SUSPENDED PC=" + haltedPcText);
            }
            else if (matchedId) {
                appendEvent(eventsPath, "BREAKPOINT_HIT id=" + matchedId + " spec=" + matchedSpec + " PC=" + haltedPcText);
            }
            else if (activeIds.length === 1) {
                matchedId = activeIds[0];
                appendEvent(eventsPath, "BREAKPOINT_HIT id=" + matchedId + " spec=" + activeBreakpoints[matchedId] + " PC=" + haltedPcText);
            }
            else {
                appendEvent(eventsPath, "TARGET_HALTED PC=" + haltedPcText + " activeBreakpointIds=" + activeIds.join(","));
            }
            manualHaltRequested = false;
        }
        if (state !== previousState || commands.length > 0) {
            appendEvent(eventsPath, "STATE " + currentStatus);
            previousState = state;
        }
        writeText(statusPath, currentStatus);
        Thread.sleep(500);
    }
}
catch (error) {
    writeText(statusPath, "ERROR;message=" + cleanError(error));
    appendEvent(eventsPath, "FATAL " + cleanError(error));
    if (environment !== null && traceStarted) environment.traceWrite("AUTODEBUG_HOLD_ERROR: " + String(error));
    else System.err.println("AUTODEBUG_HOLD_ERROR: " + String(error));
}
finally {
    if (session !== null) {
        try { if (session.target.isConnected()) session.target.disconnect(); } catch (disconnectError) {}
        try { session.terminate(); } catch (terminateError) {}
    }
    if (server !== null) try { server.stop(); } catch (serverError) {}
    if (environment !== null && traceStarted) environment.traceEnd();
}

