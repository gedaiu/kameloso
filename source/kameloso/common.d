/++
 +  Common functions used throughout the program, generic enough to be used in
 +  several places, not fitting into any specific one.
 +/
module kameloso.common;

private:

import dialect.defs : IRCClient, IRCServer;
import std.experimental.logger.core : Logger;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Tuple, Yes;
import core.time : Duration, seconds;

public:

@safe:

version(unittest)
shared static this()
{
    import kameloso.logger : KamelosoLogger;

    // This is technically before settings have been read...
    logger = new KamelosoLogger;
}


// logger
/++
 +  Instance of a `kameloso.logger.KamelosoLogger`, providing timestamped and
 +  coloured logging.
 +
 +  The member functions to use are `log`, `trace`, `info`, `warning`, `error`,
 +  and `fatal`. It is not global, so instantiate a thread-local
 +  `std.experimental.logger.Logger` if threading.
 +
 +  Having this here is unfortunate; ideally plugins should not use variables
 +  from other modules, but unsure of any way to fix this other than to have
 +  each plugin keep their own `std.experimental.logger.Logger`.
 +/
Logger logger;


// initLogger
/++
 +  Initialises the `kameloso.logger.KamelosoLogger` logger for use in this thread.
 +
 +  It needs to be separately instantiated per thread.
 +
 +  Example:
 +  ---
 +  initLogger(settings.monochrome, settings.brightTerminal, settings.flush);
 +  ---
 +
 +  Params:
 +      monochrome = Whether the terminal is set to monochrome or not.
 +      bright = Whether the terminal has a bright background or not.
 +      flush = Whether or not to flush stdout after finishing writing to it.
 +/
void initLogger(const bool monochrome = settings.monochrome,
    const bool bright = settings.brightTerminal,
    const bool flush = settings.flush)
out (; (logger !is null), "Failed to initialise logger")
do
{
    import kameloso.logger : KamelosoLogger;
    import std.experimental.logger : LogLevel;

    logger = new KamelosoLogger(LogLevel.all, monochrome, bright, flush);
}


// settings
/++
 +  A `CoreSettings` struct global, housing certain runtime settings.
 +
 +  This will be accessed from other parts of the program, via
 +  `kameloso.common.settings`, so they know to use monochrome output or not.
 +  It is a problem that needs solving.
 +/
__gshared CoreSettings settings;


// CoreSettings
/++
 +  Aggregate struct containing runtime bot setting variables.
 +
 +  Kept inside one struct, they're nicely gathered and easy to pass around.
 +  Some defaults are hardcoded here.
 +/
struct CoreSettings
{
    import lu.uda : CannotContainComments, Hidden, Quoted, Unserialisable;

    version(Colours)
    {
        bool monochrome = false;  /// Logger monochrome setting.
    }
    else
    {
        bool monochrome = true;  /// Non-colours version defaults to true.
    }

    /// Flag denoting whether or not the program should reconnect after disconnect.
    bool reconnectOnFailure = true;

    /// Flag denoting that the terminal has a bright background.
    bool brightTerminal = false;

    /// Whether to connect to IPv6 addresses or not.
    bool ipv6 = true;

    /// Whether to print outgoing messages or not.
    bool hideOutgoing = false;

    /// Whether to add colours to outgoing messages or not.
    bool colouredOutgoing = true;

    /// Flag denoting that we should save to file on exit.
    bool saveOnExit = false;

    /// Whether to endlessly connect or whether to give up after a while.
    bool endlesslyConnect = true;

    /// Whether or not to display a connection summary on program exit.
    bool exitSummary = false;

    /++
     +  Whether or not to exhaustively WHOIS all participants in home channels,
     +  and not do a just-in-time lookup when needed.
     +/
    bool eagerLookups = false;

    /// Character(s) that prefix a bot chat command.
    @Quoted string prefix = "!";

    @Unserialisable
    @Hidden
    {
        string configFile;  /// Main configuration file.
        string resourceDirectory;  /// Path to resource directory.
        string configDirectory;  /// Path to configuration directory.
        bool force;  /// Whether or not to force connecting.
        bool flush;  /// Whether or not to flush stdout after writing to it.
    }
}


// IRCBot
/++
 +  Aggregate of information relevant for an IRC *bot* that goes beyond what is
 +  needed for a mere IRC *client*.
 +/
