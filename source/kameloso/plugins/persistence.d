/++
 +  The Persistence service keeps track of all encountered users, gathering as much
 +  information about them as possible, then injects them into
 +  `dialect.defs.IRCEvent`s when information about them is incomplete.
 +
 +  This means that even if a service only refers to a user by nickname, things
 +  like his ident and address will be available to plugins as well, assuming
 +  the Persistence service had seen that previously.
 +
 +  It has no commands. It only does post-processing and doesn't handle
 +  `dialect.defs.IRCEvent`s in the normal sense at all.
 +
 +  It is mandatory for plugins to pick up user classes.
 +/
module kameloso.plugins.persistence;

version(WithPlugins):
version(WithPersistenceService):

private:

import kameloso.plugins.ircplugin;
import kameloso.plugins.common;
import dialect.defs;


// postprocess
/++
 +  Hijacks a reference to a `dialect.defs.IRCEvent` after parsing and
 +  fleshes out the `dialect.defs.IRCEvent.sender` and/or
 +  `dialect.defs.IRCEvent.target` fields, so that things like account names
 +  that are only sent sometimes carry over.
 +/
void postprocess(PersistenceService service, ref IRCEvent event)
{
    static void postprocessImpl(PersistenceService service, ref IRCEvent event, ref IRCUser user)
    {
        import std.algorithm.searching : canFind;

        if (!user.nickname.length) return;  // Ignore server events

        if ((service.state.server.daemon != IRCServer.Daemon.twitch) &&
            (user.nickname == service.state.client.nickname))
        {
            // On non-Twitch, ignore events originating from us
            return;
        }

        version(TwitchSupport)
        {
            if ((service.state.server.daemon == IRCServer.Daemon.twitch) &&
                (user.nickname == "jtv"))
            {
                return;
            }
        }

        /++
         +  Tries to apply any permanent class for a user in a channel, and if
         +  none available, tries to set one that seems to apply based on what
         +  the user looks like.
         +/
        static void applyClassifiers(PersistenceService service,
            const IRCEvent event, ref IRCUser user)
        {
            if (user.class_ == IRCUser.Class.admin)
            {
                // Do nothing, admin is permanent and program-wide
                return;
            }
            else if (!user.account.length || (user.account == "*"))
            {
                // No account means it's just a random
                user.class_ = IRCUser.Class.anyone;
            }
            else if (service.state.bot.admins.canFind(user.account))
            {
                // admin discovered
                user.class_ = IRCUser.Class.admin;
                return;
            }
            else if (event.channel.length && (event.channel in service.channelUsers) &&
                (user.account in service.channelUsers[event.channel]))
            {
                // Permanent class is defined, so apply it
                user.class_ = service.channelUsers[event.channel][user.account];
            }
            else
            {
                // All else failed, consider it a random
                user.class_ = IRCUser.Class.anyone;
            }

            // Record this channel as being the one the current class_ applies to.
            // That way we only have to look up a class_ when the channel has changed.
            service.userClassCurrentChannelCache[user.nickname] = event.channel;
        }

        auto stored = user.nickname in service.state.users;
        immutable foundNoStored = stored is null;

        if (foundNoStored)
        {
            service.state.users[user.nickname] = user;
            stored = user.nickname in service.state.users;
        }

        if (service.state.server.daemon != IRCServer.Daemon.twitch)
        {
            // Apply class here on events that carry new account information.

            with (IRCEvent.Type)
            switch (event.type)
            {
            case JOIN:
            case ACCOUNT:
            case RPL_WHOISACCOUNT:
            case RPL_WHOISUSER:
            case RPL_WHOISREGNICK:
                applyClassifiers(service, event, user);
                break;

            default:
                if (user.account.length && (user.account != "*") && !stored.account.length)
                {
                    // Unexpected event bearing new account
                    goto case RPL_WHOISACCOUNT;
                }
                break;
            }
        }

        import lu.meld : MeldingStrategy, meldInto;

        // Store initial class and restore after meld. The origin user.class_
        // can ever only be IRCUser.Class.unset UNLESS altered in the switch above.
        immutable preMeldClass = stored.class_;

        // Meld into the stored user, and store the union in the event
        // Skip if the current stored is just a direct copy of user
        if (!foundNoStored) user.meldInto!(MeldingStrategy.aggressive)(*stored);

        if (stored.class_ == IRCUser.Class.unset)
        {
            // The class was not changed, restore the previously saved one
            stored.class_ = preMeldClass;
        }

        if (service.state.server.daemon != IRCServer.Daemon.twitch)
        {
            if (event.type == IRCEvent.Type.RPL_ENDOFWHOIS)
            {
                // Record updated timestamp; this is the end of a WHOIS
                stored.updated = event.time;
            }
            else if (stored.account == "*")
            {
                // An account of "*" means the user logged out of services
                // It's not strictly true but consider him/her as unknown again.

                stored.account = string.init;
                stored.class_ = IRCUser.Class.anyone;
                stored.updated = 1L;  // To facilitate melding
                service.userClassCurrentChannelCache.remove(stored.nickname);
            }
        }

        version(TwitchSupport)
        {
            // Clear badges if it has the empty placeholder asterisk
            if ((service.state.server.daemon == IRCServer.Daemon.twitch) &&
                (stored.badges == "*"))
            {
                stored.badges = string.init;
            }
        }

        if (stored.class_ == IRCUser.Class.admin)
        {
            // Do nothing, admin is permanent and program-wide
        }
        else if ((service.state.server.daemon == IRCServer.Daemon.twitch) &&
            (stored.nickname == service.state.client.nickname))
        {
            stored.class_ = IRCUser.Class.admin;
        }
        else if (!event.channel.length || !service.state.bot.homeChannels.canFind(event.channel))
        {
            // Not a channel or not a home. Additionally not an admin nor us
            stored.class_ = IRCUser.Class.anyone;
        }
        else
        {
            const cachedChannel = stored.nickname in service.userClassCurrentChannelCache;

            if (!cachedChannel || (*cachedChannel != event.channel))
            {
                // User has no cached channel. Alternatively, user's cached channel
                // is different from this one; class likely differs.
                applyClassifiers(service, event, *stored);
            }
        }

        // Inject the modified user into the event
        user = *stored;
    }

    postprocessImpl(service, event, event.sender);
    postprocessImpl(service, event, event.target);
}


