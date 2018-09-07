/++
 +  The Channel Queries service queries channels for information about them (in
 +  terms of topic and modes) as well as its list of participants. It does this
 +  shortly after having joined a channel, as a service to all other plugins,
 +  so they don't each try to do it theemselves.
 +
 +  It has no commands.
 +
 +  It is qualified as a service, so while it is not technically mandatory, it
 +  is highly recommended if you plan on mixing in
 +  `kameloso.plugins.common.ChannelAwareness` in your plugins.
 +/
module kameloso.plugins.chanqueries;

import kameloso.plugins.common;
import kameloso.ircdefs;

import std.typecons : Flag, No, Yes;

private:


// ChannelState
/++
 +  Different states which tracked channels can be in.
 +
 +  This is to keep track of which channels have been queried, which are
 +  currently queued for being queried, etc. It is checked via bitmask, so a
 +  channel can have several channel states.
 +/
enum ChannelState
{
    unset = 1 << 0,
    topicKnown = 1 << 1,
    queued = 1 << 2,
    queried = 1 << 3,
}


// onPing
/++
 +  Queries channels for information about them and their users.
 +
 +  Checks an internal list of channels once every `PING`, and if one we inhabit
 +  hasn't been queried, queries it.
 +/
@(IRCEvent.Type.PING)
void onPing(ChanQueriesService service)
{
    import core.thread : Fiber;

    if (service.state.bot.server.daemon == IRCServer.Daemon.twitch) return;
    if (service.querying) return;  // Try again next PING

    service.querying = true;  // "Lock"

    string[] querylist;

    foreach (immutable channelName, ref state; service.channelStates)
    {
        if ((state == ChannelState.queried) ||
            (state == ChannelState.queued))
        {
            // Either already queried or queued to be
            continue;
        }

        state |= ChannelState.queued;
        querylist ~= channelName;
    }

    if (!querylist.length) return;

    Fiber fiber;

    void fiberFn()
    {
        with (IRCEvent.Type)
        with (service.state)
        foreach (immutable channelName; querylist)
        {
            import kameloso.messaging : raw;
            import core.thread : Fiber;
            import std.string : representation;

            if (!(service.channelStates[channelName] & ChannelState.topicKnown))
            {
                raw!(Yes.quiet)(service.state, "TOPIC " ~ channelName);
                awaitingFibers[RPL_TOPIC] ~= fiber;
                awaitingFibers[RPL_NOTOPIC] ~= fiber;
                Fiber.yield();  // awaiting RPL_TOPIC or RPL_NOTOPIC
            }

            service.delayFiber(fiber, service.secondsBetween);
            Fiber.yield();  // delay

            raw!(Yes.quiet)(service.state, "WHO " ~ channelName);
            awaitingFibers[RPL_ENDOFWHO] ~= fiber;
            Fiber.yield();  // awaiting RPL_ENDOFWHO

            service.delayFiber(fiber, service.secondsBetween);
            Fiber.yield();  // delay

            raw!(Yes.quiet)(service.state, "MODE " ~ channelName);
            awaitingFibers[RPL_CHANNELMODEIS] ~= fiber;
            Fiber.yield();  // awaiting RPL_CHANNELMODEIS

            service.delayFiber(fiber, service.secondsBetween);
            Fiber.yield();  // delay

            foreach (immutable modechar; service.state.bot.server.aModes.representation)
            {
                import std.format : format;

                raw!(Yes.quiet)(service.state, "MODE %s +%c"
                    .format(channelName, cast(char)modechar));
                // Cannot await an event; there are too many types,
                // so just delay for twice the duration
                service.delayFiber(fiber, (service.secondsBetween * 2));
                Fiber.yield();
            }

            // Overwrite state with `ChannelState.queried`; `topicKnown` etc are
            // no longer relevant.
            service.channelStates[channelName] = ChannelState.queried;

            // The main loop will clean up the `awaitingFibers` array.
        }

        service.querying = false;  // "Unlock"
    }

    fiber = new Fiber(&fiberFn);
    fiber.call();
}


// onSelfjoin
/++
 +  Adds a channel we join to the internal `ChanQueriesService.channels` list of
 +  channels.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.any)
void onSelfjoin(ChanQueriesService service, const IRCEvent event)
{
    if (service.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    service.channelStates[event.channel] = ChannelState.unset;
}


// onSelfpart
/++
 +  Removes a channel we part from the internal `ChanQueriesService.channels`
 +  list of channels.
 +/
@(IRCEvent.Type.SELFPART)
@(IRCEvent.Type.SELFKICK)
@(ChannelPolicy.any)
void onSelfpart(ChanQueriesService service, const IRCEvent event)
{
    if (service.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    service.channelStates.remove(event.channel);
}


// onTopic
/++
 +  Registers that we have seen the topic of a channel.
 +
 +  We do this so we know not to query it later. Mostly cosmetic.
 +/
@(IRCEvent.Type.RPL_TOPIC)
@(ChannelPolicy.any)
void onTopic(ChanQueriesService service, const IRCEvent event)
{
    service.channelStates[event.channel] |= ChannelState.topicKnown;
}


public:


// ChanQueriesService
/++
 +  The Channel Queries service queries channels for information about them (in
 +  terms of topic and modes) as well as its list of participants. It does this
 +  shortly after having joined a channel, as a service to all other plugins,
 +  so they don't each try to do it theemselves.
 +/
final class ChanQueriesService : IRCPlugin
{
    /++
     +  Extra seconds delay between channel mode/user queries. Not delaying may
     +  cause kicks and disconnects if results are returned quickly.
     +/
    enum secondsBetween = 2;

    /++
     +  Short associative array of the channels the bot is in and which state(s)
     +  they are in.
     +/
    ubyte[string] channelStates;

    /// Whether or not a channel query Fiber is running.
    bool querying;

    mixin IRCPluginImpl;
}
