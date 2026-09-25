import Foundation

/// Compile-time product gates for capabilities that require additional signing
/// verification. The SideStore MVP must remain fully functional with every
/// flag in this file disabled.
enum FeatureFlags {
    /// HealthKit export is intentionally unavailable until its entitlement,
    /// signing, permission copy, and physical-device behavior are verified.
    static let healthKitExport = false
}
