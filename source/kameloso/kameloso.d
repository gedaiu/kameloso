/++
 +  The main module, housing startup logic and the main event loop.
 +/
module kameloso.kameloso;

import kameloso.common;
import kameloso.printing;
import kameloso.thread : ThreadMessage;
import dialect;
import lu.common : Next;

version(ProfileGC)
{
    /++
     +  Set some flags to tune the garbage collector and have it print profiling
     +  information at program exit, iff version `ProfileGC`.
     +/
    extern(C)
    __gshared string[] rt_options =
    [
        "gcopt=profile:1 gc:precise",
        "scanDataSeg=precise",
    ];
}


// abort
/++
 +  Abort flag.
 +
 +  This is set when the program is interrupted (such as via Ctrl+C). Other
 +  parts of the program will be monitoring it, to take the cue and abort when
 +  it is set.
 +/
__gshared bool abort;


private:

/+
    Warn about bug #18026; Stack overflow in ddmd/dtemplate.d:6241, TemplateInstance::needsCodegen()

    It may have been fixed in versions in the future at time of writing, so
    limit it to 2.086 and earlier. Update this condition as compilers are released.

    Exempt DDoc generation, as it doesn't seem to trigger the segfaults.
 +/
static if (__VERSION__ <= 2088L)
{
    debug
    {
        // Everything is fine in debug mode
    }
    else version(D_Ddoc)
    {
        // Also fine
    }
    else
    {
        pragma(msg, "NOTE: Compilation might not succeed outside of debug mode.");
        pragma(msg, "See bug #18026 at https://issues.dlang.org/show_bug.cgi?id=18026");
    }
}


// signalHandler
/++
 +  Called when a signal is raised, usually `SIGINT`.
 +
 +  Sets the `abort` variable to `true` so other parts of the program knows to
 +  gracefully shut down.
 +
 +  Params:
 +      sig = Integer of the signal raised.
 +/
extern (C)
void signalHandler(int sig) nothrow @nogc @system
{
    import core.stdc.stdio : printf;

    printf("...caught signal %d!\n", sig);
    abort = true;

    // Restore signal handlers to the default
    resetSignals();
}


// mainLoop
/++
 +  This loops creates a `std.concurrency.Generator` `core.thread.Fiber` to loop
 +  over the over `std.socket.Socket`, reading lines and yielding
 +  `lu.net.ListenAttempt`s as it goes.
 +
 +  Full lines are stored in `lu.net.ListenAttempt`s which are
 +  yielded in the `std.concurrency.Generator` to be caught here, consequently
 +  parsed into `dialect.defs.IRCEvent`s, and then dispatched to all plugins.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +
 +  Returns:
 +      `kameloso.common.Next.returnFailure` if circumstances mean the bot
 +      should exit with a non-zero exit code,
 +      `kameloso.common.Next.returnSuccess` if it should exit by returning `0`,
 +      `kameloso.common.Next.retry` if the bot should reconnect to the server.
 +      `kameloso.common.Next.continue_` is never returned.
 +/
Next mainLoop(ref Kameloso instance)
{
    /// Enum denoting what we should do next loop.
    Next next;

    while (next == Next.continue_)
    {
        import core.thread : Fiber;

        import std.datetime.systime : Clock;
        immutable nowInUnix = Clock.currTime.toUnixTime;

        foreach (plugin; instance.plugins)
        {
            if (!plugin.state.timedFibers.length) continue;

            if (plugin.nextFiberTimestamp <= nowInUnix)
            {
                plugin.handleTimedFibers(nowInUnix);
                plugin.updateNextFiberTimestamp();
            }
        }
    }

    return next;
}


import lu.net : ListenAttempt;

// listenAttemptToNext
/++
 +  Translates the `lu.net.ListenAttempt.state` received from a
 +  `std.concurrency.Generator` into a `kameloso.common.Next`, while also providing
 +  warnings and error messages.
 +
 +  Params:
 +      instance = Reference to the current `Kameloso`.
 +      attempt = The `lu.net.ListenAttempt` to map the `.state` value of.
 +
 +  Returns:
 +      A `kameloso.common.Next` describing what action `mainLoop` should take next.
 +/
