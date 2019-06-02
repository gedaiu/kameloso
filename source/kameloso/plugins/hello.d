module kameloso.plugins.hello;

version(none):  // Remove to enable

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.messaging;

@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
@BotCommand(PrefixPolicy.nickname, "hello")
@Description("Says hello")
void onCommandHi(HelloPlugin plugin, const IRCEvent event)
{
    chan(plugin.state, event.channel, "Hello World!");
}

final class HelloPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}