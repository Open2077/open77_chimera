resource "open77_chimera_lab"
version "1.0.0"
open77_version ">=0.0.1"
auto_start false
reload_policy "reconnect"
dependency "open77_uikit >=1.0.0"
dependency "open77_chimera >=1.0.0"
server_script "server.lua"
client_script "client.lua"
permissions { "acl.read", "players.life.read", "network.events" }