Next listenAttemptToNext(ref Kameloso instance, const ListenAttempt attempt)
{
    string logtint, errortint, warningtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            logtint = (cast(KamelosoLogger)logger).logtint;
            errortint = (cast(KamelosoLogger)logger).errortint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
        }
    }

    // Handle the attempt; switch on its state
    with (ListenAttempt.State)
    final switch (attempt.state)
    {
    case prelisten:  // Should never happen
        assert(0, "listener attempt yielded state prelisten");

    case isEmpty:
        // Empty line yielded means nothing received; break foreach and try again
        return Next.retry;

    case hasString:
        // hasString means we should drop down and continue processing
        return Next.continue_;

    case warning:
        // Benign socket error; break foreach and try again
        import core.thread : Thread;
        import core.time : seconds;

        logger.warningf("Connection error! (%s%s%s)", logtint,
            attempt.lastSocketError_, warningtint);

        // Sleep briefly so it won't flood the screen on chains of errors
        Thread.sleep(1.seconds);
        return Next.retry;

    case timeout:
        logger.error("Connection lost.");
        instance.conn.connected = false;
        return Next.returnFailure;

    case error:
        if (attempt.bytesReceived == 0)
        {
            logger.errorf("Connection error: empty server response! (%s%s%s)",
                logtint, attempt.lastSocketError_, errortint);
        }
        else
        {
            logger.errorf("Connection error: invalid server response! (%s%s%s)",
                logtint, attempt.lastSocketError_, errortint);
        }

        instance.conn.connected = false;
        return Next.returnFailure;
    }
}

import kameloso.plugins.common : IRCPlugin;

// handleTimedFibers
/++
 +  Processes the timed `core.thread.Fiber`s of an
 +  `kameloso.plugins.common.IRCPlugin`.
 +
 +  Params:
 +      plugin = The `kameloso.plugins.common.IRCPlugin` whose timed
 +          `core.thread.Fiber`s to iterate and process.
 +      nowInUnix = Current UNIX timestamp to compare the timed
 +          `core.thread.Fiber`'s timestamp with.
 +/
void handleTimedFibers(IRCPlugin plugin, const long nowInUnix)
in ((nowInUnix > 0), "Tried to handle timed fibers with an unset timestamp")
do
{
    size_t[] toRemove;

    foreach (immutable i, ref fiber; plugin.state.timedFibers)
    {
        if (fiber.id > nowInUnix) continue;

        try
        {
            import core.thread : Fiber;

            if (fiber.state == Fiber.State.HOLD)
            {
                fiber.call();
            }

            // Always removed a timed Fiber after processing
            toRemove ~= i;
        }
        catch (IRCParseException e)
        {
            string logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;
                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            logger.warningf("IRC Parse Exception %s.timedFibers[%d]: %s%s",
                plugin.name, i, logtint, e.msg);
            printObject(e.event);
            version(PrintStacktraces) logger.trace(e.info);
            toRemove ~= i;
        }
        catch (Exception e)
        {
            string logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;
                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            logger.warningf("Exception %s.timedFibers[%d]: %s%s",
                plugin.name, i, logtint, e.msg);
            version(PrintStacktraces) logger.trace(e.toString);
            toRemove ~= i;
        }
    }

    // Clean up processed Fibers
    foreach_reverse (immutable i; toRemove)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        plugin.state.timedFibers = plugin.state.timedFibers.remove!(SwapStrategy.unstable)(i);
    }
}


// setupSignals
/++
 +  Registers `SIGINT` (and optionally `SIGHUP` on Posix systems) to redirect to
 +  our own `signalHandler`, so we can catch Ctrl+C and gracefully shut down.
 +/
void setupSignals() nothrow @nogc
{
    import core.stdc.signal : signal, SIGINT;

    signal(SIGINT, &signalHandler);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, &signalHandler);
    }
}


