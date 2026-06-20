# Featurable

Featurable is a feature-level state management library focused on a single feature and unidirectional data flow.

It adapts the core `Store`, `Reducer`, and `Effect` model of [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) for single-feature state management.

## Requirements

- Swift 6
- iOS 13+
- macOS 10.15+
- tvOS 13+
- watchOS 6+
- Native Observation APIs require iOS 17+, macOS 14+, tvOS 17+, or watchOS 10+.

## Installation

Add the package and import the main product:

```swift
import Featurable
```

## Core Model

A feature is built from `State`, `Action`, `Effect`, and `Reducer`:

- `State`: the data needed to render the feature.
- `Action`: user events, lifecycle events, and effect responses.
- `Effect`: asynchronous work that can send actions back to the store.
- `Reducer`: the logic that mutates state and returns an effect.

The `Store` owns state, runs the reducer, publishes changes, starts effects, and routes effect actions back through the reducer. Returning `.none` means there is no follow-up work. Returning `.run` starts asynchronous work that can send a later action.

```swift
import Featurable

struct WeatherFeature: Reducer {
  let weatherClient: any WeatherClient

  @ObservableState
  struct State: Equatable {
    var forecast: Forecast?
    var isLoading = false
  }

  enum Action: Equatable {
    case refreshButtonTapped
    case forecastResponse(Forecast)
  }

  enum CancelID: Hashable, Sendable {
    case forecastRequest
  }

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .refreshButtonTapped:
      state.isLoading = true
      let weatherClient = self.weatherClient

      return .run { send in
        let forecast = await weatherClient.fetch()
        await send(.forecastResponse(forecast))
      }
      .cancellable(id: CancelID.forecastRequest, cancelInFlight: true)

    case .forecastResponse(let forecast):
      state.forecast = forecast
      state.isLoading = false
      return .none
    }
  }
}

let store = Store(
  initialState: WeatherFeature.State(),
  reducer: WeatherFeature(weatherClient: weatherClient)
)

store.send(.refreshButtonTapped)
```

## Observation

On platforms that support Swift Observation, mark feature state with `@ObservableState`:

```swift
@ObservableState
struct State: Equatable {
  var isLoading = false
}
```

Then read state directly from the store:

```swift
store.isLoading
```

On earlier supported platforms, use `Store.publisher` to observe state changes.

## SwiftUI

On platforms that support Swift Observation, SwiftUI views can read state and send actions directly:

```swift
import Featurable
import SwiftUI

struct WeatherView: View {
  let store: StoreOf<WeatherFeature>

  var body: some View {
    VStack {
      if let forecast = store.forecast {
        ForecastView(forecast: forecast)
      }

      Button("Refresh") {
        store.send(.refreshButtonTapped)
      }
    }
  }
}
```

Bindings write through actions instead of mutating store state directly:

```swift
struct ProfileFormFeature: Reducer {
  @ObservableState
  struct State: Equatable {
    var name = ""
  }

  enum Action: Equatable {
    case nameChanged(String)
  }

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .nameChanged(let name):
      state.name = name
      return .none
    }
  }
}

struct ProfileView: View {
  let store: StoreOf<ProfileFormFeature>

  var body: some View {
    TextField(
      "Name",
      text: store.binding(
        get: \.name,
        send: { .nameChanged($0) }
      )
    )
  }
}
```

## UIKit

UIKit view controllers can subscribe to `Store.publisher`:

```swift
import Combine

final class WeatherViewController: UIViewController {
  private let store: StoreOf<WeatherFeature>
  private var cancellables: Set<AnyCancellable> = []

  override func viewDidLoad() {
    super.viewDidLoad()

    store.publisher
      .sink { [weak self] state in
        self?.loadingLabel.isHidden = !state.isLoading
      }
      .store(in: &cancellables)
  }

  private func refreshButtonTapped() {
    store.send(.refreshButtonTapped)
  }
}
```

When your feature state uses `@ObservableState`, platforms that support UIKit's automatic observation tracking can read store state in `updateProperties()`:

```swift
@available(anyAppleOS 26.0, *)
override func updateProperties() {
  super.updateProperties()
  loadingLabel.isHidden = !store.isLoading
}
```

## Effects

Effects describe asynchronous work that can send actions back to the store:

```swift
return .run { send in
  let response = await client.load()
  await send(.response(response))
}
```

Effects can also be canceled by id:

```swift
enum CancelID: Hashable, Sendable {
  case search
}

return .run { send in
  let result = await search()
  await send(.searchResponse(result))
}
.cancellable(id: CancelID.search, cancelInFlight: true)
```

## Testing

Add `FeaturableTesting` to your test target and use `TestStore` for reducer tests:

```swift
import Featurable
import FeaturableTesting
import Testing

@Test
@MainActor
func refreshWeather() async {
  let forecast: Forecast = ...
  let weatherClient: any WeatherClient = ...

  let store = TestStore(
    initialState: WeatherFeature.State(),
    reducer: WeatherFeature(weatherClient: weatherClient)
  )

  await store.send(.refreshButtonTapped) {
    $0.isLoading = true
  }

  await store.receive(.forecastResponse(forecast)) {
    $0.forecast = forecast
    $0.isLoading = false
  }
}
```