struct IRCBot
{
    import lu.uda : CannotContainComments, Hidden, Separator, Quoted, Unserialisable;

    /// Username to use as services account login name.
    string account;

    @Hidden
    @CannotContainComments
    {
        /// Password for services account.
        string password;

        /// Login `PASS`, different from `SASL` and services.
        string pass;

        /// Default reason given when quitting without specifying one.
        string quitReason;
    }

    @Separator(",")
    @Separator(" ")
    {
        /// The nickname services accounts of *administrators*, in a bot-like context.
        string[] admins;

        /// List of home channels, in a bot-like context.
        @CannotContainComments
        string[] homeChannels;

        @Hidden
        deprecated("Use `homeChannels` instead")
        alias homes = homeChannels;

        /// Currently inhabited non-home channels.
        @CannotContainComments
        string[] guestChannels;

        @Hidden
        deprecated("Use `guestChannels` instead")
        alias channels = guestChannels;
    }
}


// Kameloso
/++
 +  State needed for the kameloso bot, aggregated in a struct for easier passing
 +  by reference.
 +/
struct Kameloso
{
    import kameloso.common : OutgoingLine;
    import kameloso.constants : BufferSize;
    import kameloso.plugins.ircplugin : IRCPlugin;
    import dialect.parsing : IRCParser;
    import lu.container : Buffer;
    import lu.net : Connection;

    import std.datetime.systime : SysTime;

    // Throttle
    /++
     +  Aggregate of values and state needed to throttle messages without
     +  polluting namespace too much.
     +/
    private struct Throttle
    {
        /// Graph constant modifier (inclination, MUST be negative).
        enum k = -1.2;

        /// Origo of x-axis (last sent message).
        SysTime t0;

        /// y at t0 (ergo y at x = 0, weight at last sent message).
        double m = 0.0;

        /// Increment to y on sent message.
        double increment = 1.0;

        /++
         +  Burst limit; how many messages*increment can be sent initially
         +  before throttling kicks in.
         +/
        double burst = 3.0;

        /// Don't copy this, just keep one instance.
        @disable this(this);
    }

    /// The socket we use to connect to the server.
    Connection conn;

    /++
     +  A runtime array of all plugins. We iterate these when we have finished
     +  parsing an `dialect.defs.IRCEvent`, and call the relevant event
     +  handlers of each.
     +/
    IRCPlugin[] plugins;

    /// When a nickname was called `WHOIS` on, for hysteresis.
    long[string] previousWhoisTimestamps;

    /// Parser instance.
    IRCParser parser;

    /// IRC bot values.
    IRCBot bot;

    /// Values and state needed to throttle sending messages.
    Throttle throttle;

    /++
     +  When this is set by signal handlers, the program should exit. Other
     +  parts of the program will be monitoring it.
     +/
    __gshared bool* abort;

    /++
     +  When this is set, the main loop should print a connection summary upon
     +  the next iteration.
     +/
    bool wantLiveSummary;