// resetSignals
/++
 +  Resets `SIGINT` (and `SIGHUP` handlers) to the system default.
 +/
void resetSignals() nothrow @nogc
{
    import core.stdc.signal : signal, SIG_DFL, SIGINT;

    signal(SIGINT, SIG_DFL);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, SIG_DFL);
    }
}


// tryResolve
/++
 +  Tries to resolve the address in `instance.parser.server` to IPs, by
 +  leveraging `lu.net.resolveFiber`, reacting on the
 +  `lu.net.ResolveAttempt`s it yields to provide feedback to the user.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +
 +  Returns:
 +      `kameloso.common.Next.continue_` if resolution succeeded,
 +      `kameloso.common.Next.returnFailure` if it failed and the program should exit.
 +/
Next tryResolve(ref Kameloso instance)
{
    import kameloso.constants : Timeout;
    import lu.net : ResolveAttempt, resolveFiber;
    import std.concurrency : Generator;

    string infotint, logtint, warningtint, errortint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
            errortint = (cast(KamelosoLogger)logger).errortint;
        }
    }

    enum defaultResolveAttempts = 15;
    immutable resolveAttempts = settings.endlesslyConnect ? int.max : defaultResolveAttempts;

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(instance.conn, instance.parser.server.address,
        instance.parser.server.port, settings.ipv6, resolveAttempts, *instance.abort));

    uint incrementedRetryDelay = Timeout.retry;
    enum incrementMultiplier = 1.2;

    with (instance)
    foreach (const attempt; resolver)
    {
        with (ResolveAttempt.State)
        final switch (attempt.state)
        {
        case preresolve:
            // No message for this
            continue;

        case success:
            import lu.string : plurality;
            logger.infof("%s%s resolved into %s%s%2$s %5$s.",
                parser.server.address, logtint, infotint, conn.ips.length,
                conn.ips.length.plurality("IP", "IPs"));
            return Next.continue_;

        case exception:
            logger.warningf("Could not resolve server address. (%s%s%s)",
                logtint, attempt.error, warningtint);

            if (attempt.retryNum+1 < resolveAttempts)
            {
                import kameloso.thread : interruptibleSleep;
                import core.time : seconds;

                logger.logf("Network down? Retrying in %s%d%s seconds.",
                    infotint, incrementedRetryDelay, logtint);
                interruptibleSleep(incrementedRetryDelay.seconds, *abort);
                if (*abort) return Next.returnFailure;

                import std.algorithm.comparison : min;

                enum delayCap = 10*60;  // seconds
                incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
                incrementedRetryDelay = min(incrementedRetryDelay, delayCap);
            }
            continue;

        case error:
            logger.errorf("Could not resolve server address. (%s%s%s)", logtint, attempt.error, errortint);
            logger.log("Failed to resolve host to IPs. Verify your server address.");
            return Next.returnFailure;

        case failure:
            logger.error("Failed to resolve host.");
            return Next.returnFailure;
        }
    }

    return Next.returnFailure;
}


// complainAboutInvalidConfigurationEntries
/++
 +  Prints some information about invalid configuration entries to the local terminal.
 +
 +  Params:
 +      invalidEntries = A `string[][string]` associative array of dynamic
 +          `string[]` arrays, keyed by strings. These contain invalid settings.
 +/
void complainAboutInvalidConfigurationEntries(const string[][string] invalidEntries)
{
    if (!invalidEntries.length) return;

    logger.log("Found invalid configuration entries:");

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
        }
    }

    foreach (immutable section, const sectionEntries; invalidEntries)
    {
        logger.logf(`...under [%s%s%s]: %s%-("%s"%|, %)`,
            infotint, section, logtint, infotint, sectionEntries);
    }

    logger.log("They are either malformed, no longer in use or belong to " ~
        "plugins not currently compiled in.");
    logger.logf("Use %s--writeconfig%s to update your configuration file. [%1$s%3$s%2$s]",
        infotint, logtint, settings.configFile);
    logger.warning("Mind that any settings belonging to unbuilt plugins will be LOST.");
    logger.trace("---");
}


