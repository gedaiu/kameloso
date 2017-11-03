module kameloso.common;

import kameloso.constants;

import std.experimental.logger;
import std.meta : allSatisfy;
import std.stdio;
import std.traits : isType;
import std.range : isOutputRange;
import std.typecons : Flag, No, Yes;


// logger
/++
 +  Instance of a KamelosoLogger, providing timestamped and coloured logging.
 +
 +  The member functions to use are log, trace, info, warning, error, and fatal.
 +  It is not thread-safe, so instantiate a thread-local Logger if threading.
 +/
Logger logger;


shared static this()
{
    logger = new KamelosoLogger(LogLevel.all);
}


@safe:


/++
 +  Aggregate of thread message types.
 +
 +  This is a way to make concurrency message passing easier. You could use
 +  string literals to differentiate between messages and then have big
 +  switches inside the catching function, but with these you can actually
 +  have separate functions for each.
 +/
struct ThreadMessage
{
    /// Concurrency message type asking for a to-server PONG event.
    struct Pong {}

    /// Concurrency message type asking for a to-server PING event.
    struct Ping {}

    /// Concurrency message type asking to verbosely send a line to the server.
    struct Sendline {}

    /// Concurrency message type asking to quietly send a line to the server.
    struct Quietline {}

    /// Concurrency message type asking to quit the server and the program.
    struct Quit {}

    /// Concurrency message type asking for WHOIS information on a user.
    struct Whois {}

    /// Concurrency message type asking for a plugin to shut down cleanly.
    struct Teardown {}

    /// Concurrency message type asking for current settings to be saved to disk.
    struct WriteConfig {}
}


/// UDA used for conveying "this field is not to be saved in configuration files"
struct Unconfigurable {}

/// UDA used for conveying "this string is an array with this token as separator"
struct Separator
{
    string token = ",";
}

/// UDA used to convey "this member should not be printed in clear text"
struct Hidden {}


// Settings
/++
 +  Aggregate struct containing runtime bot setting variables.
 +
 +  Kept inside one struct they're nicely gathered and easy to pass around.
 +/
struct Settings
{
    bool joinOnInvite = true;
    bool monochrome = false;
    bool randomNickColours = true;

    string notesFile = "notes.json";
    string quotesFile = "quotes.json";

    @Unconfigurable
    {
        @Hidden
        string configFile = "kameloso.conf";
    }
}


// isConfigurableVariable
/++
 +  Eponymous template bool of whether a variable can be configured via the
 +  functions in kameloso.config or not.
 +
 +  Currently it does not support static arrays.
 +/
template isConfigurableVariable(alias var)
{
    static if (!isType!var)
    {
        import std.traits : isSomeFunction;

        alias T = typeof(var);

        enum isConfigurableVariable = !isSomeFunction!T &&
            !__traits(isTemplate, T) &&
            !__traits(isAssociativeArray, T) &&
            !__traits(isStaticArray, T);
    }
    else
    {
        // var is a type or something that cannot be called typeof on
        enum isConfigurableVariable = false;
    }
}

unittest
{
    int i;
    char[] c;
    char[8] c2;
    struct S {}
    class C {}
    enum E { foo }
    E e;

    static assert(isConfigurableVariable!i);
    static assert(isConfigurableVariable!c);
    static assert(!isConfigurableVariable!c2); // should static arrays pass?
    static assert(!isConfigurableVariable!S);
    static assert(!isConfigurableVariable!C);
    static assert(!isConfigurableVariable!E);
    static assert(isConfigurableVariable!e);
}


// printObjects
/++
 +  Prints out struct objects, with all their printable members with all their
 +  printable values.
 +
 +  This is not only convenient for deubgging but also usable to print out
 +  current settings and state, where such is kept in structs.
 +
 +  Params:
 +      thing = The struct object to enumerate.
 +/
void printObjects(Things...)(Things things) @trusted
{
    // writeln trusts lockingTextWriter so we will too.

    version(Colours)
    {
        formatObjectsColoured(stdout.lockingTextWriter, things);
    }
    else
    {
        formatObjectsMonochrome(stdout.lockingTextWriter, things);
    }
}


// printObject
/// ditto
void printObject(Thing)(Thing thing)
{
    printObjects(thing);
}


