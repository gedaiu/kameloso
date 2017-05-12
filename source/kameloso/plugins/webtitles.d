module kameloso.plugins.webtitles;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency : send, Tid;
import std.regex : ctRegex;
import std.stdio : writefln, writeln;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;

/// Cache buffer of recently looked-up URIs
//TitleLookup[string] cache;

/// Thread ID of the working thread that does the lookups
Tid workerThread;

/// Regex pattern to grep a web page title from the HTTP body
enum titlePattern = `<title>([^<]+)</title>`;

/// Regex engine to catch web titles
static titleRegex = ctRegex!(titlePattern, "i");

/// Regex pattern to match a URI, to see if one was pasted
enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;

/// Regex engine to catch URIs
static urlRegex = ctRegex!stephenhay;

/// Regex engine to match only the domain in a URI
enum domainPattern = `(?:https?://)?([^/ ]+)/?.*`;

/// Regex engine to catch domains
static domainRegex = ctRegex!domainPattern;


// TitleLookup
/++
 +  A record of a URI lookup.
 +
 +  This is both used to aggregate information about the lookup, as well as to add hysteresis
 +  to lookups, so we don't look the same one up over and over if they were pasted over and over.
 +/
struct TitleLookup
{
    import std.datetime : SysTime;

    string title;
    string domain;
    SysTime when;
}


// onMessage
/++
 +  Parses a message to see if the message contains an URI.
 +
 +  It uses a simple regex and exhaustively tries to match every URI it can detect.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("message")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)  // ?
@(PrivilegeLevel.friend)
@(Chainable.yes)
void onMessage(const IrcEvent event)
{
    import std.regex : matchAll;

    auto matches = event.content.matchAll(urlRegex);

    foreach (urlHit; matches)
    {
        if (!urlHit.length) continue;

        immutable url = urlHit[0];
        immutable target = (event.channel.length) ? event.channel : event.sender;

        writeln(url);

        workerThread.send(url, target);
    }
}


// streamUntil
/++
 +  Streams text from a supplied stream until the supplied regex engine finds a match.
 +
 +  This is used to stream a web page while applying a regex engine that looks for title tags.
 +  Since streamed content comes in unpredictable chunks, a Sink is used and gradually
 +  filled so that the entirety can be scanned if the title tag was split between two chunks.
 +
 +  Params:
 +      Stream_ = template stream type.
 +      Regex_ = template regex type.
 +      Sink = template sink type.
 +
 +      stream = a stream of a web page.
 +      engine = a regex matcher engine looking for title tags
 +      sink = a sink to fill with the streamed content, for later whole-body lookup
 +
 +  Returns:
 +      the first hit generated by the regex engine.
 +/
string streamUntil(Stream_, Regex_, Sink)
    (ref Stream_ stream, Regex_ engine, ref Sink sink)
{
    import std.regex : matchFirst;

    foreach (const data; stream)
    {
        /*writefln("Received %d bytes, total received %d from document legth %d",
            stream.front.length, rq.contentReceived, rq.contentLength);*/


        // matchFirst won't work directly on data, it's constrained to work with isSomeString
        // types and data is const(ubyte[]). We can get away without doing idup and just
        // casting to string here though, since sink.put below will copy
        const hits = (cast(string)data).matchFirst(engine);
        sink.put(data);

        if (hits.length)
        {
            /*writefln("Found title mid-stream after %s bytes", rq.contentReceived);
            writefln("Appender size is %d", sink.data.length);
            writefln("capacity is %d", sink.capacity);*/
            return hits[1];
        }
    }

    // No hits, but sink might be filled
    return string.init;
}


// lookupTitle
/++
 +  Look up a web page and try to find its title (by its <title> tag, if any).
 +
 +  Params:
 +      url = the web page address
 +/