    /++
     +  Buffer of outgoing message strings.
     +
     +  The buffer size is "how many string pointers", now how many bytes. So
     +  we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer) outbuffer;

    /++
     +  Buffer of outgoing priority message strings.
     +
     +  The buffer size is "how many string pointers", now how many bytes. So
     +  we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.priorityBuffer) priorityBuffer;

    version(TwitchSupport)
    {
        /++
         +  Buffer of outgoing fast message strings.
         +
         +  The buffer size is "how many string pointers", now how many bytes. So
         +  we can comfortably keep it arbitrarily high.
         +/
        Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer*2) fastbuffer;
    }

    /// Never copy this.
    @disable this(this);


    // throttleline
    /++
     +  Takes one or more lines from the passed buffer and sends them to the server.
     +
     +  Sends to the server in a throttled fashion, based on a simple
     +  `y = k*x + m` graph.
     +
     +  This is so we don't get kicked by the server for spamming, if a lot of
     +  lines are to be sent at once.
     +
     +  Params:
     +      Buffer = Buffer type, generally `Buffer`.
     +      buffer = `Buffer` instance.
     +      onlyIncrement = Whether or not to send anything or just do a dry run,
     +          incrementing the graph by `throttle.increment`.
     +      sendFaster = On Twitch, whether or not we should throttle less and
     +          send messages faster. Useful in some situations when rate-limiting
     +          is more lax.
     +
     +  Returns:
     +      The time remaining until the next message may be sent, so that we
     +      can reschedule the next server read timeout to happen earlier.
     +/
    double throttleline(Buffer)(ref Buffer buffer,
        const Flag!"onlyIncrement" onlyIncrement = No.onlyIncrement,
        const Flag!"sendFaster" sendFaster = No.sendFaster)
    {
        with (throttle)
        {
            import std.datetime.systime : Clock;

            immutable now = Clock.currTime;
            if (t0 == SysTime.init) t0 = now;

            version(TwitchSupport)
            {
                import dialect.defs : IRCServer;

                double k = throttle.k;
                double burst = throttle.burst;

                if (parser.server.daemon == IRCServer.Daemon.twitch)
                {
                    if (sendFaster)
                    {
                        // FIXME: Tweak numbers.
                        k = -3.0;
                        burst = 10.0;
                    }
                    else
                    {
                        k = -1.0;
                        burst = 1.0;
                    }
                }
            }

            while (!buffer.empty || onlyIncrement)
            {
                double x = (now - t0).total!"msecs"/1000.0;
                double y = k * x + m;

                if (y < 0.0)
                {
                    t0 = now;
                    x = 0.0;
                    y = 0.0;
                    m = 0.0;
                }

                if (y >= burst)
                {
                    x = (now - t0).total!"msecs"/1000.0;
                    y = k*x + m;
                    return y;
                }

                m = y + increment;
                t0 = now;

                if (onlyIncrement) break;

                if (!buffer.front.quiet)
                {
                    version(Colours)
                    {
                        import kameloso.irccolours : mapEffects;
                        logger.trace("--> ", buffer.front.line.mapEffects);
                    }
                    else
                    {
                        import kameloso.irccolours : stripEffects;
                        logger.trace("--> ", buffer.front.line.stripEffects);
                    }
                }

                conn.sendline(buffer.front.line);
                buffer.popFront();
            }

            return 0.0;
        }
    }


    // initPlugins
    /++
     +  Resets and *minimally* initialises all plugins.
     +
     +  It only initialises them to the point where they're aware of their
     +  settings, and not far enough to have loaded any resources.
     +
     +  Params:
     +      customSettings = String array of custom settings to apply to plugins
     +          in addition to those read from the configuration file.
     +      missingEntries = Out reference of an associative array of string arrays
     +          of expected configuration entries that were missing.
     +      invalidEntries = Out reference of an associative array of string arrays
     +          of unexpected configuration entries that did not belong.
     +
     +  Throws:
     +      `kameloso.plugins.common.IRCPluginSettingsException` on failure to apply custom settings.
     +/
    void initPlugins(const string[] customSettings, out string[][string] missingEntries,
        out string[][string] invalidEntries) @system
    {
        import kameloso.plugins : EnabledPlugins;
        import kameloso.plugins.common : IRCPluginState, applyCustomSettings;
        import std.concurrency : thisTid;
        import std.datetime.systime : Clock;

        teardownPlugins();

        IRCPluginState state;
        state.client = parser.client;
        state.server = parser.server;
        state.bot = this.bot;
        state.mainThread = thisTid;
        immutable now = Clock.currTime.toUnixTime;

        plugins.reserve(EnabledPlugins.length);

        // Instantiate all plugin types in `kameloso.plugins.package.EnabledPlugins`
        foreach (Plugin; EnabledPlugins)
        {
            plugins ~= new Plugin(state);
        }

        foreach (plugin; plugins)
        {
            import lu.meld : meldInto;

            string[][string] theseMissingEntries;
            string[][string] theseInvalidEntries;

            plugin.deserialiseConfigFrom(settings.configFile,
                theseMissingEntries, theseInvalidEntries);

            if (theseMissingEntries.length)
            {
                theseMissingEntries.meldInto(missingEntries);
            }

            if (theseInvalidEntries.length)
            {
                theseInvalidEntries.meldInto(invalidEntries);
            }

            if (plugin.state.nextPeriodical == 0)
            {
                import kameloso.constants : Timeout;

                // Schedule first periodical in `Timeout.initialPeriodical` for
                // plugins that don't set a timestamp themselves in `initialise`
                plugin.state.nextPeriodical = now + Timeout.initialPeriodical;
            }
        }

        immutable allCustomSuccess = plugins.applyCustomSettings(customSettings);

        if (!allCustomSuccess)
        {
            import kameloso.plugins.common : IRCPluginSettingsException;
            throw new IRCPluginSettingsException("Some custom plugin settings could not be applied.");
        }
    }


    // initPluginResources
    /++
     +  Initialises all plugins' resource files.
     +
     +  This merely calls `kameloso.plugins.common.IRCPlugin.initResources()` on
     +  each plugin.
     +/
    void initPluginResources() @system
    {
        foreach (plugin; plugins)
        {
            plugin.initResources();
        }
    }


    // teardownPlugins
    /++
     +  Tears down all plugins, deinitialising them and having them save their
     +  settings for a clean shutdown.
     +
     +  Think of it as a plugin destructor.
     +/
    void teardownPlugins() @system
    {
        if (!plugins.length) return;

        foreach (plugin; plugins)
        {
            import std.exception : ErrnoException;
            import core.memory : GC;

            try
            {
                plugin.teardown();

                if (plugin.state.botUpdated)
                {
                    plugin.state.botUpdated = false;
                    propagateBot(plugin.state.bot);
                }

                if (plugin.state.clientUpdated)
                {
                    plugin.state.clientUpdated = false;
                    propagateClient(parser.client);
                }

                if (plugin.state.serverUpdated)
                {
                    plugin.state.serverUpdated = false;
                    propagateServer(parser.server);
                }
            }
            catch (ErrnoException e)
            {
                import core.stdc.errno : ENOENT;
                import std.file : exists;
                import std.path : dirName;

                if ((e.errno == ENOENT) && !settings.resourceDirectory.dirName.exists)
                {
                    // The resource directory hasn't been created, don't panic
                }
                else
                {
                    logger.warningf("ErrnoException when tearing down %s: %s",
                        plugin.name, e.msg);
                    version(PrintStacktraces) logger.trace(e.info);
                }
            }
            catch (Exception e)
            {
                logger.warningf("Exception when tearing down %s: %s", plugin.name, e.msg);
                version(PrintStacktraces) logger.trace(e.toString);
            }

            destroy(plugin);
            GC.free(&plugin);
        }

        // Zero out old plugins array
        plugins = typeof(plugins).init;
    }


    // startPlugins
    /++
     +  *start* all plugins, loading any resources they may want.
     +
     +  This has to happen after `initPlugins` or there will not be any plugins
     +  in the `plugins` array to start.
     +/
    void startPlugins() @system
    {
        foreach (plugin; plugins)
        {
            plugin.start();

            if (plugin.state.botUpdated)
            {
                // start changed the bot; propagate
                plugin.state.botUpdated = false;
                propagateBot(plugin.state.bot);
            }

            if (plugin.state.clientUpdated)
            {
                // start changed the client; propagate
                plugin.state.clientUpdated = false;
                propagateClient(plugin.state.client);
            }

            if (plugin.state.serverUpdated)
            {
                // start changed the server; propagate
                plugin.state.serverUpdated = false;
                propagateServer(plugin.state.server);
            }
        }
    }


    // propagateClient
    /++
     +  Takes a `dialect.defs.IRCClient` and passes it out to all plugins.
     +
     +  This is called when a change to the client has occurred and we want to
     +  update all plugins to have a current copy of it.
     +
     +  Params:
     +      client = `dialect.defs.IRCClient` to propagate to all plugins.
     +/
    void propagateClient(IRCClient client) pure nothrow @nogc
    {
        parser.client = client;

        foreach (plugin; plugins)
        {
            plugin.state.client = client;
        }
    }


    // propagateServer
    /++
     +  Takes a `dialect.defs.IRCServer` and passes it out to all plugins.
     +
     +  This is called when a change to the server has occurred and we want to
     +  update all plugins to have a current copy of it.
     +
     +  Params:
     +      server = `dialect.defs.IRCServer` to propagate to all plugins.
     +/
    void propagateServer(IRCServer server) pure nothrow @nogc
    {
        parser.server = server;

        foreach (plugin; plugins)
        {
            plugin.state.server = server;
        }
    }


    // propagateBot
    /++
     +  Takes a `kameloso.common.IRCBot` and passes it out to all plugins.
     +
     +  This is called when a change to the bot has occurred and we want to
     +  update all plugins to have a current copy of it.
     +
     +  Params:
     +      bot = `kameloso.common.IRCBot` to propagate to all plugins.
     +/
    void propagateBot(IRCBot bot) pure nothrow @nogc
    {
        this.bot = bot;

        foreach (plugin; plugins)
        {
            plugin.state.bot = bot;
        }
    }


    // ConnectionHistoryEntry
    /++
     +  A record of a successful connection.
     +/
    struct ConnectionHistoryEntry
    {
        /// UNIX time when this connection was established.
        long startTime;

        /// UNIX time when this connection was lost.
        long stopTime;

        /// How many events fired during this connection.
        long numEvents;
    }

    /// History records of established connections this execution run.
    ConnectionHistoryEntry[] connectionHistory;
}