// formatObjectsColoured
/++
 +  Formats a struct object, with all its printable members with all their
 +  printable values. Formats in colour.
 +
 +  Don't use this directly, instead use printObjects(Things...).
 +
 +  Params:
 +      thing = The struct object to enumerate.
 +/
void formatObjectsColoured(Sink, Things...)(auto ref Sink sink, Things things)
{
    import kameloso.config : longestMemberName;

    import std.format : format, formattedWrite;
    import std.traits : hasUDA, isSomeFunction;
    import std.typecons : Unqual;

    // workaround formattedWrite taking Appender by value
    version(LDC) sink.put(string.init);

    enum entryPadding = longestMemberName!Things.length;

    with (BashForeground)
    foreach (thing; things)
    {
        sink.formattedWrite("%s-- %s\n",
            colourise(white),
            Unqual!(typeof(thing)).stringof);

        foreach (immutable i, member; thing.tupleof)
        {
            static if (!isType!member &&
                       isConfigurableVariable!member &&
                       !hasUDA!(thing.tupleof[i], Hidden) &&
                       !hasUDA!(thing.tupleof[i], Unconfigurable))
            {
                alias MemberType = Unqual!(typeof(member));
                enum typestring = MemberType.stringof;
                enum memberstring = __traits(identifier, thing.tupleof[i]);

                static if (is(MemberType : string))
                {
                    enum stringPattern = "%s%9s %s%-*s %s\"%s\"%s(%d)\n";
                    sink.formattedWrite(stringPattern,
                        colourise(cyan), typestring,
                        colourise(white), (entryPadding + 2),
                        memberstring,
                        colourise(lightgreen), member,
                        colourise(darkgrey), member.length);
                }
                else
                {
                    enum normalPattern = "%s%9s %s%-*s  %s%s\n";
                    sink.formattedWrite(normalPattern,
                        colourise(cyan), typestring,
                        colourise(white), (entryPadding + 2),
                        memberstring,
                        colourise(lightgreen), member);
                }
            }
        }

        sink.put(colourise(default_));
        sink.put('\n');
    }
}

unittest
{
    import std.array : Appender;
    import std.string : indexOf;

    struct StructName
    {
        int int_ = 12345;
        string string_ = "foo";
        bool bool_ = true;
        float float_ = 3.14f;
        double double_ = 99.9;
    }

    StructName s;
    Appender!string sink;

    sink.reserve(256);  // ~239
    sink.formatObjectsColoured(s);

    assert((sink.data.length > 12), "Empty sink after coloured fill");

    assert(sink.data.indexOf("-- StructName") != -1);
    assert(sink.data.indexOf("int_") != -1);
    assert(sink.data.indexOf("12345") != -1);

    assert(sink.data.indexOf("string_") != -1);
    assert(sink.data.indexOf(`"foo"`) != -1);

    assert(sink.data.indexOf("bool_") != -1);
    assert(sink.data.indexOf("true") != -1);

    assert(sink.data.indexOf("float_") != -1);
    assert(sink.data.indexOf("3.14") != -1);

    assert(sink.data.indexOf("double_") != -1);
    assert(sink.data.indexOf("99.9") != -1);
}


// formatObjectsMonochrome
/++
 +  Formats a struct object, with all its printable members with all their
 +  printable values. Formats without adding colours.
 +
 +  Don't use this directly, instead use printObjects(Things...).
 +
 +  Params:
 +      thing = The struct object to enumerate.
 +/
void formatObjectsMonochrome(Sink, Things...)(auto ref Sink sink, Things things)
{
    import kameloso.config : longestMemberName;

    import std.format   : format, formattedWrite;
    import std.traits   : hasUDA, isSomeFunction;
    import std.typecons : Unqual;

    // workaround formattedWrite taking Appender by value
    version(LDC) sink.put(string.init);

    enum entryPadding = longestMemberName!Things.length;

    foreach (thing; things)
    {
        sink.formattedWrite("-- %s\n", Unqual!(typeof(thing)).stringof);

        foreach (immutable i, member; thing.tupleof)
        {
            static if (!isType!member &&
                       isConfigurableVariable!member &&
                       !hasUDA!(thing.tupleof[i], Hidden) &&
                       !hasUDA!(thing.tupleof[i], Unconfigurable))
            {
                alias MemberType = Unqual!(typeof(member));
                enum typestring = MemberType.stringof;
                enum memberstring = __traits(identifier, thing.tupleof[i]);

                static if (is(MemberType : string))
                {
                    enum stringPattern = "%9s %-*s \"%s\"(%d)\n";
                    sink.formattedWrite(stringPattern, typestring,
                        (entryPadding + 2), memberstring,
                        member, member.length);
                }
                else
                {
                    enum normalPattern = "%9s %-*s  %s\n";
                    sink.formattedWrite(normalPattern, typestring,
                        (entryPadding + 2), memberstring, member);
                }
            }
        }

        sink.put('\n');
    }
}

