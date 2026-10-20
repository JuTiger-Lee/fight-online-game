// Supabase Realtime bridge used by Godot (scripts/net.gd) through JavaScriptBridge.
// Incoming messages are queued and drained by Godot every frame via poll().
(function () {
  let client = null;
  let channel = null;
  let queue = [];

  function push(e, p) {
    queue.push({ e, p });
  }

  function presenceList() {
    const state = channel.presenceState();
    const list = [];
    for (const key in state) {
      const metas = state[key];
      if (metas && metas.length) list.push(metas[metas.length - 1]);
    }
    return list;
  }

  window.SupaNet = {
    join(room, metaJson) {
      const meta = JSON.parse(metaJson);
      const cfg = window.BEAST_CONFIG;
      if (!client) {
        client = supabase.createClient(cfg.url, cfg.key, {
          realtime: { params: { eventsPerSecond: 40 } },
        });
      }
      if (channel) this.leave();
      channel = client.channel("beast-brawl:" + room, {
        config: { broadcast: { self: false, ack: false }, presence: { key: meta.id } },
      });
      channel
        .on("broadcast", { event: "st" }, (m) => push("st", m.payload))
        .on("broadcast", { event: "ev" }, (m) => push("ev", m.payload))
        .on("presence", { event: "sync" }, () => push("presence", { players: presenceList() }))
        .subscribe(async (status) => {
          push("status", { s: status });
          if (status === "SUBSCRIBED") await channel.track(meta);
        });
    },

    send(event, json) {
      if (!channel) return;
      channel.send({ type: "broadcast", event, payload: JSON.parse(json) });
    },

    poll() {
      if (!queue.length) return "";
      const out = JSON.stringify(queue);
      queue = [];
      return out;
    },

    leave() {
      if (channel && client) client.removeChannel(channel);
      channel = null;
      queue = [];
    },

    copyInvite(room) {
      const url = location.origin + location.pathname + "?room=" + encodeURIComponent(room);
      if (navigator.clipboard) navigator.clipboard.writeText(url);
    },
  };

  window.addEventListener("beforeunload", () => window.SupaNet.leave());
})();
