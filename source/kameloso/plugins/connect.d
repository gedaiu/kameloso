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
IRCPluginState state;

bool serverPingedAtConnect;


@Label("onSelfjoin")
@(IRCEvent.Type.SELFJOIN)
void onSelfjoin(const IRCEvent event)
{
    if (!state.bot.channels.canFind(event.channel))
    {
        state.bot.channels ~= event.channel;
        updateBot();
    }
}


@Label("onSelfPart")
@(IRCEvent.Type.SELFPART)
void onSelfpart(const IRCEvent event)
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
 +      event = the triggering IRCEvent.
 +/
@Label("notice")
@(IRCEvent.Type.NOTICE)
void onNotice(const IRCEvent event)
{
    if (state.bot.startedRegistering) return;

    state.bot.startedRegistering = true;

    if (event.sender == "(server)")
    {
        state.bot.server.family = IRCServer.Family.quakenet;
    }

    updateBot();

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
            bot.finishedAuth = true;
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
 +      event = the triggering IRCEvent.
 +/
@Label("welcome")
@(IRCEvent.Type.WELCOME)
void onWelcome(const IRCEvent event)
{
    state.bot.finishedRegistering = true;

    if (!state.bot.server.resolvedAddress.length)
    {
        state.bot.server.resolvedAddress = event.sender;
    }

    state.bot.nickname = event.target;
    updateBot();
}


@Label("toconnecttype")
@(IRCEvent.Type.TOCONNECTTYPE)
void onToConnectType(const IRCEvent event)
{
    if (serverPingedAtConnect) return;

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(event.content, event.aux));
}


@Label("onping")
@(IRCEvent.Type.PING)
void onPing(const IRCEvent event)
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
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd()
{
    // FIXME: Deadlock if a password exists but there is no challenge
    // the fix is a timeout

    with (state)
    {
        if (!bot.authPassword.length)
        {
            joinChannels();
            return;
        }

        if (bot.startedAuth) return;

        with (IRCServer.Family)
        switch (bot.server.family)
        {
        case quakenet:
            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG Q@CServe.quakenet.org :AUTH %s %s"
                .format(bot.auth, bot.authPassword));

            writeln(Foreground.white, "--> PRIVMSG Q@CServe.quakenet.org :AUTH ",
                bot.auth, " hunter2");

            break;

        case rizon:
        case freenode:
            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s %s"
                .format(bot.auth, bot.authPassword));

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
                bot.auth, " hunter2");

            break;

        default:
            /*writeln(Foreground.lightred, "Probably need to AUTH manually");

            writeln(Foreground.lightred, "Would try to auth but the service " ~
                "wouldn't understand being passed both login and password...");
            writeln(Foreground.lightred, "DEBUG: trying anyway");*/

            writeln(Foreground.lightred, "Unsure of what server family this is.");

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s %s"
                .format(bot.auth, bot.authPassword));

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
                bot.auth, " hunter2");

            break;
        }
    }
}


@Label("onchallenge")
@(IRCEvent.Type.AUTHCHALLENGE)
void onChallenge(const IRCEvent event)
{
    if (state.bot.startedAuth || state.bot.finishedAuth) return;

    state.bot.startedAuth = true;
    updateBot();

    if (state.bot.server.family == IRCServer.Family.freenode)
    {
        state.mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG NickServ :IDENTIFY %s %s"
            .format(state.bot.auth, state.bot.authPassword));

        // fake it
        writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
            state.bot.auth, " hunter2");
    }
    else
    {
        if (state.bot.nickname != state.bot.origNickname)
        {
            writeln(Foreground.lightred, "Nickname has changed, auth may not work");
        }

        state.mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG NickServ :IDENTIFY " ~ state.bot.authPassword);

        // ditto
        writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY hunter2");
    }
}


@Label("onacceptance")
@(IRCEvent.Type.AUTHACCEPTANCE)
void onAcceptance()
{
    if (state.bot.finishedAuth) return;

    state.bot.finishedAuth = true;
    joinChannels();
}


// onNickInUse
/++
 +  Appends a single character to the end of the bot's nickname, and propagates the change
 +  via the main thread to all other plugins.
 +/
@Label("nickinuse")
@(IRCEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse()
{
    state.bot.nickname ~= altNickSign;
    updateBot();

    state.mainThread.send(ThreadMessage.Sendline(),
        "NICK %s".format(state.bot.nickname));
}


@Label("oninvite")
@(IRCEvent.Type.INVITE)
void onInvite(const IRCEvent event)
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
final class ConnectPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}
