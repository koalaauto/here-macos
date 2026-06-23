import SwiftUI

struct PopoverRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @State private var state: IPState = .idle
    @State private var regionCode: String?
    @State private var lastFetchedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                content
                    .blur(radius: showsLoadingOverlay ? 4 : 0)
                    .animation(.easeInOut(duration: 0.2), value: showsLoadingOverlay)
                if showsLoadingOverlay {
                    loadingBadge
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showsLoadingOverlay)

            MetaFooter(state: state, lastFetchedAt: lastFetchedAt, onRefresh: refresh)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 360, alignment: .top)
        .task { await observeState() }
    }

    private var showsLoadingOverlay: Bool {
        state.isLoading && state.model != nil
    }

    private var loadingBadge: some View {
        ProgressView()
            .controlSize(.large)
            .padding(26)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    /// Render with **stable view identity** across state transitions.
    ///
    /// We deliberately do NOT use a `switch state { … }` here, even
    /// though that reads more naturally. SwiftUI treats each `case`
    /// of a switch as a structurally distinct branch — transitioning
    /// from `.loaded` to `.loading(cached:)` (and back) destroys the
    /// active branch's child views and creates the other branch's
    /// fresh, even though both branches happen to render the same
    /// `loadedStack(model:)`. Every `.task`-bound `@State` in
    /// `ThroughputCard`, `LatencyCard`, `HistoryCard`, … resets to
    /// its initial empty value, the cards render shorter for one
    /// frame until `observe()` re-reads the stream, then snap back
    /// — visible to the user as the popover bottom growing-and-
    /// shrinking on every refresh.
    ///
    /// Replacing the switch with a single `if let model = state.model`
    /// puts both `.loaded` and `.loading(cached:)` on the same view-
    /// tree branch. Child identities are preserved across the
    /// transition; `@State` survives; the popover stops jittering.
    @ViewBuilder
    private var content: some View {
        if let model = state.model {
            VStack(alignment: .leading, spacing: 10) {
                if case .error(let error, _, _) = state {
                    // Banner above the stack rather than as an
                    // overlay — the overlay version sat on top of the
                    // hero header and collided with the country name.
                    offlineBanner(error)
                }
                loadedStack(model: model)
            }
        } else if case .error(let error, _, _) = state {
            errorView(error)
        } else {
            loadingPlaceholder
        }
    }

    @ViewBuilder
    private func loadedStack(model: IPDataModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IPHeroView(model: model, regionCode: regionCode, fetchedAt: lastFetchedAt)
            ForEach(settings.popoverModuleOrder) { module in
                moduleCard(module, model: model)
            }
        }
    }

    @ViewBuilder
    private func moduleCard(_ module: PopoverModule, model: IPDataModel) -> some View {
        switch module {
        case .location:
            LocationCard(model: model)
        case .latency:
            if settings.latencyEnabled {
                LatencyCard()
            }
        case .history:
            HistoryCard()
        case .throughput:
            ThroughputCard()
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(String(localized: "Looking up your IP…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func offlineBanner(_ error: IPServiceError) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            Text(error.userDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                // Constrain to a single line — the message is meant
                // to be a glanceable banner above the popover, not a
                // text block. Long upstream errors (URLError's
                // `localizedDescription` can run 80+ chars) get
                // ellipsized; the full string remains accessible
                // via the tooltip below.
                .lineLimit(1)
                .truncationMode(.tail)
                .help(error.userDescription)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func errorView(_ error: IPServiceError) -> some View {
        ContentUnavailableView {
            Label(String(localized: "Can't reach the IP lookup service"), systemImage: "wifi.slash")
        } description: {
            Text(error.userDescription)
        } actions: {
            Button(String(localized: "Try again")) { refresh() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func refresh() {
        environment.scheduler.triggerNow()
    }

    private func observeState() async {
        for await next in environment.ipService.stateStream() {
            state = next
            if case .loaded(_, let at) = next {
                lastFetchedAt = at
            } else if case .error(_, _, let at?) = next {
                lastFetchedAt = at
            }
            if let model = next.model {
                regionCode = await environment.regionMapper.regionCode(for: model)
            }
        }
    }
}