unittest
{
    import std.array : Appender;

    struct StructName
    {
        int i = 12345;
        string s = "foo";
        bool b = true;
        float f = 3.14f;
        double d = 99.9;
    }

    StructName s;
    Appender!string sink;

    sink.reserve(128);  // ~119
    sink.formatObjectsMonochrome(s);

    assert((sink.data.length > 12), "Empty sink after monochrome fill");
    assert(sink.data ==
`-- StructName
      int i    12345
   string s   "foo"(3)
     bool b    true
    float f    3.14
   double d    99.9

`, "\n" ~ sink.data);
}


// longestMemberName
/++
 +  Gets the name of the longest member in a struct.
 +
 +  This is used for formatting configuration files, so that columns line up.
 +
 +  Params:
 +      T = the struct type to inspect for member name lengths.
 +/
template longestMemberName(Things...)
{
    enum longestMemberName = ()
    {
        import std.traits : hasUDA;

        string longest;

        foreach (T; Things)
        {
            foreach (name; __traits(allMembers, T))
            {
                static if (!isType!(__traits(getMember, T, name)) &&
                           isConfigurableVariable!(__traits(getMember, T, name)) &&
                           !hasUDA!(__traits(getMember, T, name), Hidden))
                {
                    if (name.length > longest.length)
                    {
                        longest = name;
                    }
                }
            }
        }

        return longest;
    }();
}

unittest
{
    struct Foo
    {
        string veryLongName;
        int i;
    }

    struct Bar
    {
        string evenLongerName;
        float f;
    }

    assert(longestMemberName!Foo == "veryLongName");
    assert(longestMemberName!Bar == "evenLongerName");
    assert(longestMemberName!(Foo, Bar) == "evenLongerName");
}


// isOfAssignableType
/++
 +  Eponymous template bool of whether a variable is "assignable"; if it is
 +  an lvalue that isn't protected from being written to.
 +/
template isOfAssignableType(T)
if (isType!T)
{
    import std.traits : isSomeFunction;

    enum isOfAssignableType = isType!T &&
        !isSomeFunction!T &&
        !is(T == const) &&
        !is(T == immutable);
}


/// Ditto
enum isOfAssignableType(alias symbol) = isType!symbol && is(symbol == enum);

unittest
{
    struct Foo
    {
        string bar, baz;
    }

    class Bar
    {
        int i;
    }

    void boo(int i) {}

    enum Baz { abc, def, ghi }
    Baz baz;

    assert(isOfAssignableType!int);
    assert(!isOfAssignableType!(const int));
    assert(!isOfAssignableType!(immutable int));
    assert(isOfAssignableType!(string[]));
    assert(isOfAssignableType!Foo);
    assert(isOfAssignableType!Bar);
    assert(!isOfAssignableType!boo);  // room for improvement: @property
    assert(isOfAssignableType!Baz);
    assert(!isOfAssignableType!baz);
}


// meldInto
/++
 +  Takes two structs and melds them together, making the members a union of
 +  the two.
 +
 +  It only overwrites members that are typeof(member).init, so only unset
 +  members get their values overwritten by the melding struct. Supply a
 +  template parameter Yes.overwrite to make it overwrite if the melding
 +  struct's member is not typeof(member).init.
 +
 +  Params:
 +      overwrite = flag denoting whether the second object should overwrite
 +                  set values in the receiving object.
 +      meldThis = struct to meld (sender).
 +      intoThis = struct to meld (receiver).
 +/
