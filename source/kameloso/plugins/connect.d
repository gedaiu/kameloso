module kameloso.plugins.connect;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;
import kameloso.stringutils;

import std.concurrency : send;
import std.format : format;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;

bool serverPingedAtConnect;


@Label("onSelfjoin")
@(IrcEvent.Type.SELFJOIN)
void onSelfjoin(const IrcEvent event)
{
    if (!state.bot.channels.canFind(event.channel))
    {
        state.bot.channels ~= event.channel;
        updateBot();
    }
}


@Label("onSelfPart")
@(IrcEvent.Type.SELFPART)
void onSelfpart(const IrcEvent event)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : canFind;

    if (!state.bot.channels.canFind(event.channel))
    {
        writeln(Foreground.lightred, "Tried to remove a channel that wasn't there: ", event.channel);
        return;
    }

    state.bot.channels = state.bot.channels.remove(event.channel);
    updateBot();
}


// onNotice
/++
 +  Performs login and channel-joining when connecting.
 +
 +  This may be Freenode-specific and may need extension to work with other servers.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("notice")
@(IrcEvent.Type.NOTICE)
void onNotice(const IrcEvent event)
{
    if (state.bot.server.resolvedAddress.length) return;

    if (event.sender == "irc.quakenet.org")
    {
        state.bot.server.family = IrcServer.Family.quakenet;
    }

    if (event.content.beginsWith("***"))
    {
        state.bot.server.resolvedAddress = event.sender;
        updateBot();

        state.mainThread.send(ThreadMessage.Sendline(),
            "NICK %s".format(state.bot.nickname));
        state.mainThread.send(ThreadMessage.Sendline(),
            "USER %s * 8 : %s".format(state.bot.ident, state.bot.user));
    }
}


void joinChannels()
{
    import std.algorithm.iteration : joiner;

    with (state)
    {
        if (bot.homes.length)
        {
            bot.finishedLogin = true;
            updateBot();

            mainThread.send(ThreadMessage.Sendline(),
                "JOIN :%s".format(bot.homes.joiner(",")));
        }

        if (bot.channels.length)
        {
            mainThread.send(ThreadMessage.Sendline(),
                "JOIN :%s".format(bot.channels.joiner(",")));
        }
    }
}


// onWelcome
/++
 +  Gets the final nickname from a WELCOME event and propagates it via the main thread to
 +  all other plugins.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("welcome")
@(IrcEvent.Type.WELCOME)
void onWelcome(const IrcEvent event)
{
    if (state.bot.server.family == IrcServer.Family.quakenet)
    {
        // Only now does quakenet servers show what the resolved address is
        // Don't update bot now, do it below
        state.bot.server.resolvedAddress = event.sender;
    }

    state.bot.nickname = event.target;
    updateBot();
}


@Label("toconnecttype")
@(IrcEvent.Type.TOCONNECTTYPE)
void onToConnectType(const IrcEvent event)
{
    if (serverPingedAtConnect) return;

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(event.content, event.aux));
}


@Label("onping")
@(IrcEvent.Type.PING)
void onPing(const IrcEvent event)
{
    serverPingedAtConnect = true;
    state.mainThread.send(ThreadMessage.Pong(), event.sender);
}


// onEndOfMotd
/++
 +  Joins channels at the end of the MOTD, and tries to authenticate with NickServ if applicable.
 +
 +  This may be Freenode-specific and may need extension to work with other servers.
 +/
@Label("endofmotd")
@(IrcEvent.Type.RPL_ENDOFMOTD)
@(IrcEvent.Type.ERR_NOMOTD)
void onEndOfMotd()
{
    // FIXME: Deadlock if a password exists but there is no challenge
    // the fix is a timeout

    if (!state.bot.password.length)
    {
        joinChannels();
        return;
    }

    if (state.bot.attemptedLogin) return;

    if (state.bot.server.family == IrcServer.Family.quakenet)
    {
        state.mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG Q@CServe.quakenet.org :AUTH %s %s"
            .format(state.bot.login, state.bot.password));

        writeln(Foreground.white, "--> PRIVMSG Q@CServe.quakenet.org :AUTH ",
            state.bot.login, " hunter2");
    }
    else if (state.bot.nickname != state.bot.origNickname)
    {
        writeln(Foreground.lightred, "Probably need to AUTH manually");

        if (state.bot.server.family == IrcServer.Family.freenode)
        {
            state.mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s %s"
                .format(state.bot.login, state.bot.password));

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
                state.bot.login, " hunter2");
        }
        else
        {
            writeln(Foreground.lightred, "Would try to auth but the service " ~
                "wouldn't understand being passed both login and password...");
            writeln(Foreground.lightred, "DEBUG: trying anyway");

            // Remove me later

            state.mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s %s"
                .format(state.bot.login, state.bot.password));

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
                state.bot.login, " hunter2");
        }
    }
}


@Label("onchallenge")
@(IrcEvent.Type.AUTHCHALLENGE)
void onChallenge(const IrcEvent event)
{
    if (state.bot.attemptedLogin || state.bot.finishedLogin) return;

    if (state.bot.server.family != IrcServer.Family.quakenet)
    {
        state.bot.server.family = getFamily(event);
    }

    state.bot.attemptedLogin = true;
    updateBot();

    if (state.bot.server.family == IrcServer.Family.freenode)
    {
        state.mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG NickServ :IDENTIFY %s %s"
            .format(state.bot.login, state.bot.password));

        // fake it
        writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
            state.bot.login, " hunter2");
    }
    else
    {
        if (state.bot.nickname != state.bot.origNickname)
        {
            writeln(Foreground.lightred, "Nickname has changed, auth may not work");
        }

        state.mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG NickServ :IDENTIFY " ~ state.bot.password);

        // ditto
        writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY hunter2");
    }
}


@Label("onacceptance")
@(IrcEvent.Type.AUTHACCEPTANCE)
void onAcceptance()
{
    if (state.bot.finishedLogin) return;

    state.bot.finishedLogin = true;
    joinChannels();
}


IrcServer.Family getFamily(const IrcEvent event)
{
    with (IrcServer.Family)
    switch (event.address)
    {
    case "services.":
        writeln(Foreground.cyan, "FREENODE");
        return freenode;

    case "rizon.net":
        writeln(Foreground.cyan, "RIZON");
        return rizon;

    case "CServe.quakenet.org":
        writeln(Foreground.cyan, "QUAKENET");
        return quakenet;

    default:
        writeln(Foreground.lightred, "Could not tell what kind of server this is...");
        printObjects(event);
        return unset;
    }
}


// onNickInUse
/++
 +  Appends a single character to the end of the bot's nickname, and propagates the change
 +  via the main thread to all other plugins.
 +/
@Label("nickinuse")
@(IrcEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse()
{
    state.bot.nickname ~= altNickSign;
    updateBot();

    state.mainThread.send(ThreadMessage.Sendline(),
        "NICK %s".format(state.bot.nickname));
}


@Label("oninvite")
@(IrcEvent.Type.INVITE)
void onInvite(const IrcEvent event)
{
    if (!state.settings.joinOnInvite)
    {
        writeln(Foreground.lightcyan, "settings.joinOnInvite is false so not joining");
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(),
        "JOIN :" ~ event.channel);
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;

public:


// ConnectPlugin
/++
 +  A collection of functions and state needed to connect to an IRC server. This is mostly
 +  a matter of sending USER and NICK at the starting "handshake", but also incorporates
 +  logic to authenticate with NickServ.
 +/
final class ConnectPlugin : IrcPlugin
{
    mixin IrcPluginBasics;
}
