/++
 +  The Twitch Support service post-processes `kameloso.irc.defs.IRCEvent`s after
 +  they are parsed but before they are sent to the plugins for handling, and
 +  deals with Twitch-specifics. Those include extracting the colour someone's
 +  name should be printed in, their alias/"display name" (generally their
 +  nickname capitalised), converting the event to some event types unique to
 +  Twitch, etc.
 +
 +  It has no bot commands and no event handlers; it only post-processes events.
 +
 +  It is useless on other servers but crucial on Twitch itself. Even enabled
 +  it won't slow the bot down though, as the very fist thing it does is to
 +  verify that it is on a Twitch server, and aborts and returns if not.
 +/
module kameloso.plugins.twitchsupport;

version(WithPlugins):
version(TwitchSupport):

//version = TwitchWarnings;

private:

import kameloso.plugins.common;
import kameloso.irc.defs;

version(Colours)
{
    import kameloso.terminal : TerminalForeground;
}


// postprocess
/++
 +  Handle Twitch specifics, modifying the `kameloso.irc.defs.IRCEvent` to add
 +  things like `colour` and differentiate between temporary and permanent bans.
 +/
void postprocess(TwitchSupportService service, ref IRCEvent event)
{
    // isEnabled doesn't work here since we're not offering to disable this plugin
    if (service.state.client.server.daemon != IRCServer.Daemon.twitch) return;

    service.parseTwitchTags(event);

    with (IRCEvent.Type)
    {
        if ((event.type == CLEARCHAT) && event.target.nickname.length && event.sender.isServer)
        {
            // Stay CLEARCHAT if no target nickname
            event.type = (event.count > 0) ? TWITCH_TIMEOUT : TWITCH_BAN;
        }
    }

    if (event.sender.nickname.length)
    {
        // Twitch nicknames are always the same as the user accounts; the
        // displayed name/alias is sent separately as a "display-name" IRCv3 tag
        event.sender.account = event.sender.nickname;
    }
}


// parseTwitchTags
/++
 +  Parses a Twitch event's IRCv3 tags.
 +
 +  The event is passed by ref as many tags necessitate changes to it.
 +
 +  Params:
 +      service = Current `TwitchSupportService`.
 +      event = Reference to the `kameloso.irc.defs.IRCEvent` whose tags should be parsed.
 +/
