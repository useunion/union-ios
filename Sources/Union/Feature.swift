import Foundation

/// A feature declared in code. The key is written once and the role follows from the method, so a
/// funnel reads as the flow it measures:
///
/// ```swift
/// let checkout = Union.feature("checkout")
/// checkout.screen("Checkout")            // discovery: saw the Checkout screen
/// checkout.start("checkout_started")
/// checkout.use("shipping_selected")
/// checkout.success("order_placed", properties: ["total": 49.9])
/// checkout.failure("payment_failed")
/// ```
///
/// On the server a declaration is a definition, not a suggestion: production and TestFlight traffic
/// creates the feature (or extends one the panel already has) without an inbox step, and the panel
/// refines it — name, owner, extra events. Edits made there are kept on later syncs. Development
/// builds only pre-fill the editor. A typo in the key therefore makes a second feature: visible as
/// "Declared in code" with its key, fixed by archiving it.
///
/// The key follows the event-name alphabet (`^[a-z][a-z0-9_]*$`, ≤ 64). An invalid key is logged
/// once here; events sent through the handle are then dropped, never sent without their feature —
/// an event stripped of the feature it was written for would read as "not part of any feature".
public struct Feature: Sendable, Equatable {
    public let key: String

    init(key: String) { self.key = key }

    public func discovery(_ name: String, properties: [String: PropertyValue] = [:]) { track(name, properties, .discovery) }
    public func start(_ name: String, properties: [String: PropertyValue] = [:]) { track(name, properties, .start) }
    public func use(_ name: String, properties: [String: PropertyValue] = [:]) { track(name, properties, .use) }
    public func success(_ name: String, properties: [String: PropertyValue] = [:]) { track(name, properties, .success) }
    public func failure(_ name: String, properties: [String: PropertyValue] = [:]) { track(name, properties, .failure) }

    /// `$screen_view` for this feature: the usual discovery step. Same as `Union.screen(name, feature: key)`.
    public func screen(_ name: String, properties: [String: PropertyValue] = [:]) {
        Union.screen(name, properties: properties, feature: key)
    }

    private func track(_ name: String, _ properties: [String: PropertyValue], _ role: FeatureRole) {
        Union.track(name, properties: properties, feature: key, role: role)
    }
}
