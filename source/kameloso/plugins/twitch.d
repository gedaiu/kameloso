module kameloso.plugins.twitch;

import kameloso.plugins.common;
import kameloso.ircstructs;

import std.stdio;

private:

struct TwitchSettings
{
    bool twitchColours = true;
}

@Settings TwitchSettings twitchSettings;

IRCPluginState state;

/++
 +  FIXME
 +/
void postprocess(ref IRCEvent event)
{
    import std.algorithm.searching : endsWith;

    if (!state.bot.server.address.endsWith(".twitch.tv")) return;

    parseTwitchTags(event);

    if (event.sender.isServer)
    {
        event.badge = "server";

        if (event.type == IRCEvent.Type.CLEARCHAT)
        {
            event.type = event.aux.length ?
                IRCEvent.Type.TEMPBAN : IRCEvent.Type.PERMBAN;
        }
    }
}


// parseTwitchTags
/++
 +  Parses a Twitch event's IRCv3 tags.
 +
 +  The event is passed by ref as many tags neccessitate changes to it.
 +
 +  Params:
 +      ref event = A reference to the IRCEvent whose tags should be parsed.
 +/
void parseTwitchTags(ref IRCEvent event)
{
    import kameloso.common : logger;
    import kameloso.string : nom;
    import std.algorithm.iteration : splitter;

    // https://dev.twitch.tv/docs/v5/guides/irc/#twitch-irc-capability-tags

    if (!event.tags.length) return;

    with (IRCEvent)
    foreach (tag; event.tags.splitter(";"))
    {
        immutable key = tag.nom("=");
        immutable value = tag;

        switch (key)
        {
        case "display-name":
            // The user’s display name, escaped as described in the IRCv3 spec.
            // This is empty if it is never set.
            event.sender.alias_ = value;
            break;

        case "badges":
            // Comma-separated list of chat badges and the version of each
            // badge (each in the format <badge>/<version>, such as admin/1).
            // Valid badge values: admin, bits, broadcaster, global_mod,
            // moderator, subscriber, staff, turbo.
            import std.string : indexOf;

            if (!value.length) break;

            // Assume the first badge is the most prominent one.
            // Seems to be the case
            immutable slash = value.indexOf('/');
            assert((slash != -1), "Slash-less badgestring");
            event.badge = value[0..slash];
            break;

        case "mod":
        case "subscriber":
        case "turbo":
            // 1 if the user has a (moderator|subscriber|turbo) badge; otherwise, 0.
            if (value == "0") break;

            if (!event.badge.length)
            {
                logger.errorf("PANIC! %s yet no previous badge!", key);
            }
            break;

        case "ban-duration":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // (Optional) Duration of the timeout, in seconds. If omitted,
            // the ban is permanent.
            event.aux = value;
            break;

        case "user-type":
            // The user’s type. Valid values: empty, mod, global_mod, admin, staff.
            // The broadcaster can have any of these.
            if (!value.length) break;
            if (!event.badge.length)
            {
                logger.errorf("PANIC! %s yet no previous badge!", value);
            }
            break;

        case "system-msg":
        case "ban-reason":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // The moderator’s reason for the timeout or ban.
            // system-msg: The message printed in chat along with this notice.
            import kameloso.irc : decodeIRCv3String;
            event.content = decodeIRCv3String(value);
            break;

        case "emote-only":
            if (value == "0") break;
            if (event.type == Type.CHAN) event.type = Type.EMOTE;
            break;

        case "msg-id":
            // The type of notice (not the ID) / A message ID string.
            // Can be used for i18ln. Valid values: see
            // Msg-id Tags for the NOTICE Commands Capability.
            // https://dev.twitch.tv/docs/irc#msg-id-tags-for-the-notice-commands-capability

            /*
                sub
                resub
                charity
                already_banned          <user> is already banned in this room.
                already_emote_only_off  This room is not in emote-only mode.
                already_emote_only_on   This room is already in emote-only mode.
                already_r9k_off         This room is not in r9k mode.
                already_r9k_on          This room is already in r9k mode.
                already_subs_off        This room is not in subscribers-only mode.
                already_subs_on         This room is already in subscribers-only mode.
                bad_host_hosting        This channel is hosting <channel>.
                bad_unban_no_ban        <user> is not banned from this room.
                ban_success             <user> is banned from this room.
                emote_only_off          This room is no longer in emote-only mode.
                emote_only_on           This room is now in emote-only mode.
                host_off                Exited host mode.
                host_on                 Now hosting <channel>.
                hosts_remaining         There are <number> host commands remaining this half hour.
                msg_channel_suspended   This channel is suspended.
                r9k_off                 This room is no longer in r9k mode.
                r9k_on                  This room is now in r9k mode.
                slow_off                This room is no longer in slow mode.
                slow_on                 This room is now in slow mode. You may send messages every <slow seconds> seconds.
                subs_off                This room is no longer in subscribers-only mode.
                subs_on                 This room is now in subscribers-only mode.
                timeout_success         <user> has been timed out for <duration> seconds.
                unban_success           <user> is no longer banned from this chat room.
                unrecognized_cmd        Unrecognized command: <command>
            */
            switch (value)
            {
            case "host_on":
                event.type = Type.HOSTSTART;
                break;

            case "host_off":
            case "host_target_went_offline":
                event.type = Type.HOSTEND;
                break;

            case "sub":
                event.type = Type.SUB;
                break;

            case "resub":
                event.type = Type.RESUB;
                break;

            case "subgift":
                // [21:33:48] msg-param-recipient-display-name = 'emilypiee'
                // [21:33:48] msg-param-recipient-id = '125985061'
                // [21:33:48] msg-param-recipient-user-name = 'emilypiee'
                event.type = Type.SUBGIFT;
                break;

            default:
                logger.info("unhandled message: ", value);
                break;
            }
            break;

        case "msg-param-receipient-display-name":
            event.target.alias_ = value;
            break;

        case "msg-param-recipient-user-name":
            event.target.nickname = value;
            break;

        case "msg-param-months":
            // The number of consecutive months the user has subscribed for,
            // in a resub notice.
            event.aux = event.aux.length ? (value ~ 'x' ~ event.aux) : value;
            break;

        case "msg-param-sub-plan":
            // The type of subscription plan being used.
            // Valid values: Prime, 1000, 2000, 3000.
            // 1000, 2000, and 3000 refer to the first, second, and third
            // levels of paid subscriptions, respectively (currently $4.99,
            // $9.99, and $24.99).
            // EVALUATE ME
            event.aux = event.aux.length ? (event.aux ~ 'x' ~ value) : value;
            break;

        case "color":
            // Hexadecimal RGB color code. This is empty if it is never set.
            if (value.length) event.colour = value[1..$];
            break;

        case "msg-param-sub-plan-name":
            // The display name of the subscription plan. This may be a default
            // name or one created by the channel owner.
        case "bits":
            /*  (Optional) The amount of cheer/bits employed by the user.
                All instances of these regular expressions:

                    /(^\|\s)<emote-name>\d+(\s\|$)/

                (where <emote-name> is an emote name returned by the Get
                Cheermotes endpoint), should be replaced with the appropriate
                emote:

                static-cdn.jtvnw.net/bits/<theme>/<type>/<color>/<size>

                * theme – light or dark
                * type – animated or static
                * color – red for 10000+ bits, blue for 5000-9999, green for
                  1000-4999, purple for 100-999, gray for 1-99
                * size – A digit between 1 and 4
            */
        case "broadcaster-lang":
            // The chat language when broadcaster language mode is enabled;
            // otherwise, empty. Examples: en (English), fi (Finnish), es-MX
            //(Mexican variant of Spanish).
        case "subs-only":
            // Subscribers-only mode. If enabled, only subscribers and
            // moderators can chat. Valid values: 0 (disabled) or 1 (enabled).
        case "r9k":
            // R9K mode. If enabled, messages with more than 9 characters must
            // be unique. Valid values: 0 (disabled) or 1 (enabled).
        case "emotes":
            /*  Information to replace text in the message with emote images.
                This can be empty. Syntax:

                <emote ID>:<first index>-<last index>,
                <another first index>-<another last index>/
                <another emote ID>:<first index>-<last index>...

                * emote ID – The number to use in this URL:
                      http://static-cdn.jtvnw.net/emoticons/v1/:<emote ID>/:<size>
                  (size is 1.0, 2.0 or 3.0.)
                * first index, last index – Character indexes. \001ACTION does
                  not count. Indexing starts from the first character that is
                  part of the user’s actual message. See the example (normal
                  message) below.
            */
        case "emote-sets":
            // A comma-separated list of emotes, belonging to one or more emote
            // sets. This always contains at least 0. Get Chat Emoticons by Set
            // gets a subset of emoticons.
        case "mercury":
            // ?
        case "followers-only":
            // Probably followers only.
        case "room-id":
            // The channel ID.
        case "slow":
            // The number of seconds chatters without moderator privileges must
            // wait between sending messages.
        case "id":
            // A unique ID for the message.
        case "sent-ts":
            // ?
        case "tmi-sent-ts":
            // ?
        case "user":
            // The name of the user who sent the notice.
        case "user-id":
            // The user’s ID.
        case "login":
            // user login? what?
        case "target-user-id":
            // The target's user ID

            // Ignore these events
            break;

        case "message":
            // The message.
        case "number-of-viewers":
            // (Optional) Number of viewers watching the host.
        default:
            // Verbosely
            logger.trace(key, " = '", value, "'");
            break;
        }
    }
}

public:

mixin BasicEventHandlers;
mixin OnEventImpl;


final class TwitchPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}
