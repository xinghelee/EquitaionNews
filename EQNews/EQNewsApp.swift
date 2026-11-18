import SwiftUI

@main
struct EQNewsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var client = EqnClient()
    @State private var speaker = Speaker()
    @State private var market = MarketStore()
    @State private var watchlist = Watchlist()
    @State private var briefing = Briefing()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .environment(speaker)
                .environment(market)
                .environment(watchlist)
                .environment(briefing)
                .task {
                    SerifFont.shared.load()
                    market.start()
                    client.onNew = { [speaker, watchlist, market] item in
                        market.anchor(item)
                        speaker.handleNew(item, level: watchlist.level(for: item), rulesActive: !watchlist.rules.isEmpty)
                    }
                    client.start()
                    PushManager.shared.rules = { [watchlist] in watchlist.payloadRules }
                    PushManager.shared.start()
                    briefing.start(items: { [client] in client.items },
                                   speak: { [speaker] t in speaker.speakText(t, id: "brief-auto-\(Date().timeIntervalSince1970)") })
                    if speaker.hasKey { await speaker.loadVoices() }
                }
        }
        .onChange(of: watchlist.rules) { _, _ in Task { await PushManager.shared.sync() } }
        .onChange(of: phase) { _, p in
            speaker.setAppActive(p == .active)
            if p == .active { client.resume(); Task { await market.refresh() } }
        }
    }
}
