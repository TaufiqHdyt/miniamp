extension Duration {
    /// The duration in seconds, with the fraction.
    public var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// The duration in milliseconds, rounded down.
    public var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}