version(Colours)
{
    private import kameloso.terminal : TerminalForeground;
}

// printVersionInfo
/++
 +  Prints out the bot banner with the version number and GitHub URL, with the
 +  passed colouring.
 +
 +  Example:
 +  ---
 +  printVersionInfo(TerminalForeground.white);
 +  ---
 +
 +  Params:
 +      colourCode = Terminal foreground colour to display the text in.
 +/
version(Colours)
void printVersionInfo(TerminalForeground colourCode) @system
{
    import kameloso.terminal : colour;

    enum fgDefault = TerminalForeground.default_.colour.idup;
    return printVersionInfo(colourCode.colour, fgDefault);
}


// printVersionInfo
/++
 +  Prints out the bot banner with the version number and GitHub URL, optionally
 +  with passed colouring in string format.
 +
 +  Overload that does not rely on `kameloso.terminal.TerminalForeground` being available, yet
 +  takes the necessary parameters to allow the other overload to reuse this one.
 +
 +  Example:
 +  ---
 +  printVersionInfo();
 +  ---
 +
 +  Params:
 +      pre = String to preface the line with, usually a colour code string.
 +      post = String to end the line with, usually a resetting code string.
 +/
void printVersionInfo(const string pre = string.init, const string post = string.init) @system
{
    import kameloso.constants : KamelosoInfo;
    import std.stdio : stdout, writefln;

    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        pre,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        post);

    if (settings.flush) stdout.flush();
}


