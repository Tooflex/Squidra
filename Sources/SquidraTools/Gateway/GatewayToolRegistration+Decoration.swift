extension GatewayToolRegistration {
    /// Trusted composition hook. Keep the catalog identity, surface and exact
    /// target resolver while wrapping only the already authorized executor.
    public func decoratingExecutor(_ transform: @Sendable (any ToolExecutor) -> any ToolExecutor) -> GatewayToolRegistration {
        GatewayToolRegistration(definition:definition,surface:surface,executor:transform(executor),resolveTarget:resolveTarget)
    }
}