// onQuit
/++
 +  Removes a user's `dialect.defs.IRCUser` entry from the `users`
 +  associative array of the current `PersistenceService`'s
 +  `kameloso.plugins.common.IRCPluginState` upon them disconnecting.
 +
 +  Additionally from the nickname-chanel cache.
 +/
@(IRCEvent.Type.QUIT)
void onQuit(PersistenceService service, const IRCEvent event)
{
    service.state.users.remove(event.sender.nickname);
    service.userClassCurrentChannelCache.remove(event.sender.nickname);
}


// onNick
/++
 +  Updates the entry of someone in the `users` associative array of the current
 +  `PersistenceService`'s `kameloso.plugins.common.IRCPluginState` when they
 +  change nickname, to point to the new `dialect.defs.IRCUser`.
 +
 +  Removes the old entry.
 +/
@(IRCEvent.Type.NICK)
@(IRCEvent.Type.SELFNICK)
void onNick(PersistenceService service, const IRCEvent event)
{
    with (service.state)
    {
        if (const stored = event.sender.nickname in users)
        {
            users[event.target.nickname] = *stored;
            users[event.target.nickname].nickname = event.target.nickname;
            users.remove(event.sender.nickname);
        }
        /*else
        {
            // Logically this should never happen, as postprocess creates a user
            // if none already exists.
            users[event.target.nickname] = event.sender;
            users[event.target.nickname].nickname = event.target.nickname;
        }*/

        if (const channel = event.sender.nickname in service.userClassCurrentChannelCache)
        {
            service.userClassCurrentChannelCache[event.target.nickname] = *channel;
            service.userClassCurrentChannelCache.remove(event.sender.nickname);
        }
    }
}


// onEndOfMotd
/++
 +  Reloads classifier definitions from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(PersistenceService service)
{
    service.reloadClassifiersFromDisk();
}


// reload
/++
 +  Reloads the service, rehashing the user array and loading
 +  admin/whitelist/blacklist classifier definitions from disk.
 +/
void reload(PersistenceService service)
{
    service.state.users.rehash();
    service.reloadClassifiersFromDisk();
}


// periodically
/++
 +  Periodically rehashes the user array, allowing for optimised access.
 +
 +  This is normally done as part of user-awareness, but we're not mixing that
 +  in so we have to reinvent it.
 +/
void periodically(PersistenceService service, const long now)
{
    import std.datetime.systime : Clock;

    enum hoursBetweenRehashes = 3;

    service.state.users.rehash();
    service.state.nextPeriodical = now + (hoursBetweenRehashes * 3600);
}


// reloadClassifiersFromDisk
/++
 +  Reloads admin/whitelist/blacklist classifier definitions from disk.
 +
 +  Params:
 +      service = The current `PersistenceService`.
 +/
