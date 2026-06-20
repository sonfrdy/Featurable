extension AsyncStream {
  static var never: Self {
    Self { _ in }
  }
}