void meldInto(Flag!"overwrite" overwrite = No.overwrite, Thing)
    (Thing meldThis, ref Thing intoThis)
{
    foreach (immutable i, ref member; intoThis.tupleof)
    {
        static if (!isType!member)
        {
            alias MemberType = typeof(member);

            static if (is(MemberType == struct) || is(MemberType == class))
            {
                // Recurse
                meldThis.tupleof[i].meldInto(member);
            }
            else static if (isOfAssignableType!MemberType)
            {
                static if (overwrite)
                {
                    static if (is(MemberType == float))
                    {
                        import std.math : isNaN;

                        if (!meldThis.tupleof[i].isNaN)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else
                    {
                        if (meldThis.tupleof[i] != MemberType.init)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                }
                else
                {
                    static if (is(MemberType == float))
                    {
                        import std.math : isNaN;

                        if (member.isNaN)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else
                    {
                        if ((member == MemberType.init) ||
                            (member == Thing.init.tupleof[i]))
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                }
            }
        }
    }
}

unittest
{
    import std.conv : to;

    struct Foo
    {
        string abc;
        string def;
        int i;
        float f;
    }

    Foo f1; // = new Foo;
    f1.abc = "ABC";
    f1.def = "DEF";

    Foo f2; // = new Foo;
    f2.abc = "this won't get copied";
    f2.def = "neither will this";
    f2.i = 42;
    f2.f = 3.14f;

    f2.meldInto(f1);

    with (f1)
    {
        assert((abc == "ABC"), abc);
        assert((def == "DEF"), def);
        assert((i == 42), i.to!string);
        assert((f == 3.14f), f.to!string);
    }

    Foo f3; // new Foo;
    f3.abc = "abc";
    f3.def = "def";
    f3.i = 100_135;
    f3.f = 99.9f;

    Foo f4; // new Foo;
    f4.abc = "OVERWRITTEN";
    f4.def = "OVERWRITTEN TOO";
    f4.i = 0;
    f4.f = 0.1f;

    f4.meldInto!(Yes.overwrite)(f3);

    with (f3)
    {
        assert((abc == "OVERWRITTEN"), abc);
        assert((def == "OVERWRITTEN TOO"), def);
        assert((i == 100_135), i.to!string); // 0 is int.init
        assert((f == 0.1f), f.to!string);
    }
}


// scopeguard
/++
 +  Generates a string mixin of scopeguards. This is a convenience function
 +  to automate basic scope(exit|success|failure) messages, as well as an
 +  optional entry message. Which scope to guard is passed by ORing the states.
 +
 +  Params:
 +      states = Bitmsask of which states to guard, see the enum in kameloso.constants.
 +      scopeName = Optional scope name to print. Otherwise the current function
 +                  name will be used.
 +
 +  Returns:
 +      One or more scopeguards in string form. Mix them in to use.
 +/
string scopeguard(ubyte states = exit, string scopeName = string.init)
{
    import std.array : Appender;
    Appender!string app;

    string scopeString(const string state)
    {
        import std.string : format, toLower;

        if (scopeName.length)
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    logger.info("[%2$s] %3$s");
                }
            }.format(state.toLower, state, scopeName);
        }
        else
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    import std.string : indexOf;
                    enum __%2$sdotPos  = __FUNCTION__.indexOf('.');
                    enum __%2$sfunName = __FUNCTION__[(__%2$sdotPos+1)..$];
                    logger.infof("[%%s %2$s", __%2$sfunName);
                }
            }.format(state.toLower, state);
        }
    }

    string entryString(const string state)
    {
        import std.string : format, toLower;

        if (scopeName.length)
        {
            return
            q{
                logger.info("[%s] %s");
            }.format(scopeName, state);
        }
        else
        {
            return
            q{
                import std.string : indexOf;
                enum __%1$sdotPos  = __FUNCTION__.indexOf('.');
                enum __%1$sfunName = __FUNCTION__[(__%1$sdotPos+1)..$];
                logger.infof("[%%s %1$s", __%1$sfunName);
            }.format(state);
        }
    }

    if (states & entry)   app.put(entryString("entry"));
    if (states & exit)    app.put(scopeString("exit"));
    if (states & success) app.put(scopeString("success"));
    if (states & failure) app.put(scopeString("FAILURE"));

    return app.data;
}


/// Bool of whether a type is a colour code enum
enum isAColourCode(T) = is(T : BashForeground) || is(T : BashBackground) ||
                        is(T : BashFormat) || is(T : BashReset);


