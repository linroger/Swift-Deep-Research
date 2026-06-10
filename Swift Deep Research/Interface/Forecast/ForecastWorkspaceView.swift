import SwiftUI

/// Detail pane for the Forecast workspace: the live/restored pipeline when one is
/// active, otherwise the composer hero. Ensures the MiroFish backend is starting
/// in the background so the first run is as fast as possible.
struct ForecastWorkspaceView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        Group {
            if let run = env.forecast {
                ForecastPipelineView(run: run, onNewForecast: { env.newForecast() })
            } else {
                ForecastComposer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvasBackground)
        .sheet(isPresented: $env.forecastOnboardingOpen) {
            ForecastOnboardingView()
        }
        .task {
            let status = await env.ensureForecastBackend()
            env.maybeAutoPresentForecastOnboarding()
            if case .running = status { await env.refreshBackendPipelines() }
        }
    }

    @ViewBuilder
    private var canvasBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear.background(.regularMaterial)
        } else {
            Color(NSColor.windowBackgroundColor)
        }
    }
}