void reloadClassifiersFromDisk(PersistenceService service)
{
    import kameloso.common : logger;
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;
    json.reset();
    json.load(service.userFile);

    service.channelUsers.clear();

    import lu.conv : Enum;
    import std.range : only;

    foreach (class_; only(IRCUser.Class.operator, IRCUser.Class.whitelist, IRCUser.Class.blacklist))
    {
        immutable list = Enum!(IRCUser.Class).toString(class_);
        const listFromJSON = list in json;

        if (!listFromJSON)
        {
            json[list] = null;
            json[list].object = null;
        }

        try
        {
            foreach (immutable channel, const channelAccountJSON; listFromJSON.object)
            {
                foreach (immutable accountJSON; channelAccountJSON.array)
                {
                    if (channel !in service.channelUsers)
                    {
                        service.channelUsers[channel] = (IRCUser.Class[string]).init;
                    }

                    service.channelUsers[channel][accountJSON.str] = class_;
                }
            }
        }
        catch (JSONException e)
        {
            logger.warningf("JSON exception caught when populating %s: %s", list, e.msg);
            version(PrintStacktraces) logger.trace(e.toString);
        }
        catch (Exception e)
        {
            logger.warningf("Unhandled exception caught when populating %s: %s", list, e.msg);
            version(PrintStacktraces) logger.trace(e.toString);
        }
    }
}


// initResources
/++
 +  Reads, completes and saves the user classification JSON file, creating one
 +  if one doesn't exist. Removes any duplicate entries.
 +
 +  This ensures there will be a `"whitelist"` and `"blacklist"` array in it.
 +
 +  Throws: `kameloso.plugins.common.IRCPluginInitialisationException` on
 +      failure loading the `user.json` file.
 +/
void initResources(PersistenceService service)
{
    import lu.json : JSONStorage;
    import std.json : JSONException, JSONValue;

    JSONStorage json;
    json.reset();

    try
    {
        json.load(service.userFile);
    }
    catch (JSONException e)
    {
        import std.path : baseName;
        throw new IRCPluginInitialisationException(service.userFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    static auto deduplicate(JSONValue before)
    {
        import std.algorithm.iteration : filter, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        auto after = before
            .array
            .sort!((a,b) => a.str < b.str)
            .uniq
            .filter!((a) => a.str.length > 0)
            .array;

        return JSONValue(after);
    }

    /+
    unittest
    {
        auto users = JSONValue([ "foo", "bar", "baz", "bar", "foo" ]);
        assert((users.array.length == 5), users.array.length.text);

        users = deduplicated(users);
        assert((users == JSONValue([ "bar", "baz", "foo" ])), users.array.text);
    }+/

    import std.range : only;

    foreach (liststring; only("operator", "whitelist", "blacklist"))
    {
        if (liststring !in json)
        {
            json[liststring] = null;
            json[liststring].object = null;
        }
        else
        {
            try
            {
                foreach (immutable channel, ref channelAccountsJSON; json[liststring].object)
                {
                    channelAccountsJSON = deduplicate(json[liststring][channel]);
                }
            }
            catch (JSONException e)
            {
                import std.path : baseName;
                throw new IRCPluginInitialisationException(service.userFile.baseName ~ " may be malformed.");
            }
        }
    }

    // Force operator and whitelist to appear before blacklist in the .json
    static immutable order = [ "operator", "whitelist", "blacklist" ];
    json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.userFile, order);
}


public:


// PersistenceService
/++
 +  The Persistence service melds new `dialect.defs.IRCUser`s (from
 +  post-processing new `dialect.defs.IRCEvent`s) with old records of themselves.
 +
 +  Sometimes the only bit of information about a sender (or target) embedded in
 +  an `dialect.defs.IRCEvent` may be his/her nickname, even though the
 +  event before detailed everything, even including their account name. With
 +  this service we aim to complete such `dialect.defs.IRCUser` entries as
 +  the union of everything we know from previous events.
 +
 +  It only needs part of `kameloso.plugins.common.UserAwareness` for minimal
 +  bookkeeping, not the full package, so we only copy/paste the relevant bits
 +  to stay slim.
 +/
final class PersistenceService : IRCPlugin
{
private:
    /// File with user definitions.
    @Resource string userFile = "users.json";

    /// Associative array of permanent user classifications, per account and channel name.
    IRCUser.Class[string][string] channelUsers;

    /// Associative array of which channel the latest class lookup for an account related to.
    string[string] userClassCurrentChannelCache;

    mixin IRCPluginImpl;
}
