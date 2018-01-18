/++
 +  The Persistence service keeps track of all seen users, gathering as much
 +  information about them as possible, then injects them into
 +  `kameloso.ircdefs.IRCEvent`s where such information was not present.
 +
 +  This means that even if a service only refers to a user by nickname, things
 +  like his ident and address will be available to plugins as well, assuming
 +  the Persistence service had seen that previously.
 +
 +  It has no commands. It only does postprocessing and doesn't handle
 +  `kameloso.ircdefs.IRCEvent`s in the normal sense at all.
 +
 +  It is technically optional but it's very enriching for plugins, so it stays
 +  recommended.
 +/
module kameloso.plugins.persistence;

import kameloso.plugins.common;
import kameloso.ircdefs;

private:


// postprocess
/++
 +  Hijacks a reference to a `kameloso.ircdefs.IRCEvent` after parsing and
 +  fleshes out the `event.sender` and/or `event.target` fields, so that things
 +  like account names that are only sent sometimes carry over.
 +/
void postprocess(PersistenceService service, ref IRCEvent event)
{
    import kameloso.common : meldInto;
    import std.range : only;
    import std.typecons : Flag, No, Yes;

    if (event.type == IRCEvent.Type.QUIT) return;

    foreach (user; only(&event.sender, &event.target))
    {
        if (!user.nickname.length) continue;

        if (auto stored = user.nickname in service.state.users)
        {
            with (user)
            with (IRCEvent.Type)
            switch (event.type)
            {
            case JOIN:
                if (account.length) goto case ACCOUNT;
                break;

            case RPL_WHOISACCOUNT:
            case ACCOUNT:
                // Record WHOIS if we have new account information
                import std.datetime.systime : Clock;
                lastWhois = Clock.currTime.toUnixTime;
                break;

            default:
                if (account.length && (account != "*") && !stored.account.length)
                {
                    goto case ACCOUNT;
                }
                break;
            }

            // Meld into the stored user, and store the union in the event
            (*user).meldInto!(Yes.overwrite)(*stored);

            // An account of "*" means the user logged out of services
            if (user.account == "*") stored.account = string.init;

            // Inject the modified user into the event
            *user = *stored;
        }
        else
        {
            // New entry
            service.state.users[user.nickname] = *user;
        }
    }
}


// onQuit
/++
 +  Removes a user's `kameloso.ircdefs.IRCUser` entry from the `users`
 +  associative array of the current `PersistenceService`'s
 +  `kameloso.plugins.common.IRCPluginState` upon them disconnecting.
 +/
@(IRCEvent.Type.QUIT)
void onQuit(PersistenceService service, const IRCEvent event)
{
    service.state.users.remove(event.sender.nickname);
}


// onNick
/++
 +  Update the entry of someone in the `users` associative array of the current
 +  `PersistenceService`'s `kameloso.plugins.common.IRCPluginState` when they
 +  change nickname, point to the new `kameloso.ircdefs.IRCUser`.
 +
 +  Removes the old entry.
 +/
@(IRCEvent.Type.NICK)
void onNick(PersistenceService service, const IRCEvent event)
{
    with (service.state)
    {
        if (auto stored = event.sender.nickname in users)
        {
            users[event.target.nickname] = *stored;
            users[event.target.nickname].nickname = event.target.nickname;
            users.remove(event.sender.nickname);
        }
        else
        {
            users[event.target.nickname] = event.sender;
            users[event.target.nickname].nickname = event.target.nickname;
        }
    }
}


// onPing
/++
 +  Rehash the internal `users` associative array of the current
 +  `PersistenceService`'s `kameloso.plugins.common.IRCPluginState` once every
 +  `hoursBetweenRehashes` hours.
 +
 +  We ride the periodicity of `PING` to get a natural cadence without
 +  having to resort to timed `core.thread.Fiber`s.
 +
 +  The number of hours is so far hardcoded but can be made configurable if
 +  there's a use-case for it.
 +/
@(IRCEvent.Type.PING)
void onPing(PersistenceService service)
{
    import std.datetime.systime : Clock;

    const hour = Clock.currTime.hour;

    enum hoursBetweenRehashes = 12;  // also see UserAwareness

    with (service)
    {
        /// Once every few hours, rehash the `users` array.
        if ((hoursBetweenRehashes > 0) && (hour == rehashCounter))
        {
            rehashCounter = (rehashCounter + hoursBetweenRehashes) % 24;
            state.users.rehash();
        }
    }
}


public:


// PersistenceService
/++
 +  The Persistence service melds new `kameloso.ircdefs.IRCUser`s (from
 +  postprocessing new `kameloso.ircdefs.IRCEvent`s) with old records of
 +  themselves,
 +
 +  Sometimes the only bit of information about a sender (or target) embedded in
 +  an `kameloso.ircdefs.IRCEvent` may be his/her nickname, even though the
 +  event before detailed everything, even including their account name. With
 +  this service we aim to complete such `kameloso.ircdefs.IRCUser` entries with
 +  the union of everything we know from previous events.
 +
 +  It only needs part of `kameloso.plugins.common.UserAwareness` for minimal
 +  bookkeeping, not the full package, so we only copy/paste the relevant bits
 +  to stay slim.
 +/
final class PersistenceService : IRCPlugin
{
    mixin IRCPluginImpl;
}