TitleLookup lookupTitle(string url)
{
    import kameloso.stringutils : beginsWith;
    import requests     : Request;
    import std.array    : Appender, arrayReplace = replace;
    import std.datetime : Clock;
    import std.regex    : matchFirst;
    import std.string   : removechars, strip;

    TitleLookup lookup;
    Appender!string pageContent;
    pageContent.reserve(BufferSize.titleLookup);

    if (!url.beginsWith("http"))
    {
        writeln("NEEDS HTTP. DOES THIS EVER HAPPEN?");
        url = "http://" ~ url;
    }

    writeln("URL: ", url);

    Request rq;
    rq.useStreaming = true;
    rq.keepAlive = false;
    rq.bufferSize = BufferSize.titleLookup;

    auto rs = rq.get(url);
    auto stream = rs.receiveAsRange();

    writeln("code: ", rs.code);
    if (rs.code >= 400) return lookup;

    lookup.title = stream.streamUntil(titleRegex, pageContent);

    if (!pageContent.data.length)
    {
        writeln("Could not get content. Bad URL?");
        return lookup;
    }

    if (!lookup.title.length)
    {
        auto titleHits = pageContent.data.matchFirst(titleRegex);

        if (titleHits.length)
        {
            writeln("Found title in complete data (it was split)");
            lookup.title = titleHits[1];
        }
        else
        {
            writeln("No title...");
            return lookup;
        }
    }

    lookup.title = lookup.title
        .removechars("\r")
        .arrayReplace("\n", " ")
        .strip;

    auto domainHits = url.matchFirst(domainRegex);

    if (!domainHits.length) return lookup;

    lookup.domain = domainHits[1];
    lookup.when = Clock.currTime;

    return lookup;
}


// titleworker
/++
 +  Worker thread of the Webtitles plugin.
 +
 +  It sits and waits for concurrency messages of URLs to look up.
 +
 +  Params:
 +      sMainThread = a shared copy of the mainThread Tid, to which every outgoing messages
 +          will be sent.
 +/
void titleworker(shared Tid sMainThread)
{
    import core.time : seconds;
    import std.concurrency : OwnerTerminated, receive;
    import std.datetime : Clock;
    import std.variant : Variant;

    Tid mainThread = cast(Tid)sMainThread;

    /// Cache buffer of recently looked-up URIs
    TitleLookup[string] cache;
    bool halt;

    while (!halt)
    {
        receive(
            &onEvent,
            (string url, string target)
            {
                import std.format : format;

                TitleLookup lookup;
                const inCache = url in cache;

                if (inCache && ((Clock.currTime - inCache.when) < Timeout.titleCache.seconds))
                {
                    lookup = *inCache;
                }
                else
                {
                    try lookup = lookupTitle(url);
                    catch (Exception e)
                    {
                        writeln("Exception looking up a title: ", e.msg);
                    }
                }

                if (lookup == TitleLookup.init) return;

                cache[url] = lookup;

                if (lookup.domain.length)
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG %s :[%s] %s".format(target, lookup.domain, lookup.title));
                }
                else
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG %s :%s".format(target, lookup.title));
                }
            },
            (ThreadMessage.Teardown)
            {
                halt = true;
            },
            (OwnerTerminated o)
            {
                halt = true;
            },
            (Variant v)
            {
                writeln("Titleworker received Variant");
                writeln(v);
            }
        );
    }
}


// initialise
/++
 +  Initialises the Webtitles plugin. Spawns the titleworker thread.
 +/
void initialise()
{
    import std.concurrency : spawnLinked;

    const stateCopy = state;
    workerThread = spawnLinked(&titleworker, cast(shared)(stateCopy.mainThread));
}


// teardown
/++
 +  Deinitialises the Webtitles plugin. Shuts down the titleworker thread.
 +/
void teardown()
{
    workerThread.send(ThreadMessage.Teardown());
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;

public:


// Webtitles
/++
 +  The Webtitles plugin catches HTTP URI links in an IRC channel, connects to its server and
 +  and streams the web page itself, looking for the web page's title (in its <title> tags).
 +  This is then reported to the originating channel.
 +/
final class Webtitles : IrcPlugin
{
    mixin IrcPluginBasics;
}