// printStacktrace
/++
 +  Prints the current stacktrace to the terminal.
 +
 +  This is so we can get the stacktrace even outside a thrown Exception.
 +/
version(PrintStacktraces)
void printStacktrace() @system
{
    import core.runtime : defaultTraceHandler;
    import std.stdio : writeln;

    writeln(defaultTraceHandler);
}


// OutgoingLine
/++
 +  A string to be sent to the IRC server, along with whether or not the message
 +  should be sent quietly or if it should be displayed in the terminal.
 +/
struct OutgoingLine
{
    /// String line to send.
    string line;

    /// Whether or not this message should be sent quietly or verbosely.
    bool quiet;

    /// Constructor.
    this(const string line, const bool quiet = false)
    {
        this.line = line;
        this.quiet = quiet;
    }
}


// findURLs
/++
 +  Finds URLs in a string, returning an array of them.
 +
 +  Replacement for regex matching using much less memory when compiling
 +  (around ~300mb).
 +
 +  To consider: does this need a `dstring`?
 +
 +  Example:
 +  ---
 +  // Replaces the following:
 +  // enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;
 +  // static urlRegex = ctRegex!stephenhay;
 +
 +  string[] urls = findURL("blah https://google.com http://facebook.com httpx://wefpokwe");
 +  assert(urls.length == 2);
 +  ---
 +
 +  Params:
 +      line = String line to examine and find URLs in.
 +
 +  Returns:
 +      A `string[]` array of found URLs. These include fragment identifiers.
 +/
string[] findURLs(const string line) @safe pure
{
    import lu.string : contains, nom, strippedRight;
    import std.string : indexOf;
    import std.typecons : Flag, No, Yes;

    enum wordBoundaryTokens = ".,!?:";

    string[] hits;
    string slice = line;  // mutable

    ptrdiff_t httpPos = slice.indexOf("http");

    while (httpPos != -1)
    {
        if ((httpPos > 0) && (slice[httpPos-1] != ' '))
        {
            // Run-on http address (character before the 'h')
            slice = slice[httpPos+4..$];
            httpPos = slice.indexOf("http");
            continue;
        }

        slice = slice[httpPos..$];

        if (slice.length < 11)
        {
            // Too short, minimum is "http://a.se".length
            break;
        }
        else if ((slice[4] != ':') && (slice[4] != 's'))
        {
            // Not http or https, something else
            // But could still be another link after this
            slice = slice[5..$];
            httpPos = slice.indexOf("http");
            continue;
        }
        else if (!slice[8..$].contains('.'))
        {
            break;
        }
        else if (!slice.contains(' ') &&
            (slice[10..$].contains("http://") ||
            slice[10..$].contains("https://")))
        {
            // There is a second URL in the middle of this one
            break;
        }

        // nom until the next space if there is one, otherwise just inherit slice
        // Also strip away common punctuation
        hits ~= slice.nom!(Yes.inherit)(' ').strippedRight(wordBoundaryTokens);
        httpPos = slice.indexOf("http");
    }

    return hits;
}

