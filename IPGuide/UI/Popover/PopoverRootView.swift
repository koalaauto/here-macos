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

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            loadingPlaceholder
        case .loading(let cached):
            if let cached {
                loadedStack(model: cached)
            } else {
                loadingPlaceholder
            }
        case .loaded(let model, _):
            loadedStack(model: model)
        case .error(let error, let cached, _):
            if let cached {
                // Banner on its own row above the stack rather than an
                // overlay — the overlay version sat on top of the hero
                // header and collided with the country name (truncated
                // "Unite…" under the pill, misaligned icon).
                VStack(alignment: .leading, spacing: 10) {
                    offlineBanner(error)
                    loadedStack(model: cached)
                }
            } else {
                errorView(error)
            }
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
                .lineLimit(2)
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
            Label(String(localized: "Can't reach ip.guide"), systemImage: "wifi.slash")
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