void parseTwitchTags(TwitchSupportService service, ref IRCEvent event)
{
    import kameloso.irc.common : decodeIRCv3String;
    import std.algorithm.iteration : splitter;

    // https://dev.twitch.tv/docs/v5/guides/irc/#twitch-irc-capability-tags

    if (!event.tags.length) return;

    /++
     +  Clears a user's address and class.
     +
     +  We invent users on some events, like (re-)subs, where there before were
     +  only the server announcing some event originating from that user. When
     +  we rewrite it, the server's address and its classification as special
     +  remain. Reset those.
     +/
    static void resetUser(ref IRCUser user)
    {
        user.address = string.init;  // Clear server address
        user.class_ = IRCUser.Class.unset;
    }

    with (IRCEvent)
    foreach (tag; event.tags.splitter(";"))
    {
        import kameloso.string : contains, nom;
        immutable key = tag.nom("=");
        immutable value = tag;

        switch (key)
        {
        case "msg-id":
            // The type of notice (not the ID) / A message ID string.
            // Can be used for i18ln. Valid values: see
            // Msg-id Tags for the NOTICE Commands Capability.
            // https://dev.twitch.tv/docs/irc#msg-id-tags-for-the-notice-commands-capability
            // https://swiftyspiffy.com/TwitchLib/Client/_msg_ids_8cs_source.html
            // https://dev.twitch.tv/docs/irc/msg-id/

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
                raid                    Raiders from <other channel> have joined!\n
            */
            switch (value)
            {
            case "sub":
            case "resub":
                event.type = Type.TWITCH_SUB;
                break;

            case "subgift":
                // [21:33:48] msg-param-recipient-display-name = 'emilypiee'
                // [21:33:48] msg-param-recipient-id = '125985061'
                // [21:33:48] msg-param-recipient-user-name = 'emilypiee'
                event.type = Type.TWITCH_SUBGIFT;
                break;

            case "ritual":
                // unhandled message: ritual
                event.type = Type.TWITCH_RITUAL;
                break;

            case "rewardgift":
                //msg-param-bits-amount = '199'
                //msg-param-min-cheer-amount = '150'
                //msg-param-selected-count = '60'
                event.type = Type.TWITCH_REWARDGIFT;
                break;

            case "purchase":
                //msg-param-asin = 'B07DBTZZTH'
                //msg-param-channelID = '17337557'
                //msg-param-crateCount = '0'
                //msg-param-imageURL = 'https://images-na.ssl-images-amazon.com/images/I/31PzvL+AidL.jpg'
                //msg-param-title = 'Speed\s&\sMomentum\sCrate\s(Steam\sVersion)'
                //msg-param-userID = '182815893'
                //[usernotice] tmi.twitch.tv [#drdisrespectlive]: "Purchased Speed & Momentum Crate (Steam Version) in channel."
                event.type = Type.TWITCH_PURCHASE;
                break;

            case "raid":
                //display-name=VHSGlitch
                //login=vhsglitch
                //msg-id=raid
                //msg-param-displayName=VHSGlitch
                //msg-param-login=vhsglitch
                //msg-param-viewerCount=9
                //system-msg=9\sraiders\sfrom\sVHSGlitch\shave\sjoined\n!
                event.type = Type.TWITCH_RAID;
                break;

            case "charity":
                //msg-id = charity
                //msg-param-charity-days-remaining = 11
                //msg-param-charity-hashtag = #charity
                //msg-param-charity-hours-remaining = 286
                //msg-param-charity-learn-more = https://link.twitch.tv/blizzardofbits
                //msg-param-charity-name = Direct\sRelief
                //msg-param-total = 135770
                // Too much to store in a single IRCEvent...
                event.type = Type.TWITCH_CHARITY;
                break;

            /*case "bad_ban_admin":
            case "bad_ban_anon":
            case "bad_ban_broadcaster":
            case "bad_ban_global_mod":
            case "bad_ban_mod":
            case "bad_ban_self":
            case "bad_ban_staff":
            case "bad_commercial_error":
            case "bad_delete_message_broadcaster":
            case "bad_delete_message_mod":
            case "bad_delete_message_error":
            case "bad_host_error":
            case "bad_host_hosting":
            case "bad_host_rate_exceeded":
            case "bad_host_rejected":
            case "bad_host_self":
            case "bad_marker_client":
            case "bad_mod_banned":
            case "bad_mod_mod":
            case "bad_slow_duration":
            case "bad_timeout_admin":
            case "bad_timeout_broadcaster":
            case "bad_timeout_duration":
            case "bad_timeout_global_mod":
            case "bad_timeout_mod":
            case "bad_timeout_self":
            case "bad_timeout_staff":
            case "bad_unban_no_ban":
            case "bad_unhost_error":
            case "bad_unmod_mod":*/

            case "already_banned":
            case "already_emote_only_on":
            case "already_emote_only_off":
            case "already_r9k_on":
            case "already_r9k_off":
            case "already_subs_on":
            case "already_subs_off":
            case "host_tagline_length_error":
            case "invalid_user":
            case "msg_bad_characters":
            case "msg_channel_blocked":
            case "msg_r9k":
            case "msg_ratelimit":
            case "msg_rejected_mandatory":
            case "msg_room_not_found":
            case "msg_suspended":
            case "msg_timedout":
            case "no_help":
            case "no_mods":
            case "not_hosting":
            case "no_permission":
            case "raid_already_raiding":
            case "raid_error_forbidden":
            case "raid_error_self":
            case "raid_error_too_many_viewers":
            case "raid_error_unexpected":
            case "timeout_no_timeout":
            case "unraid_error_no_active_raid":
            case "unraid_error_unexpected":
            case "unrecognized_cmd":
            case "unsupported_chatrooms_cmd":
            case "untimeout_banned":
            case "whisper_banned":
            case "whisper_banned_recipient":
            case "whisper_restricted_recipient":
            case "whisper_invalid_args":
            case "whisper_invalid_login":
            case "whisper_invalid_self":
            case "whisper_limit_per_min":
            case "whisper_limit_per_sec":
            case "whisper_restricted":
            case "msg_subsonly":
            case "msg_verified_email":
            case "msg_slowmode":
            case "tos_ban":
            case "msg_channel_suspended":
            case "msg_banned":
            case "msg_duplicate":
            case "msg_facebook":
            case "turbo_only_color":
                // Generic Twitch error.
                event.type = Type.TWITCH_ERROR;
                event.aux = value;
                break;

            case "emote_only_on":
            case "emote_only_off":
            case "r9k_on":
            case "r9k_off":
            case "slow_on":
            case "slow_off":
            case "subs_on":
            case "subs_off":
            case "followers_on":
            case "followers_off":
            case "followers_on_zero":
            case "host_on":
            case "host_off":

            /*case "usage_ban":
            case "usage_clear":
            case "usage_color":
            case "usage_commercial":
            case "usage_disconnect":
            case "usage_emote_only_off":
            case "usage_emote_only_on":
            case "usage_followers_off":
            case "usage_followers_on":
            case "usage_help":
            case "usage_host":
            case "usage_marker":
            case "usage_me":
            case "usage_mod":
            case "usage_mods":
            case "usage_r9k_off":
            case "usage_r9k_on":
            case "usage_raid":
            case "usage_slow_off":
            case "usage_slow_on":
            case "usage_subs_off":
            case "usage_subs_on":
            case "usage_timeout":
            case "usage_unban":
            case "usage_unhost":
            case "usage_unmod":
            case "usage_unraid":
            case "usage_untimeout":*/

            case "host_success_viewers":
            case "hosts_remaining":
            case "mod_success":
            case "msg_emotesonly":
            case "msg_followersonly":
            case "msg_followersonly_followed":
            case "msg_followersonly_zero":
            case "msg_rejected":  // "being checked by mods"
            case "raid_notice_mature":
            case "raid_notice_restricted_chat":
            case "room_mods":
            case "timeout_success":
            case "unban_success":
            case "unmod_success":
            case "unraid_success":
            case "untimeout_success":
            case "cmds_available":
            case "color_changed":
            case "commercial_success":
            case "delete_message_success":
            case "ban_success":
            case "host_target_went_offline":
            case "host_success":
                // Generic Twitch server reply.
                event.type = Type.TWITCH_NOTICE;
                event.aux = value;
                break;

            case "submysterygift":
                event.type = Type.TWITCH_SUBGIFT;
                break;

            case "giftpaidupgrade":
                event.type = Type.TWITCH_GIFTUPGRADE;
                break;

            default:
                import kameloso.string : beginsWith;

                event.aux = value;

                if (value.beginsWith("bad_"))
                {
                    event.type = Type.TWITCH_ERROR;
                    break;
                }
                else if (value.beginsWith("usage_"))
                {
                    event.type = Type.TWITCH_NOTICE;
                    break;
                }

                version(TwitchWarnings)
                {
                    import kameloso.terminal : TerminalToken;
                    import kameloso.common : logger;
                    logger.warning("Unknown Twitch msg-id: ", value, cast(char)TerminalToken.bell);
                }
                break;
            }
            break;

        ////////////////////////////////////////////////////////////////////////

         case "display-name":
            // The user’s display name, escaped as described in the IRCv3 spec.
            // This is empty if it is never set.
            import kameloso.string : strippedRight;
            immutable alias_ = value.contains('\\') ? decodeIRCv3String(value).strippedRight : value;

            if ((event.type == Type.USERSTATE) || (event.type == Type.GLOBALUSERSTATE))
            {
                // USERSTATE describes the bot in the context of a specific channel,
                // such as what badges are available. It's *always* about the bot,
                // so expose the display name in event.target and let Persistence store it.
                event.target = event.sender;  // get badges etc
                event.target.nickname = service.state.client.nickname;
                event.target.class_ = IRCUser.Class.admin;
                event.target.alias_ = alias_;
                event.target.address = string.init;

                if (!service.state.client.alias_.length)
                {
                    // Also store the alias in the IRCClient, for highlighting purposes
                    // *ASSUME* it never changes during runtime.
                    service.state.client.alias_ = alias_;
                    service.state.client.updated = true;
                }
            }
            else
            {
                // The display name of the sender.
                event.sender.alias_ = alias_;
            }
            break;

        case "badges":
            // Comma-separated list of chat badges and the version of each
            // badge (each in the format <badge>/<version>, such as admin/1).
            // Valid badge values: admin, bits, broadcaster, global_mod,
            // moderator, subscriber, staff, turbo.
            // Save the whole list, let the printer deal with which to display
            // Set an empty list to a placeholder asterisk
            event.sender.badges = value.length ? value : "*";
            break;

        case "system-msg":
        case "ban-reason":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // The moderator’s reason for the timeout or ban.
            // system-msg: The message printed in chat along with this notice.
            import kameloso.string : strippedRight;
            if (!event.content.length) event.content = decodeIRCv3String(value).strippedRight;
            break;

        case "emote-only":
            if (value == "0") break;
            if (event.type == Type.CHAN) event.type = Type.EMOTE;
            break;

        case "msg-param-recipient-display-name":
        case "msg-param-sender-name":
            // In a GIFTUPGRADE the display name of the one who started the gift sub train?
            event.target.alias_ = value;
            break;

        case "msg-param-recipient-user-name":
        case "msg-param-sender-login":
            // In a GIFTUPGRADE the one who started the gift sub train?
            event.target.nickname = value;
            break;

        case "msg-param-displayName":
            // RAID; sender alias and thus raiding channel cased
            event.sender.alias_ = value;
            break;

        case "msg-param-login":
        case "login":
            // RAID; real sender nickname and thus raiding channel lowercased
            // also PURCHASE. The sender's user login (real nickname)
            // CLEARMSG, SUBGIFT, lots
            event.sender.nickname = value;
            resetUser(event.sender);
            break;

        case "color":
            version(Colours)
            {
                // Hexadecimal RGB colour code. This is empty if it is never set.
                if (value.length) event.sender.colour = value[1..$];
            }
            break;

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
            import std.conv : to;
            event.type = Type.TWITCH_CHEER;
            event.count = value.to!int;
            break;

        case "msg-param-sub-plan":
            // The type of subscription plan being used.
            // Valid values: Prime, 1000, 2000, 3000.
            // 1000, 2000, and 3000 refer to the first, second, and third
            // levels of paid subscriptions, respectively (currently $4.99,
            // $9.99, and $24.99).
        case "msg-param-ritual-name":
            // msg-param-ritual-name = 'new_chatter'
            // [ritual] tmi.twitch.tv [#couragejd]: "@callmejosh15 is new here. Say hello!"
        case "msg-param-promo-name":
            // Promotion name
            // msg-param-promo-name = Subtember
            event.aux = value;
            break;

        case "emotes":
            /++ Information to replace text in the message with emote images.
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
             +/
            event.emotes = value;
            break;

        case "msg-param-title":
            //msg-param-title = 'Speed\s&\sMomentum\sCrate\s(Steam\sVersion)'
            event.aux = decodeIRCv3String(value);
            break;

        case "msg-param-charity-name":
            //msg-param-charity-name = Direct\sRelief
            immutable decoded = decodeIRCv3String(value);
            if (event.aux.length)
            {
                import std.format : format;
                event.aux = "%s: %s".format(decoded, event.aux);
            }
            else
            {
                event.aux = decoded;
            }
            break;

        case "msg-param-charity-learn-more":
            //msg-param-charity-learn-more = https://link.twitch.tv/blizzardofbits
            if (event.aux.length)
            {
                import std.format : format;
                event.aux = "%s: %s".format(event.aux, value);
            }
            else
            {
                event.aux = value;
            }
            break;

        case "ban-duration":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // (Optional) Duration of the timeout, in seconds. If omitted,
            // the ban is permanent.
        case "msg-param-viewerCount":
            // RAID; viewer count of raiding channel
            // msg-param-viewerCount = '9'
        case "msg-param-bits-amount":
            //msg-param-bits-amount = '199'
        case "msg-param-crateCount":
            // PURCHASE, no idea
        case "msg-param-sender-count":
            // Number of gift subs a user has given in the channel, on a SUBGIFT event
        case "msg-param-selected-count":
            // REWARDGIFT; of interest?
        case "msg-param-min-cheer-amount":
            // REWARDGIFT; of interest?
            // msg-param-min-cheer-amount = '150'
        case "msg-param-mass-gift-count":  // Collides with something else
            // Number of subs being gifted
        case "msg-param-promo-gift-total":
            // Number of total gifts this promotion
        case "msg-param-total":
            // Total amount donated to this charity
        case "msg-param-cumulative-months":
            // Total number of months subscribed, over time. Replaces msg-param-months
            import std.conv : to;
            event.count = value.to!int;
            break;

        case "badge-info":
            /+
                Metadata related to the chat badges in the badges tag.

                Currently this is used only for subscriber, to indicate the exact
                number of months the user has been a subscriber. This number is
                finer grained than the version number in badges. For example,
                a user who has been a subscriber for 45 months would have a
                badge-info value of 45 but might have a badges version number
                for only 3 years.

                https://dev.twitch.tv/docs/irc/tags/
             +/
            // As of yet we're not taking into consideration badge versions values.
            // When/if we do, we'll have to make sure this value overwrites the
            // subscriber/version value in the badges tag.
            // For now, ignore, as "subscriber/*" is repeated in badges.
            break;

        case "id":
            // A unique ID for the message.
            event.id = value;
            break;

        case "msg-param-asin":
            // PURCHASE
            //msg-param-asin = 'B07DBTZZTH'
        case "msg-param-channelID":
            // PURCHASE
            //msg-param-channelID = '17337557'
        case "msg-param-imageURL":
            // PURCHASE
            //msg-param-imageURL = 'https://images-na.ssl-images-amazon.com/images/I/31PzvL+AidL.jpg'
        case "msg-param-sub-plan-name":
            // The display name of the subscription plan. This may be a default
            // name or one created by the channel owner.
        case "broadcaster-lang":
            // The chat language when broadcaster language mode is enabled;
            // otherwise, empty. Examples: en (English), fi (Finnish), es-MX
            // (Mexican variant of Spanish).
        case "subs-only":
            // Subscribers-only mode. If enabled, only subscribers and
            // moderators can chat. Valid values: 0 (disabled) or 1 (enabled).
        case "r9k":
            // R9K mode. If enabled, messages with more than 9 characters must
            // be unique. Valid values: 0 (disabled) or 1 (enabled).
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
        case "sent-ts":
            // ?
        case "tmi-sent-ts":
            // ?
        case "user":
            // The name of the user who sent the notice.
        case "msg-param-userID":
        case "user-id":
        case "user-ID":
            // The user’s ID.
        case "target-user-id":
            // The target's user ID
        case "rituals":
            /++
                "Rituals makes it easier for you to celebrate special moments
                that bring your community together. Say a viewer is checking out
                a new channel for the first time. After a minute, she’ll have
                the choice to signal to the rest of the community that she’s new
                to the channel. Twitch will break the ice for her in Chat, and
                maybe she’ll make some new friends.

                Rituals will help you build a more vibrant community when it
                launches in November."

                spotted in the wild as = 0
             +/
        case "msg-param-recipient-id":
            // sub gifts
        case "target-msg-id":
            // banphrase
        case "msg-param-profileImageURL":
            // URL link to profile picture.
        case "flags":
            // Unsure.
            // flags =
            // flags = 4-11:P.5,40-46:P.6
        case "msg-param-domain":
            // msg-param-domain = owl2018
            // [rewardgift] [#overwatchleague] Asdf [bits]: "A Cheer shared Rewards to 35 others in Chat!" {35}
            // Unsure.
        case "mod":
        case "subscriber":
        case "turbo":
            // 1 if the user has a (moderator|subscriber|turbo) badge; otherwise, 0.
            // Deprecated, use badges instead.
        case "user-type":
            // The user’s type. Valid values: empty, mod, global_mod, admin, staff.
            // Deprecated, use badges instead.
        case "msg-param-origin-id":
            // msg-param-origin-id = 6e\s15\s70\s6d\s34\s2a\s7e\s5b\sd9\s45\sd3\sd2\sce\s20\sd3\s4b\s9c\s07\s49\sc4
            // [subgift] [#savjz] sender [SP] (target): "sender gifted a Tier 1 sub to target! This is their first Gift Sub in the channel!" (1000) {1}
        case "msg-param-charity-days-remaining":
            // Number of days remaining in a charity
        case "msg-param-charity-hours-remaining":
            // Number of hours remaining in a charity
        case "msg-param-charity-hashtag":
            // charity hashtag
        case "msg-param-fun-string":
            // msg-param-fun-string = FunStringTwo
            // [subgift] [#waifugate] AnAnonymousGifter (Asdf): "An anonymous user gifted a Tier 1 sub to Asdf!" (1000) {1}
            // Unsure.
        case "message-id":
            // message-id = 3
            // WHISPER, rolling number enumerating messages
        case "thread-id":
            // thread-id = 22216721_404208264
            // WHISPER, private message session?
        case "msg-param-cumulative-tenure-months":
            // Ongoing number of subscriptions (in a row)
        case "msg-param-should-share-streak-tenure":
        case "msg-param-should-share-streak":
        case "msg-param-streak-months":
        case "msg-param-streak-tenure-months":
            // Streak resubs
            // There's no extra field in which to place streak sub numbers
            // without creating a new type, but even then information is lost
            // unless we fall back to auxes of "1000 streak 3".
        case "msg-param-months":
            // DEPRECATED in favor of msg-param-cumulative-months.
            // The number of consecutive months the user has subscribed for,
            // in a resub notice.

            // Ignore these events.
            break;

        case "message":
            // The message.
        case "number-of-viewers":
            // (Optional) Number of viewers watching the host.
        default:
            version(TwitchWarnings)
            {
                import kameloso.terminal : TerminalToken;
                import kameloso.common : logger;
                logger.warningf("Unknown Twitch tag: %s = %s%c", key, value, cast(char)TerminalToken.bell);
            }
            break;
        }
    }
}