///
unittest
{
    import std.conv : text;

    {
        const urls = findURLs("http://google.com");
        assert((urls.length == 1), urls.text);
        assert((urls[0] == "http://google.com"), urls[0]);
    }
    {
        const urls = findURLs("blah https://a.com http://b.com shttps://c https://d.asdf.asdf.asdf        ");
        assert((urls.length == 3), urls.text);
        assert((urls == [ "https://a.com", "http://b.com", "https://d.asdf.asdf.asdf" ]), urls.text);
    }
    {
        const urls = findURLs("http:// http://asdf https:// asdfhttpasdf http");
        assert(!urls.length, urls.text);
    }
    {
        const urls = findURLs("http://a.sehttp://a.shttp://a.http://http:");
        assert(!urls.length, urls.text);
    }
    {
        const urls = findURLs("blahblah https://motorbörsen.se blhblah");
        assert(urls.length, urls.text);
    }
    {
        // Let dlang-requests attempt complex URLs, don't validate more than necessary
        const urls = findURLs("blahblah https://高所恐怖症。co.jp blhblah");
        assert(urls.length, urls.text);
    }
    {
        const urls = findURLs("nyaa is now at https://nyaa.si, https://nyaa.si? " ~
            "https://nyaa.si. https://nyaa.si! and you should use it https://nyaa.si:");

        foreach (immutable url; urls)
        {
            assert((url == "https://nyaa.si"), url);
        }
    }
    {
        const urls = findURLs("https://google.se httpx://google.se https://google.se");
        assert((urls == [ "https://google.se", "https://google.se" ]), urls.text);
    }
}


// timeSince
/++
 +  Express how much time has passed in a `Duration`, in natural (English) language.
 +
 +  Write the result to a passed output range `sink`.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +
 +  const then = Clock.currTime;
 +  Thread.sleep(1.seconds);
 +  const now = Clock.currTime;
 +
 +  const duration = (now - then);
 +  immutable inEnglish = sink.timeSince(duration);
 +  ---
 +
 +  Params:
 +      abbreviate = Whether or not to abbreviate the output, using `h` instead
 +          of `hours`, `m` instead of `minutes`, etc.
 +      sink = Output buffer sink to write to.
 +      duration = A period of time.
 +/
void timeSince(Flag!"abbreviate" abbreviate = No.abbreviate, Sink)
    (auto ref Sink sink, const Duration duration) pure
if (isOutputRange!(Sink, char[]))
in ((duration >= 0.seconds), "Cannot call `timeSince` on a negative duration")
do
{
    import std.format : formattedWrite;
    import std.traits : isIntegral, isSomeString;

    static if (!__traits(hasMember, Sink, "put")) import std.range.primitives : put;

    int days, hours, minutes, seconds;
    duration.split!("days", "hours", "minutes", "seconds")(days, hours, minutes, seconds);

    // Copied from lu.string to avoid importing it
    pragma(inline)
    static string plurality(const int num, const string singular, const string plural) pure nothrow @nogc
    {
        return ((num == 1) || (num == -1)) ? singular : plural;
    }

    if (days)
    {
        static if (abbreviate)
        {
            sink.formattedWrite("%dd", days);
        }
        else
        {
            sink.formattedWrite("%d %s", days, plurality(days, "day", "days"));
        }
    }

    if (hours)
    {
        static if (abbreviate)
        {
            if (days) sink.put(' ');
            sink.formattedWrite("%dh", hours);
        }
        else
        {
            if (days)
            {
                if (minutes) sink.put(", ");
                else sink.put("and ");
            }
            sink.formattedWrite("%d %s", hours, plurality(hours, "hour", "hours"));
        }
    }

    if (minutes)
    {
        static if (abbreviate)
        {
            if (hours || days) sink.put(' ');
            sink.formattedWrite("%dm", minutes);
        }
        else
        {
            if (hours || days) sink.put(" and ");
            sink.formattedWrite("%d %s", minutes, plurality(minutes, "minute", "minutes"));
        }
    }

    if (!minutes && !hours && !days)
    {
        static if (abbreviate)
        {
            sink.formattedWrite("%ds", seconds);
        }
        else
        {
            sink.formattedWrite("%d %s", seconds, plurality(seconds, "second", "seconds"));
        }
    }
}