// complainAboutMissingConfiguration
/++
 +  Displays an error if the configuration is *incomplete*, e.g. missing crucial information.
 +
 +  It assumes such information is missing, and that the check has been done at
 +  the calling site.
 +
 +  Params:
 +      args = The command-line arguments passed to the program at start.
 +/
void complainAboutMissingConfiguration(const string[] args)
{
    import std.file : exists;
    import std.path : baseName;

    logger.warning("Warning: No administrators nor home channels configured!");

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
        }
    }

    if (settings.configFile.exists)
    {
        logger.logf("Edit %s%s%s and make sure it has at least one of the following:",
            infotint, settings.configFile, logtint);
        complainAboutIncompleteConfiguration();
    }
    else
    {
        logger.logf("Use %s%s --writeconfig%s to generate a configuration file.",
            infotint, args[0].baseName, logtint);
    }
}


// preInstanceSetup
/++
 +  Sets up the program (terminal) environment.
 +
 +  Depending on your platform it may set any of thread name, terminal title and
 +  console codepages.
 +
 +  This is called very early during execution.
 +/
void preInstanceSetup()
{
    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("kameloso");
    }

    version(Windows)
    {
        import kameloso.terminal : setConsoleModeAndCodepage;

        // Set up the console to display text and colours properly.
        setConsoleModeAndCodepage();
    }

    import kameloso.constants : KamelosoInfo;
    import kameloso.terminal : setTitle;

    enum terminalTitle = "kameloso v" ~ cast(string)KamelosoInfo.version_;
    setTitle(terminalTitle);
}


// startBot
/++
 +  Main connection logic.
 +
 +  This function *starts* the bot, after it has been sufficiently initialised.
 +  It resolves and connects to servers, then hands off execution to `mainLoop`.
 +
 +  Params:
 +      instance = Reference to the current `Kameloso`.
 +      attempt = Voldemort aggregate of state variables used when connecting.
 +/
void startBot(Attempt)(ref Kameloso instance, ref Attempt attempt)
{
    string logtint, warningtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
        }
    }

    // Save a backup snapshot of the client, for restoring upon reconnections
    IRCClient backupClient = instance.parser.client;

    with (attempt)
    outerloop:
    do
    {
        // *instance.abort is guaranteed to be false here.

        silentExit = true;

        import kameloso.plugins.common : IRCPluginInitialisationException;
        import std.path : baseName;

        // Ensure initialised resources after resolve so we know we have a
        // valid server to create a directory for.
        instance.initPluginResources();
        if (*instance.abort) break outerloop;

        import dialect.parsing : IRCParser;

        // Reinit with its own server.
        instance.parser = IRCParser(backupClient, instance.parser.server);

        instance.startPlugins();
        if (*instance.abort) break outerloop;

        next = instance.mainLoop();
        firstConnect = false;
    }
    while (!*instance.abort && ((next == Next.continue_) || (next == Next.retry) ||
        ((next == Next.returnFailure) && settings.reconnectOnFailure)));
}


public:


// initBot
/++
 +  Entry point of the program.
 +
 +  Params:
 +      args = Command-line arguments passed to the program.
 +
 +  Returns:
 +      `0` on success, `1` on failure.
 +/
