//
//  ExternalBibleApp.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-05.
//

import SwiftUI
import LampCore

/// One row in the "open passages in" picker.
///
/// Which apps Lamp can hand a passage to, their URL schemes, and the shape of
/// the link each one wants all live in `LampExternalBibleApplication`, so this
/// and the Mac offer the same apps and build the same links. This type adds
/// only what the list needs: the "None" row, which stands for no handoff at
/// all and so has no application behind it.
struct ExternalBibleApp: Identifiable, Hashable {
    /// `nil` for the "None" row.
    let application: LampExternalBibleApplication?

    var id: String { name }
    var name: String { application?.rawValue ?? "None" }

    /// Empty for "None", which is never checked for installation.
    var scheme: String { application?.scheme ?? "" }

    func getFullUrl(sv: Int, ev: Int) -> URL? {
        application?.url(startReference: sv, endReference: ev) { number in
            guard let book = try? BundledModuleDatabase.shared.getBook(id: number) else {
                return nil
            }
            // The installed translation's own OSIS identifier, which is
            // authoritative over core's canonical table for that book.
            return LampExternalBibleBook(
                number: number,
                name: book.name,
                osisID: book.osisParatextAbbreviation
            )
        }
    }
}

let externalBibleApps: [ExternalBibleApp] =
    [ExternalBibleApp(application: nil)]
    + LampExternalBibleApplication.allCases.map(ExternalBibleApp.init(application:))