// colourise
/++
 +  Takes a mix of a BashForeground, a BashBackground, a BashFormat and/or a
 +  BashReset and composes them into a colour code token.
 +
 +  This function creates an appender and fills it with the return value of
 +  colourise(Sink, Codes...).
 +
 +  Params:
 +      codes = a variadic list of codes.
 +
 +  Returns:
 +      A Bash code sequence of the passed codes.
 +/
version(Colours)
string colourise(Codes...)(Codes codes)
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(16);

    sink.colourise(codes);
    return sink.data;
}
else
/// Dummy colourise for when version != Colours
string colourise(Codes...)(Codes codes)
{
    return string.init;
}


// colourise
/++
 +  Takes a mix of a BashForeground, a BashBackground, a BashFormat and/or a
 +  BashReset and composes them into a colour code token.
 +
 +  This is the composing function that fills its result into a sink.
 +
 +  Params:
 +      codes = a variadic list of codes.
 +
 +  Returns:
 +      A Bash code sequence of the passed codes.
 +/
version(Colours)
void colourise(Sink, Codes...)(auto ref Sink sink, Codes codes)
if (isOutputRange!(Sink,string) && Codes.length && allSatisfy!(isAColourCode, Codes))
{
    sink.put(BashColourToken);
    sink.put('[');

    uint numCodes;

    foreach (const code; codes)
    {
        if (++numCodes > 1) sink.put(';');

        sink.put(cast(string)code);
    }

    sink.put('m');
}


// KamelosoLogger
/++
 +  Modified Logger to print timestamped and coloured logging messages.
 +/
final class KamelosoLogger : Logger
{
    import std.concurrency : Tid;
    import std.datetime;
    import std.format : formattedWrite;
    import std.array : Appender;

    // Appender sink to fill with content and print in one go
    //Appender!(char[]) sink;

    this(LogLevel lv) @safe
    {
        super(lv);

        /*static if (__traits(hasMember, sink, "reserve"))
        {
            sink.reserve(512);
        }*/
    }

    /// This override is needed or it won't compile
    override void writeLogMsg(ref LogEntry payload) const {}

    /// Outputs the head of a logger message
    protected void beginLogMsg(Sink)(auto ref Sink sink,
        string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) @safe
    {
        version(Colours)
        {
            sink.colourise(BashForeground.white);
        }

        sink.formattedWrite("[%s] ", (cast(DateTime)timestamp)
            .timeOfDay
            .toString());

        version(Colours)
        with (LogLevel)
        switch (logLevel)
        {
        case trace:
            sink.colourise(BashForeground.default_);
            break;

        case info:
            sink.colourise(BashForeground.lightgreen);
            break;

        case warning:
            sink.colourise(BashForeground.lightred);
            break;

        case error:
            sink.colourise(BashForeground.red);
            break;

        case fatal:
            sink.colourise(BashForeground.red, BashFormat.blink);
            break;

        default:
            sink.colourise(BashForeground.white);
            break;
        }
    }

    /// ditto
    override protected void beginLogMsg(string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) @trusted
    {
        return beginLogMsg(stdout.lockingTextWriter, file, line, funcName,
            prettyFuncName, moduleName, logLevel, threadId, timestamp, logger);
    }

    /// Outputs the message part of a logger message; the content
    protected void logMsgPart(Sink)(auto ref Sink sink, const(char)[] msg) @safe
    {
        sink.put(msg);
    }

    /// ditto
    override protected void logMsgPart(const(char)[] msg) @trusted
    {
        if (!msg.length) return;

        return logMsgPart(stdout.lockingTextWriter, msg);
    }

    /// Outputs the tail of a logger message
    protected void finishLogMsg(Sink)(auto ref Sink sink) @safe
    {
        version(Colours)
        {
            // Reset.blink in case a fatal message was thrown
            sink.colourise(BashForeground.default_, BashReset.blink);
        }

        static if (__traits(hasMember, sink, "data"))
        {
            writeln(sink.data);
            sink.clear();
        }
        else
        {
            sink.put('\n');
        }
    }

    /// ditto
    override protected void finishLogMsg() @trusted
    {
        return finishLogMsg(stdout.lockingTextWriter);
    }
}

unittest
{
    Logger log_ = new KamelosoLogger(LogLevel.all);

    log_.log("log: log");
    log_.info("log: info");
    log_.warning("log: warning");
    log_.error("log: error");
    // log_.fatal("log: FATAL");  // crashes the program
    log_.trace("log: trace");
}