///
unittest
{
    import core.time;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(64);  // workaround for formattedWrite < 2.076

    {
        immutable dur = 0.seconds;
        sink.timeSince(dur);
        assert((sink.data == "0 seconds"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "0s"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3_141_519_265.msecs;
        sink.timeSince(dur);
        assert((sink.data == "36 days, 8 hours and 38 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "36d 8h 38m"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3599.seconds;
        sink.timeSince(dur);
        assert((sink.data == "59 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "59m"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3.days + 35.minutes;
        sink.timeSince(dur);
        assert((sink.data == "3 days and 35 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "3d 35m"), sink.data);
        sink.clear();
    }
}


// timeSince
/++
 +  Express how much time has passed in a `Duration`, in natural (English) language.
 +
 +  Returns the result as a string.
 +
 +  Example:
 +  ---
 +  const then = Clock.currTime;
 +  Thread.sleep(1.seconds);
 +  const now = Clock.currTime;
 +
 +  const duration = (now - then);
 +  immutable inEnglish = timeSince(duration);
 +  ---
 +
 +  Params:
 +      abbreviate = Whether or not to abbreviate the output, using `h` instead
 +          of `hours`, `m` instead of `minutes`, etc.
 +      duration = A period of time.
 +
 +  Returns:
 +      A string with the passed duration expressed in natural English language.
 +/
string timeSince(Flag!"abbreviate" abbreviate = No.abbreviate)(const Duration duration) pure
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(50);
    sink.timeSince!abbreviate(duration);
    return sink.data;
}

///
unittest
{
    import core.time : seconds;

    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "9 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "9d 3h 16m"), abbrev);
    }

    {
        immutable dur = 3_620.seconds;  // 1 hour and 20 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 hour"), since);
        assert((abbrev == "1h"), abbrev);
    }

    {
        immutable dur = 30.seconds;  // 30 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "30 seconds"), since);
        assert((abbrev == "30s"), abbrev);
    }

    {
        immutable dur = 1.seconds;
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 second"), since);
        assert((abbrev == "1s"), abbrev);
    }
}


// stripSeparatedPrefix
/++
 +  Strips a prefix word from a string, optionally also stripping away some
 +  non-word characters (`:?! `).
 +
 +  This is to make a helper for stripping away bot prefixes, where such may be
 +  "`kameloso:`".
 +
 +  Example:
 +  ---
 +  string prefixed = "kameloso: sudo MODE +o #channel :user";
 +  string command = prefixed.stripSeparatedPrefix("kameloso");
 +  assert((command == "sudo MODE +o #channel :user"), command);
 +  ---
 +
 +  Params:
 +      demandSeparatingChars = Makes it a necessity that `line` is followed
 +          by one of the prefix letters `:?! `. If it isn't, the `line` string
 +          will be returned as is.
 +      line = String line prefixed with `prefix`, potentially including separating characters.
 +      prefix = Prefix to strip.
 +
 +  Returns:
 +      The passed line with the `prefix` sliced away.
 +/
string stripSeparatedPrefix(Flag!"demandSeparatingChars" demandSeparatingChars = Yes.demandSeparatingChars)
    (const string line, const string prefix) pure @nogc
in (prefix.length, "Tried to strip separated prefix but no prefix was given")
do
{
    import lu.string : beginsWithOneOf, nom, strippedLeft;

    enum separatingChars = ": !?";

    string slice = line.strippedLeft;  // mutable

    // the onus is on the caller that slice begins with prefix, else this will throw
    slice.nom!(Yes.decode)(prefix);

    static if (demandSeparatingChars)
    {
        // Return the whole line, a non-match, if there are no separating characters
        // (at least one of the chars in separatingChars
        if (!slice.beginsWithOneOf(separatingChars)) return line;
        slice = slice[1..$];
    }

    return slice.strippedLeft(separatingChars);
}

///
unittest
{
    immutable lorem = "say: lorem ipsum".stripSeparatedPrefix("say");
    assert((lorem == "lorem ipsum"), lorem);

    immutable notehello = "note!!!! zorael hello".stripSeparatedPrefix("note");
    assert((notehello == "zorael hello"), notehello);

    immutable sudoquit = "sudo quit :derp".stripSeparatedPrefix("sudo");
    assert((sudoquit == "quit :derp"), sudoquit);

    /*immutable eightball = "8ball predicate?".stripSeparatedPrefix("");
    assert((eightball == "8ball predicate?"), eightball);*/

    immutable isnotabot = "kamelosois a bot".stripSeparatedPrefix("kameloso");
    assert((isnotabot == "kamelosois a bot"), isnotabot);

    immutable isabot = "kamelosois a bot".stripSeparatedPrefix!(No.demandSeparatingChars)("kameloso");
    assert((isabot == "is a bot"), isabot);
}


// Tint
/++
 +  Provides an easy way to access the `*tint` members of our `KamelosoLogger`
 +  instance `logger`.
 +
 +  Currently you need visibility of three things to be able to tint text;
 +  *   `kameloso.common.logger`, as an instance of `kameloso.logger.KamelosoLogger`.
 +  *   `kameloso.logger.KamelosoLogger` itself, to cast `logger` to its subclass.
 +  *   `kameloso.common.settings`, to know whether we want monochrome output or not.
 +
 +  By placing this here where there is visibility of `logger` and `settings`,
 +  the caller need just import this.
 +
 +  Example:
 +  ---
 +  logger.logf("%s%s%s am a %1$s%4$s%3$s!", Tint.info, "I", Tint.log, "fish");
 +  ---
 +
 +  If `settings.monochrome` is true, `Tint.*` will just return an empty string.
 +  The monochrome-ness can be overridden with `Tint.*(false)`.
 +/
struct Tint
{
    version(Colours)
    {
        // opDispatch
        /++
         +  Provides the string that corresponds to the tint of the
         +  `std.experimental.logger.core.LogLevel` that was passed in string form
         +  as the `tint` `opDispatch` template parameter.
         +
         +  This saves us the boilerplate of copy/pasting one function for each
         +  `std.experimental.logger.core.LogLevel`.
         +/
        pragma(inline)
        static string opDispatch(string tint)(const bool monochrome = settings.monochrome)
        in ((logger !is null), "`Tint." ~ tint ~ "` was called with an uninitialised `logger`")
        {
            import kameloso.logger : KamelosoLogger;
            import std.traits : isSomeFunction;

            //enum tintfun = "(cast(KamelosoLogger)logger)." ~ tint ~ "tint";

            pragma(msg, __VERSION__);

            static if (__traits(hasMember, cast(KamelosoLogger)logger, tint ~ "tint") &&
                isSomeFunction!(mixin("(cast(KamelosoLogger)logger)." ~ tint ~ "tint")))
            {
                return monochrome ? string.init :
                    mixin("(cast(KamelosoLogger)logger)." ~ tint ~ "tint");
            }
            else
            {
                static assert(0, "Unknown tint `" ~ tint ~ "` passed to `Tint.opDispatch`");
            }
        }
    }
    else
    {
        /++
         +  Returns an empty string, since we're not versioned `Colours`.
         +/
        pragma(inline)
        static string log()
        {
            return string.init;
        }

        alias info = log;
        alias warning = log;
        alias error = log;
        alias fatal = log;
    }
}

///
unittest
{
    import kameloso.logger : KamelosoLogger;

    if (logger !is null)
    {
        KamelosoLogger kl = cast(KamelosoLogger)logger;
        assert(kl);

        version(Colours)
        {
            assert(Tint.log is kl.logtint);
            assert(Tint.info is kl.infotint);
            assert(Tint.warning is kl.warningtint);
            assert(Tint.error is kl.errortint);
            assert(Tint.fatal is kl.fataltint);
        }
        else
        {
            assert(Tint.log == string.init);
            assert(Tint.info == string.init);
            assert(Tint.warning == string.init);
            assert(Tint.error == string.init);
            assert(Tint.fatal == string.init);
        }
    }
}