int initBot(string[] args)
{
    /// Voldemort aggregate of state variables.
    struct Attempt
    {
        /// Enum denoting what we should do next loop.
        Next next;

        /++
         +  An array for `handleGetopt` to fill by ref with custom settings
         +  set on the command-line using `--set plugin.setting=value`.
         +/
        string[] customSettings;

        /++
         +  Bool whether this is the first connection attempt or if we have
         +  connected at least once already.
         +/
        bool firstConnect = true;

        /// Whether or not "Exiting..." should be printed at program exit.
        bool silentExit;

        /// Shell return value to exit with.
        int retval;
    }

    // Set up the terminal environment.
    //preInstanceSetup();

    // Initialise the main Kameloso. Set its abort pointer to the global abort.
    Kameloso instance;
    instance.abort = &abort;
    Attempt attempt;

    // Set up `kameloso.common.settings`, expanding paths.
    //setupSettings();

    // Initialise the logger immediately so it's always available.
    // handleGetopt re-inits later when we know the settings for monochrome
    initLogger(settings.monochrome, settings.brightTerminal, settings.flush);

    // Set up signal handling so that we can gracefully catch Ctrl+C.
    setupSignals();

    scope(failure)
    {
        import kameloso.terminal : TerminalToken;

        logger.error("We just crashed!", cast(char)TerminalToken.bell);
        *instance.abort = true;
        resetSignals();
    }

    // Apply some defaults to empty members, as stored in `kameloso.constants`.
    import kameloso.common : applyDefaults;
    applyDefaults(instance.parser.client, instance.parser.server);

    string pre, post, infotint, logtint, warningtint, errortint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;
            import kameloso.terminal : TerminalForeground, colour;

            enum headertintColourBright = TerminalForeground.black.colour;
            enum headertintColourDark = TerminalForeground.white.colour;
            enum defaulttintColour = TerminalForeground.default_.colour;
            pre = settings.brightTerminal ? headertintColourBright : headertintColourDark;
            post = defaulttintColour;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
            errortint = (cast(KamelosoLogger)logger).errortint;
        }
    }

    import std.stdio : writeln;
    printVersionInfo(pre, post);
    writeln();

    import kameloso.printing : printObjects;

    // Print the current settings to show what's going on.
    printObjects(instance.parser.client, instance.bot, instance.parser.server);

    if (!instance.bot.homes.length && !instance.bot.admins.length)
    {
        complainAboutMissingConfiguration(args);
    }

    // Save the original nickname *once*, outside the connection loop and before
    // initialising plugins (who will make a copy of it). Knowing this is useful
    // when authenticating.
    instance.parser.client.origNickname = instance.parser.client.nickname;

    // Initialise plugins outside the loop once, for the error messages
    import kameloso.plugins.common : IRCPluginSettingsException;
    import std.conv : ConvException;

    try
    {
        const invalidEntries = instance.initPlugins(attempt.customSettings);
        complainAboutInvalidConfigurationEntries(invalidEntries);
    }
    catch (ConvException e)
    {
        // Configuration file/--set argument syntax error
        logger.error(e.msg);
        if (!settings.force) return 1;
    }
    catch (IRCPluginSettingsException e)
    {
        // --set plugin/setting name error
        logger.error(e.msg);
        if (!settings.force) return 1;
    }

    // Save the original nickname *once*, outside the connection loop.
    // It will change later and knowing this is useful when authenticating
    instance.parser.client.origNickname = instance.parser.client.nickname;

    // Go!
    instance.startBot(attempt);

    // If we're here, we should exit. The only question is in what way.

    if (*instance.abort && instance.conn.connected)
    {
        // Connected and aborting

        if (!settings.hideOutgoing)
        {
            version(Colours)
            {
                import kameloso.irccolours : mapEffects;
                logger.trace("--> QUIT :", instance.bot.quitReason.mapEffects);
            }
            else
            {
                import kameloso.irccolours : stripEffects;
                logger.trace("--> QUIT :", instance.bot.quitReason.stripEffects);
            }
        }

        instance.conn.sendline("QUIT :" ~ instance.bot.quitReason);
    }
    else if (!*instance.abort && (attempt.next == Next.returnFailure) &&
        !settings.reconnectOnFailure)
    {
        // Didn't Ctrl+C, did return failure and shouldn't reconnect
        logger.logf("(Not reconnecting due to %sreconnectOnFailure%s not being enabled)", infotint, logtint);
    }

    // Save if we're exiting and configuration says we should.
    if (settings.saveOnExit)
    {
        instance.writeConfigurationFile(settings.configFile);
    }

    if (*instance.abort)
    {
        // Ctrl+C
        logger.error("Aborting...");
        return 1;
    }
    else if (!attempt.silentExit)
    {
        logger.info("Exiting...");
    }

    return attempt.retval;
}
