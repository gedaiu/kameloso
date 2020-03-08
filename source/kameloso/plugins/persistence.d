/++
 +  The Persistence service keeps track of all seen users, gathering as much
 +  information about them as possible, then injects them into
 +  `dialect.defs.IRCEvent`s when such information is not present.
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
    import std.range : only;

    foreach (user; only(&event.sender, &event.target))
    {
        if (!user.nickname.length) continue;

        /// Apply user class if we have one stored.
        void applyClassifiersDg(IRCUser* userToClassify)
        {
            import std.algorithm.searching : canFind;

            if (service.state.bot.admins.canFind(userToClassify.account))
            {
                // Admins are (currently) stored in an array IRCClient.admins
                userToClassify.class_ = IRCUser.Class.admin;
            }
            else
            {
                userToClassify.class_ = service.userClasses.get(userToClassify.account, IRCUser.Class.anyone);
            }
        }

        version(TwitchSupport)
        {
            if (service.state.server.daemon == IRCServer.Daemon.twitch)
            {
                auto stored = user.nickname in service.state.users;

                if (stored)
                {
                    import lu.meld : MeldingStrategy, meldInto;

                    // Twitch bot postprocess is run before this postprocess is.
                    // If it changes the user class, have it persist past our
                    // own melding here.

                    immutable origClass = user.class_;
                    (*user).meldInto!(MeldingStrategy.aggressive)(*stored);
                    if (origClass > stored.class_) stored.class_ = origClass;
                }
                else
                {
                    service.state.users[user.nickname] = *user;
                    stored = user.nickname in service.state.users;
                }

                if (stored.class_ == IRCUser.Class.unset)
                {
                    applyClassifiersDg(stored);
                }

                // Clear badges if it has the empty placeholder asterisk
                if (stored.badges == "*") stored.badges = string.init;

                *user = *stored;
                continue;
            }
        }

        if (auto stored = user.nickname in service.state.users)
        {
            with (IRCEvent.Type)
            switch (event.type)
            {
            case JOIN:
                if (user.account.length) goto case RPL_WHOISACCOUNT;
                break;

            case ACCOUNT:
                if (user.account == "*")
                {
                    // User logged out, reset updated so the user can be WHOISed again later
                    // A value of 0L won't be melded...
                    user.updated = 1L;
                }
                else
                {
                    goto case RPL_WHOISACCOUNT;
                }
                break;

            case RPL_WHOISACCOUNT:
            case RPL_WHOISUSER:
            case RPL_WHOISREGNICK:
                // Record WHOIS if we have new account information
                import std.datetime.systime : Clock;

                user.updated = Clock.currTime.toUnixTime;
                applyClassifiersDg(user);
                break;

            default:
                if (user.account.length && (user.account != "*") && !stored.account.length)
                {
                    goto case RPL_WHOISACCOUNT;
                }
                break;
            }

            import lu.meld : MeldingStrategy, meldInto;

            // Meld into the stored user, and store the union in the event
            (*user).meldInto!(MeldingStrategy.aggressive)(*stored);

            // An account of "*" means the user logged out of services
            if (user.account == "*") stored.account = string.init;

            // Inject the modified user into the event
            *user = *stored;
        }
        else if (event.type != IRCEvent.Type.QUIT)
        {
            // New entry
            if (user.account == "*") user.account = string.init;

            if (user.account.length)
            {
                // Initial user already has account info
                applyClassifiersDg(user);
            }

            service.state.users[user.nickname] = *user;
        }
    }
}


// onQuit
/++
 +  Removes a user's `dialect.defs.IRCUser` entry from the `users`
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
 +  Reloads the plugin, rehashing the user array and loading
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
void periodically(PersistenceService service)
{
    import std.datetime.systime : Clock;

    immutable now = Clock.currTime.toUnixTime;
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

    service.userClasses.clear();

    /*if (const adminFromJSON = "admin" in json)
    {
        try
        {
            foreach (const account; adminFromJSON.array)
            {
                service.userClasses[account.str] = IRCUser.Class.admin;
            }
        }
        catch (JSONException e)
        {
            logger.warning("JSON exception caught when populating admins: ", e.msg);
        }
        catch (Exception e)
        {
            logger.warning("Unhandled exception caught when populating admins: ", e.msg);
        }
    }*/

    if (const whitelistFromJSON = "whitelist" in json)
    {
        try
        {
            foreach (const account; whitelistFromJSON.array)
            {
                service.userClasses[account.str] = IRCUser.Class.whitelist;
            }
        }
        catch (JSONException e)
        {
            logger.warning("JSON exception caught when populating whitelist: ", e.msg);
        }
        catch (Exception e)
        {
            logger.warning("Unhandled exception caught when populating whitelist: ", e.msg);
        }
    }

    if (const blacklistFromJSON = "blacklist" in json)
    {
        try
        {
            foreach (const account; blacklistFromJSON.array)
            {
                service.userClasses[account.str] = IRCUser.Class.blacklist;
            }
        }
        catch (JSONException e)
        {
            logger.warning("JSON exception caught when populating blacklist: ", e.msg);
        }
        catch (Exception e)
        {
            logger.warning("Unhandled exception caught when populating blacklist: ", e.msg);
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

    /*if ("admin" !in json)
    {
        json["admin"] = null;
        json["admin"].array = null;
    }
    else
    {
        json["admin"] = deduplicate(json["admin"]);
    }*/

    if ("whitelist" !in json)
    {
        json["whitelist"] = null;
        json["whitelist"].array = null;
    }
    else
    {
        json["whitelist"] = deduplicate(json["whitelist"]);
    }

    if ("blacklist" !in json)
    {
        json["blacklist"] = null;
        json["blacklist"].array = null;
    }
    else
    {
        json["blacklist"] = deduplicate(json["blacklist"]);
    }

    // Force whitelist to appear before blacklist in the .json
    // Note: if we ever want support for admin definitions, we need to do something like:
    //static immutable order = [ "admin", "whitelist", "blacklist" ];
    //json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.userFile, order);
    json.save!(JSONStorage.KeyOrderStrategy.reverse)(service.userFile);
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

    /// Associative array of transient user classifications, per account and channel name.
    IRCUser.Class[string][string] transientUsers;

    /// Associative array of which channel the latest class lookup for an account related to.
    string[string] userClassCurrentChannelCache;

    mixin IRCPluginImpl;
}
