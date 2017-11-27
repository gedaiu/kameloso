module kameloso.plugins.ctcp;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : ThreadMessage;
import kameloso.constants : IRCControlCharacter;

import std.stdio;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

// onCTCPs
/++
 +  Handle CTCP requests.
 +
 +  This is a catch-all function handling 5/6 CTCP requests we support, instead
 +  of having five different functions each dealing with one. Either design
 +  works; both end up with a switch.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CTCP_VERSION)
@(IRCEvent.Type.CTCP_FINGER)
@(IRCEvent.Type.CTCP_SOURCE)
@(IRCEvent.Type.CTCP_PING)
@(IRCEvent.Type.CTCP_TIME)
@(IRCEvent.Type.CTCP_USERINFO)
void onCTCPs(const IRCEvent event)
{
    import kameloso.common : KamelosoInfo;
    import std.concurrency : send;
    import std.format : format;

    /// https://modern.ircdocs.horse/ctcp.html

    string line;

    with (state)
    with (IRCEvent.Type)
    switch (event.type)
    {
    case CTCP_VERSION:
        /*  This metadata query is used to return the name and version of the
            client software in use. There is no specified format for the version
            string.

            VERSION is universally implemented. Clients MUST implement this CTCP message.

            Example:
            Query:     VERSION
            Response:  VERSION WeeChat 1.5-rc2 (git: v1.5-rc2-1-gc1441b1) (Apr 25 2016)
         */

        line = "VERSION kameloso:%s:linux".format(cast(string)KamelosoInfo.version_);
        break;

    case CTCP_FINGER:
        /*  This metadata query returns miscellaneous info about the user,
            typically the same information that’s held in their realname field.
            However, some implementations return the client name and version instead.

            FINGER is widely implemented, but largely obsolete. Clients MAY
            implement this CTCP message.

            Example:
            Query:     FINGER
            Response:  FINGER WeeChat 1.5
         */
        line = "FINGER kameloso " ~ cast(string)KamelosoInfo.version_;
        break;

    case CTCP_SOURCE:
        /*  This metadata query is used to return the location of the source
            code for the client.

            SOURCE is rarely implemented. Clients MAY implement this CTCP message.

            Example:
            Query:     SOURCE
            Response:  SOURCE https://weechat.org/download
         */
        line = "SOURCE " ~ cast(string)KamelosoInfo.source;
        break;

    case CTCP_PING:
        /*  This extended query is used to confirm reachability with other
            clients and to check latency. When receiving a CTCP PING, the reply
            must contain exactly the same parameters as the original query.

            PING is universally implemented. Clients MUST implement this CTCP message.

            Example:
            Query:     PING 1473523721 662865
            Response:  PING 1473523721 662865

            Query:     PING foo bar baz
            Response:  PING foo bar baz
         */
        line = "PING " ~ event.content;
        break;

    case CTCP_TIME:
        import std.datetime : Clock;
        /*  This extended query is used to return the client’s local time in an
            unspecified human-readable format. We recommend ISO 8601 format, but
            raw ctime() output appears to be the most common in practice.

            New implementations SHOULD default to UTC time for privacy reasons.

            TIME is almost universally implemented. Clients SHOULD implement
            this CTCP message.

            Example:
            Query:     TIME
            Response:  TIME 2016-09-26T00:45:36Z
         */
        line = "TIME " ~ Clock.currTime.toUTC().toString();
        break;

    /* case CTCP_CLIENTINFO:
        // more complex; handled in own function
        break; */

    case CTCP_USERINFO:
        /*  This metadata query returns miscellaneous info about the user,
            typically the same information that’s held in their realname field.

            However, some implementations return <nickname> (<realname>) instead.

            USERINFO is widely implemented, but largely obsolete. Clients MAY
            implement this CTCP message.

            Example:
            Query:     USERINFO
            Response:  USERINFO fred (Fred Foobar)
         */
        line = "USERINFO %s (%s)".format(bot.nickname, bot.user);
        break;

    case CTCP_DCC:
        /*  DCC (Direct Client-to-Client) is used to setup and control
            connections that go directly between clients, bypassing the IRC
            server. This is typically used for features that require a large
            amount of traffic between clients or simply wish to bypass the
            server itself such as file transfer, direct chat, and voice messages.

            Properly implementing the various DCC types requires a document all
            of its own, and are not described here.

            DCC is widely implemented. Clients MAY implement this CTCP message.
         */
        break;

    case CTCP_LAG:
        // g-line fishing? do nothing?
        break;

    default:
        assert(0);
    }

    immutable target = event.sender.isServer ?
        event.sender.address: event.sender.nickname;

    with (IRCControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ line ~ ctcp).format(target));
}


// onCTCPClientinfo
/++
 +  Sends a list of which CTCP events we understand.
 +
 +  This builds a string of the names of all IRCEvent.Types that begin
 +  with CTCP_, at compile-time. As such, as long as we name any new
 +  such types CTCP_SOMETHING, this list will always be correct.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CTCP_CLIENTINFO)
void onCTCPClientinfo(const IRCEvent event)
{
    import std.concurrency : send;
    import std.format : format;

    /*  This metadata query returns a list of the CTCP messages that this
        client supports and implements. CLIENTINFO is widely implemented.

        Clients SHOULD implement this CTCP message.

        Example:
        Query:     CLIENTINFO
        Response:  CLIENTINFO ACTION DCC CLIENTINFO FINGER PING SOURCE TIME USERINFO VERSION
     */

    enum string allCTCPTypes = ()
    {
        import std.conv   : to;
        import std.string : stripRight;
        import std.traits : getSymbolsByUDA, getUDAs, isSomeFunction;

        string allTypes;

        foreach (fun; getSymbolsByUDA!(mixin(__MODULE__), IRCEvent.Type))
        {
            static if (isSomeFunction!(fun))
            {
                foreach (type; getUDAs!(fun, IRCEvent.Type))
                {
                    allTypes = allTypes ~ type.to!string[5..$] ~ " ";
                }
            }
        }

        return allTypes.stripRight();
    }();

    // Don't forget to add ACTION, it's handed elsewhere

    with (IRCControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "CLIENTINFO ACTION %s" ~ ctcp)
        .format(event.sender.nickname, allCTCPTypes));
}


mixin OnEventImpl;

public:


// CTCP
/++
 +  The CTCP plugin (client-to-client protocol) answers to special queries
 +  sometime made over the IRC protocol. These are generally of metadata about
 +  the client itself and its capbilities.
 +
 +  Information about these were gathered from the following sites:
 +      https://modern.ircdocs.horse/ctcp.html
 +      http://www.irchelp.org/protocol/ctcpspec.html
 +/
final class CTCPPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}
