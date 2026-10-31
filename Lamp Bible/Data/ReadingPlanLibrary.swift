//
//  ReadingPlanLibrary.swift
//  Lamp Bible
//

import Foundation

/// The reading plans the phone can follow: the bundled ones, and those the
/// user has added or made, which are kept in the user's database and synced
/// as Plans/<id>.lamp. A user's plan stands in for a bundled one of the same ID.
enum ReadingPlanLibrary {
    /// The bundled plans, then the user's, each by name.
    static func allPlans() -> [Plan] {
        let users = (try? ModuleDatabase.shared.getAllPlans()) ?? []
        let userIDs = Set(users.map(\.id))
        let bundled = ((try? BundledModuleDatabase.shared.getAllPlans()) ?? []).filter { !userIDs.contains($0.id) }
        return bundled + users.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func plan(id: String) -> Plan? {
        if let plan = (try? ModuleDatabase.shared.getPlan(id: id)) ?? nil { return plan }
        return (try? BundledModuleDatabase.shared.getPlan(id: id)) ?? nil
    }

    /// The plan's readings for `day`, from whichever database holds the plan.
    static func planDay(planId: String, day: Int) throws -> PlanDay? {
        if isUserPlan(id: planId) {
            return try ModuleDatabase.shared.getPlanDay(planId: planId, day: day)
        }
        return try BundledModuleDatabase.shared.getPlanDay(planId: planId, day: day)
    }

    /// Whether the plan is the user's, added or made, rather than bundled.
    static func isUserPlan(id: String) -> Bool {
        ((try? ModuleDatabase.shared.getPlan(id: id)) ?? nil) != nil
    }
}