// onEndOfMotd
/++
 +  Upon having connected, registered and logged onto the Twitch servers,
 +  disable outgoing colours and warn about having a `.` prefix.
 +
 +  Twitch chat doesn't do colours, so ours would only show up like `00kameloso`.
 +  Furthermore, Twitch's own commands are prefixed with a dot `.`, so we can't
 +  use that ourselves.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd()
{
    import kameloso.common : logger, settings;

    settings.colouredOutgoing = false;

    if (settings.prefix == ".")
    {
        string logtint, warningtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;

                logtint = (cast(KamelosoLogger)logger).logtint;
                warningtint = (cast(KamelosoLogger)logger).warningtint;
            }
        }

        logger.warningf(`WARNING: A prefix of "%s%s%s" will *not* work ` ~
            "on Twitch servers, as it is reserved for Twitch's own commands.",
            logtint, settings.prefix, warningtint);
    }
}


public:


// TwitchSupportService
/++
 +  Twitch-specific service.
 +
 +  Twitch events are initially very basic with only skeletal functionality,
 +  until you enable capabilities that unlock their IRCv3 tags, at which point
 +  events become a flood of information.
 +
 +  This service only post-processes events and doesn't yet act on them in any way.
 +/
final class TwitchSupportService : IRCPlugin
{
private:
    mixin IRCPluginImpl;

    /++
     +  Override `IRCPluginImpl.onEvent` and inject a server check, so this
     +  service does nothing on non-Twitch servers. The function to call is
     +  `IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `kameloso.irc.defs.IRCEvent` to pass onto `onEventImpl`
     +          after verifying we're on a Twitch server.
     +/
    public bool onEvent(const IRCEvent event)
    {
        if (state.client.server.daemon != IRCServer.Daemon.twitch)
        {
            // Daemon known and not Twitch
            return false;
        }

        return onEventImpl(event);
    }
}
